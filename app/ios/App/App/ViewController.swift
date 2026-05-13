import UIKit
import Capacitor
import ARKit
import AVFoundation
import CoreImage
import Speech

class ViewController: CAPBridgeViewController, WKScriptMessageHandler {

    private var engine: NavigationEngine?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    var latestPixelBuffer: CVPixelBuffer?
    private var cameraPreviewOn = false
    private lazy var voiceController = VoiceCommandController()
    // Standalone speech for welcome screens (before engine starts)
    private let standalonesynth = AVSpeechSynthesizer()

    // Demo overlay — colorized LiDAR heatmap, toggled by 3-finger tap.
    private var depthOverlay: DepthOverlayView?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        print("VC: viewDidLoad — webView exists: \(webView != nil)")

        // Configure audio session early so welcome screen speech works
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowBluetooth, .mixWithOthers, .duckOthers])
            try audioSession.setActive(true)
            // Don't force speaker — let Bluetooth stay connected if paired
            let hasBT = audioSession.currentRoute.outputs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
            if !hasBT { try audioSession.overrideOutputAudioPort(.speaker) }
        } catch {
            print("VC: audio session error: \(error)")
        }

        webView?.configuration.userContentController.add(self, name: "speak")
        webView?.configuration.userContentController.add(self, name: "scanRequest")
        webView?.configuration.userContentController.add(self, name: "cameraToggle")
        webView?.configuration.userContentController.add(self, name: "voiceCommand")
        webView?.configuration.userContentController.add(self, name: "engineStart")

        // Log when webView finishes loading
        webView?.navigationDelegate = self as? WKNavigationDelegate

        installDepthOverlay()

        // Pre-warm the non-LiDAR depth model on a background queue so its
        // 1-5s JIT compile happens while the user is reading the privacy
        // and help screens. By the time engineStart fires, the model is
        // already loaded and NavigationEngine.init returns instantly
        // rather than freezing the main thread.
        //
        // Skipped on LiDAR-equipped devices since they never instantiate
        // DepthAnythingProcessor.
        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            DepthAnythingProcessor.preload()
        }

        print("VC: viewDidLoad complete")
    }

    /// Set up the demo heatmap overlay above the webView, plus a 3-finger
    /// tap recognizer to toggle it from the stage during a demo.
    private func installDepthOverlay() {
        let overlay = DepthOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        depthOverlay = overlay

        // 3-finger tap toggles the heatmap. Attached to self.view so it fires
        // even when the webView would otherwise capture touches.
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleDepthOverlay))
        tap.numberOfTouchesRequired = 3
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func toggleDepthOverlay() {
        depthOverlay?.toggle()
    }

    override func capacitorDidLoad() {
        print("VC: capacitorDidLoad — waiting for user to dismiss welcome screens")
        // Engine starts when JS sends "engineStart" message after user taps through privacy + help
    }

    // MARK: - Engine

    private func startEngine() {
        let e = NavigationEngine()
        engine = e

        // Bridge depth readings to JS
        e.onDepthUpdate = { [weak self] center, left, right in
            self?.sendJS(String(
                format: "if(window.__onLiDARDepth){window.__onLiDARDepth(%.3f,%.3f,%.3f);}",
                center, left, right
            ))
        }

        // Camera frames: stash for AI, send preview if camera toggle is on
        e.onCameraFrame = { [weak self] pixelBuffer in
            guard let self = self else { return }
            self.latestPixelBuffer = pixelBuffer
            if self.cameraPreviewOn {
                self.sendCameraFrame(pixelBuffer)
            }
        }

        // Bridge YOLO detections to JS
        e.onDetectionEvent = { [weak self] label, direction in
            let safe = label.replacingOccurrences(of: "'", with: "\\'")
            self?.sendJS("if(window.__onDetection){window.__onDetection('\(safe)','\(direction)');}")
        }

        // Feed the demo heatmap overlay (no-op while it's hidden).
        e.onDepthMap = { [weak self] depthMap in
            self?.depthOverlay?.update(depthMap: depthMap)
        }

        e.start()

        // Connect voice commands to engine
        voiceController.delegate = e

        sendJS("if(window.__onNativeReady){window.__onNativeReady(\(e.hasLiDAR));}")
        print("⚡️ NavigationEngine started (LiDAR: \(e.hasLiDAR))")
    }

    // MARK: - Script Message Handlers

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "speak":
            guard let text = message.body as? String, !text.isEmpty else { return }
            // Single space = cancel current speech
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                standalonesynth.stopSpeaking(at: .immediate)
                return
            }
            if let e = engine {
                e.speakText(text)
            } else {
                standalonesynth.stopSpeaking(at: .immediate)
                let u = AVSpeechUtterance(string: text)
                u.rate = 0.5
                u.volume = 1.0
                standalonesynth.speak(u)
            }

        case "scanRequest":
            engine?.triggerManualScan()

        case "cameraToggle":
            if let on = message.body as? Bool {
                cameraPreviewOn = on
                if !on {
                    sendJS("if(window.__onNativeFrame){window.__onNativeFrame(null);}")
                }
            }

        case "voiceCommand":
            let action = message.body as? String ?? "toggle"
            print("VC: voiceCommand received: \(action), isListening=\(voiceController.isListening)")
            if action == "stop" || (action == "toggle" && voiceController.isListening) {
                voiceController.stopListening()
            } else {
                voiceController.startListening()
            }

        case "engineStart":
            standalonesynth.stopSpeaking(at: .immediate)
            guard engine == nil else { break }

            // Check if all permissions already granted — if so, start immediately
            let camOK = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized

            if camOK && micOK && speechOK {
                print("VC: all permissions granted — starting engine immediately")
                startEngine()
            } else {
                print("VC: requesting permissions...")
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        SFSpeechRecognizer.requestAuthorization { _ in
                            DispatchQueue.main.async {
                                self?.startEngine()
                            }
                        }
                    }
                }
            }

        default: break
        }
    }

    // MARK: - Camera Frame → JS (only when camera toggle is ON)

    private func sendCameraFrame(_ pixelBuffer: CVPixelBuffer) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            var ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)

            // 720p at decent quality — only runs when camera toggle is on
            let scale = min(720.0 / ciImage.extent.width, 960.0 / ciImage.extent.height, 1.0)
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            let uiImage = UIImage(cgImage: cgImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.7) else { return }
            let base64 = jpegData.base64EncodedString()

            self.sendJS("if(window.__onNativeFrame){window.__onNativeFrame('\(base64)');}")
        }
    }

    // MARK: - Helpers

    private func sendJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
