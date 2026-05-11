// Cloudflare Worker — GuideDog Vision AI gateway.
//
// Proxies image + prompt requests to Anthropic (Claude Haiku 4.5) or
// OpenAI (GPT-4.1-mini), keeping API keys server side and exposing CORS
// for the GitHub Pages client.
//
// Supports two modes on the same POST endpoint:
//
//   { ..., stream: false }  → behaves exactly like the prior Worker.
//                              Awaits the full upstream response and
//                              returns { result } as application/json.
//
//   { ..., stream: true  }  → opens an SSE pipe. Parses the upstream
//                              vendor-specific stream, normalizes to a
//                              single shape, and re-emits as
//                                data: {"delta":"some text"}
//                                data: {"done":true}
//                              The client can speak each completed
//                              sentence as it arrives.
//
// Required Worker secrets (already in place on the deployed Worker):
//   ANTHROPIC_API_KEY
//   OPENAI_API_KEY

function detectMediaType(base64) {
    if (base64.startsWith('/9j/')) return 'image/jpeg';
    if (base64.startsWith('iVBOR')) return 'image/png';
    if (base64.startsWith('UklGR')) return 'image/webp';
    return 'image/jpeg';
}

const SYSTEM_PROMPT_APP = `You are a safety assistant for a blind person. Analyze the image and respond in under 15 words.

FIRST PRIORITY — always check these before anything else:
- STAIRS (up or down, which side) — say "STAIRS DOWN center" or "STAIRS UP left"
- STEPS, CURBS, DROP-OFFS, LEDGES — say "STEP DOWN ahead" or "CURB right"

SECOND PRIORITY:
- Wet/slippery surfaces
- Head-height obstacles (beams, branches, signs)
- Moving vehicles, cyclists
- Doors (open/closed)
- Wall or dead end blocking path

For each hazard: what, direction (left/center/right), urgency (stop/slow/aware).
If path is genuinely open with no stairs, walls, or obstacles: "Path clear"
Under 15 words. No greetings. No filler.`;

const SYSTEM_PROMPT_GUIDE = `You are walking beside a blind person as their sighted guide, helping them navigate their surroundings. Describe what you see in 10-15 words.

Describe:
- What is ahead (wall, door, hallway, open room, outside, sidewalk)
- Any obstacles in the walking path
- Stairs, steps, or curbs (only if clearly visible — do not guess)
- Doors (open or closed) and which direction
- Floor conditions or surface changes (carpet to tile, wet, uneven)
- General surroundings to help them understand where they are (kitchen, hallway, parking lot, intersection)
- Which direction is clear to walk

Your goal is to help them move safely and confidently. Speak naturally like a helpful friend walking with them.
Under 15 words. No greetings.`;

const CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
};

function jsonResponse(body, status = 200) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
    });
}

function buildPrompts(mode, context) {
    const isDetailed = mode === 'detailed';
    const isGuide = mode === 'guide';
    const systemPrompt = isGuide ? SYSTEM_PROMPT_GUIDE : SYSTEM_PROMPT_APP;
    const maxTokens = isDetailed ? 150 : 60;
    const userPrompt = context
        ? `Describe what you see to help a blind person navigate. Their sensors detect: ${context}. Focus on what sensors miss.`
        : `Describe what you see to help a blind person navigate safely.`;
    return { systemPrompt, maxTokens, userPrompt };
}

function buildAnthropicRequest({ apiKey, image, mediaType, systemPrompt, userPrompt, maxTokens, stream }) {
    return new Request('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01'
        },
        body: JSON.stringify({
            model: 'claude-haiku-4-5-20251001',
            max_tokens: maxTokens,
            stream,
            system: systemPrompt,
            messages: [{
                role: 'user',
                content: [
                    { type: 'image', source: { type: 'base64', media_type: mediaType, data: image } },
                    { type: 'text', text: userPrompt }
                ]
            }]
        })
    });
}

function buildOpenAIRequest({ apiKey, image, mediaType, systemPrompt, userPrompt, maxTokens, stream }) {
    return new Request('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${apiKey}`
        },
        body: JSON.stringify({
            model: 'gpt-4.1-mini',
            max_tokens: maxTokens,
            stream,
            messages: [
                { role: 'system', content: systemPrompt },
                {
                    role: 'user',
                    content: [
                        { type: 'text', text: userPrompt },
                        { type: 'image_url', image_url: { url: `data:${mediaType};base64,${image}`, detail: 'auto' } }
                    ]
                }
            ]
        })
    });
}

async function handleNonStreaming(env, body) {
    const { image, provider, mode = 'background', context = '' } = body;
    const mediaType = detectMediaType(image);
    const { systemPrompt, maxTokens, userPrompt } = buildPrompts(mode, context);

    let result;
    if (provider === 'anthropic' && env.ANTHROPIC_API_KEY) {
        const req = buildAnthropicRequest({
            apiKey: env.ANTHROPIC_API_KEY,
            image, mediaType, systemPrompt, userPrompt, maxTokens, stream: false
        });
        const response = await fetch(req);
        if (!response.ok) {
            const err = await response.text();
            throw new Error(`Anthropic ${response.status}: ${err}`);
        }
        const data = await response.json();
        result = data.content[0].text;
    } else if (env.OPENAI_API_KEY) {
        const req = buildOpenAIRequest({
            apiKey: env.OPENAI_API_KEY,
            image, mediaType, systemPrompt, userPrompt, maxTokens, stream: false
        });
        const response = await fetch(req);
        if (!response.ok) {
            const err = await response.text();
            throw new Error(`OpenAI ${response.status}: ${err}`);
        }
        const data = await response.json();
        result = data.choices[0].message.content;
    } else {
        return jsonResponse({ error: 'No API key configured' }, 500);
    }
    return jsonResponse({ result });
}

async function handleStreaming(env, body) {
    const { image, provider, mode = 'background', context = '' } = body;
    const mediaType = detectMediaType(image);
    const { systemPrompt, maxTokens, userPrompt } = buildPrompts(mode, context);

    let upstream;
    let upstreamProvider;
    if (provider === 'anthropic' && env.ANTHROPIC_API_KEY) {
        upstreamProvider = 'anthropic';
        const req = buildAnthropicRequest({
            apiKey: env.ANTHROPIC_API_KEY,
            image, mediaType, systemPrompt, userPrompt, maxTokens, stream: true
        });
        upstream = await fetch(req);
    } else if (env.OPENAI_API_KEY) {
        upstreamProvider = 'openai';
        const req = buildOpenAIRequest({
            apiKey: env.OPENAI_API_KEY,
            image, mediaType, systemPrompt, userPrompt, maxTokens, stream: true
        });
        upstream = await fetch(req);
    } else {
        return jsonResponse({ error: 'No API key configured' }, 500);
    }

    if (!upstream.ok) {
        const err = await upstream.text();
        return jsonResponse({ error: `${upstreamProvider} ${upstream.status}: ${err}` }, 500);
    }

    // Normalize upstream SSE → unified SSE for the client.
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const encoder = new TextEncoder();

    (async () => {
        const reader = upstream.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        async function emit(obj) {
            await writer.write(encoder.encode(`data: ${JSON.stringify(obj)}\n\n`));
        }

        try {
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                buffer += decoder.decode(value, { stream: true });

                // SSE events are separated by blank lines.
                const events = buffer.split('\n\n');
                buffer = events.pop(); // last item may be partial

                for (const event of events) {
                    const dataLine = event.split('\n').find(l => l.startsWith('data:'));
                    if (!dataLine) continue;
                    const data = dataLine.slice(5).trim();
                    if (!data || data === '[DONE]') continue;

                    let parsed;
                    try { parsed = JSON.parse(data); }
                    catch (e) { continue; }

                    let delta = null;
                    if (upstreamProvider === 'anthropic') {
                        if (parsed.type === 'content_block_delta'
                            && parsed.delta?.type === 'text_delta') {
                            delta = parsed.delta.text;
                        }
                    } else {
                        delta = parsed.choices?.[0]?.delta?.content || null;
                    }

                    if (delta) await emit({ delta });
                }
            }
            await emit({ done: true });
        } catch (e) {
            await emit({ error: e.message || String(e) });
        } finally {
            try { await writer.close(); } catch (e) {}
        }
    })();

    return new Response(readable, {
        headers: {
            ...CORS_HEADERS,
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache, no-transform',
            'X-Accel-Buffering': 'no'
        }
    });
}

export default {
    async fetch(request, env) {
        if (request.method === 'OPTIONS') {
            return new Response(null, { headers: CORS_HEADERS });
        }
        if (request.method !== 'POST') {
            return jsonResponse({ error: 'POST only' }, 405);
        }
        try {
            const body = await request.json();
            if (body.stream === true) {
                return await handleStreaming(env, body);
            }
            return await handleNonStreaming(env, body);
        } catch (error) {
            return jsonResponse({ error: error.message || String(error) }, 500);
        }
    }
};
