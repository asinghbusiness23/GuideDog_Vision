import UIKit
import CoreVideo

/// Demo overlay: colorizes the LiDAR depth map and renders it as a translucent
/// heatmap on top of the rest of the UI so a projector audience can see the
/// AI's depth perception.
///
///   < 0.5m  red          (critical)
///   < 1.0m  red-orange   (danger)
///   < 2.0m  orange       (caution)
///   < 3.0m  yellow-green (approaching)
///   3-5m    green        (safe)
///   > 5m    teal         (far)
///
/// Toggle via 3-finger tap (handled in ViewController).
final class DepthOverlayView: UIView {

    // MARK: - Subviews

    private let heatmapView = UIImageView()
    private let legendBar = UIView()
    private let legendLabel = UILabel()
    private let scaleStrip = UIView()

    // MARK: - Render state

    private let processingQueue = DispatchQueue(label: "com.guidedog.depthOverlay", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isProcessing = false
    private var pendingFrame: CVPixelBuffer?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        isUserInteractionEnabled = false
        clipsToBounds = true
        isHidden = true

        // Heatmap fills the whole view.
        heatmapView.frame = bounds
        heatmapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        heatmapView.contentMode = .scaleAspectFill
        heatmapView.alpha = 0.85
        addSubview(heatmapView)

        // Legend pill at the top.
        legendBar.translatesAutoresizingMaskIntoConstraints = false
        legendBar.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        legendBar.layer.cornerRadius = 14
        legendBar.layer.masksToBounds = true
        addSubview(legendBar)

        legendLabel.translatesAutoresizingMaskIntoConstraints = false
        legendLabel.text = "DEPTH HEATMAP"
        legendLabel.font = .monospacedSystemFont(ofSize: 13, weight: .heavy)
        legendLabel.textColor = .white
        legendLabel.textAlignment = .center
        legendBar.addSubview(legendLabel)

        // Color scale strip showing the gradient.
        scaleStrip.translatesAutoresizingMaskIntoConstraints = false
        scaleStrip.layer.cornerRadius = 8
        scaleStrip.layer.masksToBounds = true
        addSubview(scaleStrip)

        let scaleGradient = CAGradientLayer()
        scaleGradient.colors = [
            UIColor(red: 1.00, green: 0.00, blue: 0.00, alpha: 1).cgColor,   // red
            UIColor(red: 1.00, green: 0.31, blue: 0.00, alpha: 1).cgColor,   // red-orange
            UIColor(red: 1.00, green: 0.78, blue: 0.00, alpha: 1).cgColor,   // orange
            UIColor(red: 0.78, green: 1.00, blue: 0.00, alpha: 1).cgColor,   // yellow-green
            UIColor(red: 0.00, green: 0.86, blue: 0.24, alpha: 1).cgColor,   // green
            UIColor(red: 0.00, green: 0.51, blue: 0.63, alpha: 1).cgColor,   // teal
        ]
        scaleGradient.startPoint = CGPoint(x: 0, y: 0.5)
        scaleGradient.endPoint = CGPoint(x: 1, y: 0.5)
        scaleStrip.layer.addSublayer(scaleGradient)
        scaleStrip.layer.setValue(scaleGradient, forKey: "gradient")

        let scaleLabels = UIStackView()
        scaleLabels.translatesAutoresizingMaskIntoConstraints = false
        scaleLabels.axis = .horizontal
        scaleLabels.distribution = .equalSpacing
        addSubview(scaleLabels)
        for txt in ["close", "1m", "2m", "3m", "5m", "far"] {
            let l = UILabel()
            l.text = txt
            l.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
            l.textColor = UIColor.white.withAlphaComponent(0.85)
            l.layer.shadowColor = UIColor.black.cgColor
            l.layer.shadowOpacity = 0.9
            l.layer.shadowRadius = 2
            l.layer.shadowOffset = .zero
            scaleLabels.addArrangedSubview(l)
        }

        NSLayoutConstraint.activate([
            legendBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            legendBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            legendBar.heightAnchor.constraint(equalToConstant: 32),
            legendBar.widthAnchor.constraint(equalToConstant: 220),

            legendLabel.leadingAnchor.constraint(equalTo: legendBar.leadingAnchor, constant: 12),
            legendLabel.trailingAnchor.constraint(equalTo: legendBar.trailingAnchor, constant: -12),
            legendLabel.centerYAnchor.constraint(equalTo: legendBar.centerYAnchor),

            scaleStrip.topAnchor.constraint(equalTo: legendBar.bottomAnchor, constant: 8),
            scaleStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scaleStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scaleStrip.heightAnchor.constraint(equalToConstant: 14),

            scaleLabels.topAnchor.constraint(equalTo: scaleStrip.bottomAnchor, constant: 4),
            scaleLabels.leadingAnchor.constraint(equalTo: scaleStrip.leadingAnchor),
            scaleLabels.trailingAnchor.constraint(equalTo: scaleStrip.trailingAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let g = scaleStrip.layer.value(forKey: "gradient") as? CAGradientLayer {
            g.frame = scaleStrip.bounds
        }
    }

    // MARK: - Public API

    /// Feed a new depth map. Cheap to call every AR frame — the most recent
    /// pending frame is kept while one is being colorized so we never queue up.
    func update(depthMap: CVPixelBuffer) {
        if Thread.isMainThread, isHidden { return }

        stateLock.lock()
        if isProcessing {
            pendingFrame = depthMap
            stateLock.unlock()
            return
        }
        isProcessing = true
        stateLock.unlock()

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            let image = Self.colorize(depthMap: depthMap)
            DispatchQueue.main.async {
                if !self.isHidden { self.heatmapView.image = image }

                self.stateLock.lock()
                self.isProcessing = false
                let next = self.pendingFrame
                self.pendingFrame = nil
                self.stateLock.unlock()

                if let n = next { self.update(depthMap: n) }
            }
        }
    }

    func toggle() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isHidden.toggle()
            if self.isHidden { self.heatmapView.image = nil }
        }
    }

    // MARK: - Colorize

    private static func colorize(depthMap: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        let depths = base.assumingMemoryBound(to: Float32.self)
        let pixelCount = width * height
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)

        for i in 0..<pixelCount {
            let d = depths[i]
            var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 235
            if d.isFinite && d > 0.03 {
                if d < 0.5         { r = 255; g = 0;   b = 0   }
                else if d < 1.0    { r = 255; g = 80;  b = 0   }
                else if d < 2.0    { r = 255; g = 200; b = 0   }
                else if d < 3.0    { r = 200; g = 255; b = 0   }
                else if d < 5.0    { r = 0;   g = 220; b = 60  }
                else               { r = 0;   g = 130; b = 160 }
            } else {
                a = 0
            }
            rgba[i * 4]     = r
            rgba[i * 4 + 1] = g
            rgba[i * 4 + 2] = b
            rgba[i * 4 + 3] = a
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4,
                               space: colorSpace, bitmapInfo: bitmapInfo,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }

        // ARKit depth maps are landscape; rotate 90° CW for portrait phones.
        return UIImage(cgImage: cg, scale: 1.0, orientation: .right)
    }
}
