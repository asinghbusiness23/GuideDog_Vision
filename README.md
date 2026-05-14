# GuideDog

GuideDog was built to act as a virtual guide dog for the visually and audibly impaired. The iPhone app watches what's in front of users with LiDAR and machine learning models to warn users of obstacles and hazards. The website replicates the same functionality without LiDAR support and runs on any browser across all phones.

| App Store | Website |
|:---:|:---:|
| <img src="qr-app.png" alt="QR code for GuideDog on the App Store" width="240"> | <img src="qr-website.png" alt="QR code for GuideDog website" width="240"> |
| Scan to download on iPhone | Scan to launch in your browser |

## Why This Was Built

### How many people this affects

**2.2 billion people** on Earth faces some form of vision difficulty, according to the World Health Organization. Close to **43 million** live without sight entirely, while near **300 million** manage life with moderate to severe visual impairements [1]. Growth trends suggest a rising path ahead. By 2050, those affected may swell by **55%**, adding around **600 million individuals** to today’s totals [2].

Among those affected, employment rates reveal a stark contrast. Just **44%** of working-age U.S. adults facing moderate to severe vision challenges hold jobs, while the general population sits at **77%** [3]. Mental health outcomes show similar strain, with depression and related conditions appear **up to 2.8 times more often** in people experiencing sight loss [4].

### The guide dog gap

One of the better-known supports for those unable to see well is the guide dog. Still, access remains limited for many facing vision loss. Across the U.S., roughly 10,000 pairs of handlers and dogs perform this work. Worldwide, just 2 percent of individuals who are blind receive such assistance [5].

This gap exists for three primary causes:

Costing between forty thousand and sixty thousand dollars to produce and assign, a prepared guide dog represents significant investment [5][6]. Because nonprofit support often covers part or all of this expense, availability depends heavily on how much money these groups can gather. After placement occurs, ongoing expenses follow, with monthly amounts ranging from **$180 - $220** cover meals, health visits, and needed items [5].

A single guide dog requires close to twenty-four months of training, yet merely one out of three completes it successfully [5]. Due to such constraints, availability remains extremely low; wait times stretch between twelve and thirty-six months [7]. Surprisingly, certain organizations are forced to stop or pause taking applications for guide dogs because their supply is so limited.

Though placed successfully, movement still faces limits with guide dogs. Certain locations refuse entry to service animals, while others demand arrangements the handler might lack time to make. Care for the animal involves steady housing, daily activity, medical visits, plus regular cleaning routines. Health maintenance demands consistent effort over years, turning each pairing into a lasting duty.

### How many people are affected by hearing loss

Hearing loss runs parallel to vision loss in scale and impact. **1.5 billion people** worldwide live with some form of hearing loss according to the World Health Organization. About **430 million** of them face disabling hearing loss that needs rehabilitation today [8]. The trajectory ahead is steeper than for vision. By 2050, **2.5 billion people** are projected to have hearing loss of some kind, with **700 million** needing daily rehabilitation [8].

The downstream costs follow the same pattern. Unaddressed hearing loss costs the global economy roughly **$980 billion per year** through lost productivity and added health spending [8]. People with untreated hearing loss face higher rates of unemployment, depression, and social isolation, plus a measurably increased risk of dementia later in life [9].

### The hearing aid gap

Hearing aids work, but access is the problem. In the United States, only about **17 percent** of adults who could benefit from a hearing aid actually use one [9]. Cost is the biggest barrier. A single pair runs **$1,000 to $6,000**, and most insurance plans, Medicare included, do not cover them [10]. Cochlear implants, the next step up for severe loss, cost **$30,000 to $50,000 per ear** without coverage [11].

The technology gap matters beyond conversation. Audible alerts (smoke alarms, doorbells, sirens, car horns, someone calling a name) are part of the safety infrastructure built around assuming everyone can hear. When that assumption breaks, the world becomes harder to move through.

### Where this app fits

GuideDog is not a guide dog. A trained animal makes its own safety calls and is a companion. Software cannot do either of those things. What software can do is run on a phone someone already owns, watch the scene in front of them, listen for the sounds around them, and report back. The app does both. The Sound and Captions mode classifies environmental audio (alarms, sirens, doorbells, conversation) and turns nearby speech into live captions, while the obstacle detection side handles the visual layer. This makes both visual and hearing assistance available at a scale guide dogs cannot reach, on hardware people already own.

---

**Sources**

1. World Health Organization. *Vision impairment and blindness fact sheet.* https://www.who.int/news-room/fact-sheets/detail/blindness-and-visual-impairment
2. Statista. *Vision Loss Predicted to Surge 55% by 2050.* https://www.statista.com/chart/31502/expected-number-of-people-with-vision-loss-globally/
3. McDonnall, M. C., & Sui, Z. (2019). *Employment and Unemployment Rates of People Who Are Blind or Visually Impaired.* https://journals.sagepub.com/doi/abs/10.1177/0145482X19887620
4. National Library of Medicine. *Visual Impairment and Mental Health: Unmet Needs and Treatment Options.* https://pmc.ncbi.nlm.nih.gov/articles/PMC7721280/
5. Dogster. *10 Service Dog Statistics: Training, Costs & FAQ.* https://www.dogster.com/statistics/service-dog-statistics
6. Hepper Pet Resources. *How Much is a Guide Dog: Cost Breakdown & FAQs.* https://articles.hepper.com/how-much-is-a-guide-dog/
7. All About Vision. *How to Get a Guide Dog: A Resource Guide.* https://www.allaboutvision.com/conditions/blindness-low-vision/how-to-get-a-guide-dog/
8. World Health Organization. *Deafness and hearing loss fact sheet.* https://www.who.int/news-room/fact-sheets/detail/deafness-and-hearing-loss
9. National Institute on Deafness and Other Communication Disorders. *Quick Statistics About Hearing, Balance, & Dizziness.* https://www.nidcd.nih.gov/health/statistics/quick-statistics-hearing
10. National Council on Aging. *How Much Do Hearing Aids Cost in 2024?* https://www.ncoa.org/adviser/hearing-aids/hearing-aid-cost/
11. Healthline. *How Much Do Cochlear Implants Cost?* https://www.healthline.com/health/cochlear-implant-cost

## Overview

The project has two halves that share the same goal.

The iPhone app uses ARKit LiDAR (on Pro models), YOLOv8n object detection, a custom 55 class navigation model trained for this project, Apple's mesh classifier for walls and doors, and a cloud AI fallback for scene descriptions. On non-Pro iPhones it relies back to Depth-Anything, which is a neural depth estimator to allow the app to continue to work without LiDAR.

The website is a Progressive Web App that runs in any modern browser. This website has no LiDAR access at all, so all of the decisions come from a mix of machine learning, APIs, and a cloud AI. Specifically, it uses:
COCO-SSD for objects
Depth-Anything in the browser for relative depth
MediaPipe Audio Classifier for sound detection
The Web Speech API for live captions
Cloud AI that runs every few seconds as a sighted companion, which races Claude Haiku 4.5 against GPT-4.1-mini and returns the first output.
