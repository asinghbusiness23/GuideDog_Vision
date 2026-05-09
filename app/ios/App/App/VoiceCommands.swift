import Speech
import AVFoundation

enum VoiceCommand {
    case whatsAround
    case isSafe
    case checkLeft
    case checkRight
    case stop
    case resume
    case help
    case scan
    case readText
    case identifyBill
    case identifyColor
    case unknown(String)
}

protocol VoiceCommandDelegate: AnyObject {
    func voiceCommandReceived(_ command: VoiceCommand)
}

class VoiceCommandController: NSObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isListeningState = false
    private var lastCommandTime: Date?
    private let commandCooldown: TimeInterval = 2.0
    weak var delegate: VoiceCommandDelegate?

    override init() {
        super.init()
    }

    var isListening: Bool { isListeningState }

    func startListening() {
        guard !isListeningState else {
            print("Voice: already listening")
            return
        }

        // Request authorization synchronously-ish — check status first
        let status = SFSpeechRecognizer.authorizationStatus()
        print("Voice: auth status = \(status.rawValue)")

        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] newStatus in
                print("Voice: auth result = \(newStatus.rawValue)")
                if newStatus == .authorized {
                    DispatchQueue.main.async { self?.beginListening() }
                } else {
                    print("Voice: authorization denied")
                }
            }
            return
        }

        guard status == .authorized else {
            print("Voice: not authorized (\(status.rawValue))")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.beginListening()
        }
    }

    func stopListening() {
        DispatchQueue.main.async { [weak self] in
            self?.cleanup()
            print("Voice: stopped")
        }
    }

    private func beginListening() {
        cleanup()
        print("Voice: beginning recognition...")

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("Voice: recognizer not available")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Don't require on-device — it may not be downloaded
        if #available(iOS 13, *) {
            request.requiresOnDeviceRecognition = false
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            print("Voice: bad input format ch=\(inputFormat.channelCount) rate=\(inputFormat.sampleRate)")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            try engine.start()
            isListeningState = true
            print("Voice: engine started, listening...")
        } catch {
            print("Voice: engine start failed: \(error)")
            cleanup()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                print("Voice: recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.cleanup() }
                return
            }

            guard let result = result else { return }
            let transcript = result.bestTranscription.formattedString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            print("Voice: heard '\(transcript)' (final=\(result.isFinal))")

            // Skip empty transcripts
            guard transcript.count >= 3 else { return }

            // Process known commands from partial results immediately
            // But DON'T process "unknown" from partials — wait for final
            let command = self.parseCommand(transcript)
            switch command {
            case .unknown:
                // Only process unknown on final result
                if result.isFinal {
                    self.processCommand(transcript)
                    DispatchQueue.main.async { self.cleanup() }
                }
            default:
                // Known command — act immediately from partial
                self.processCommand(transcript)
                DispatchQueue.main.async { self.cleanup() }
            }
        }
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        isListeningState = false
    }

    private func processCommand(_ transcript: String) {
        if let lastTime = lastCommandTime,
           Date().timeIntervalSince(lastTime) < commandCooldown { return }

        let command = parseCommand(transcript)
        lastCommandTime = Date()
        print("Voice: command = \(command)")

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.voiceCommandReceived(command)
        }
    }

    private func parseCommand(_ transcript: String) -> VoiceCommand {
        // Vision tricks first — these contain words that could collide
        // with the more general commands below.
        if transcript.contains("color") || transcript.contains("colour") { return .identifyColor }
        if transcript.contains("bill") || transcript.contains("dollar") ||
           transcript.contains("money") || transcript.contains("cash") ||
           transcript.contains("currency") { return .identifyBill }
        if transcript.contains("read") { return .readText }

        if transcript.contains("around") || transcript.contains("describe") || transcript.contains("surroundings") { return .whatsAround }
        if transcript.contains("safe") || transcript.contains("clear") { return .isSafe }
        if transcript.contains("left") { return .checkLeft }
        if transcript.contains("right") { return .checkRight }
        if transcript.contains("stop") || transcript.contains("pause") { return .stop }
        if transcript.contains("resume") || transcript.contains("start") || transcript.contains("go") { return .resume }
        if transcript.contains("help") { return .help }
        if transcript.contains("scan") { return .scan }
        return .unknown(transcript)
    }

    deinit { cleanup() }
}
