// DepthAnythingProcessor.swift
//
// Camera-based depth pipeline for iPhones without LiDAR.
//
// Loads the converted Depth-Anything Small CoreML model
// (DepthAnythingSmall.mlpackage), runs it on captured camera frames,
// samples the resulting depth map into left / center / right zones, and
// (when calibrated against known-distance detections) emits those zones
// in absolute meters.
//
// Calibration model:
//   Depth-Anything outputs relative depth where HIGHER values = CLOSER.
//   We pair an object's triangulated distance (computed by
//   NavigationEngine.estimateDistanceFromSize) with the model's depth
//   value at the same bounding box centre, giving a per-frame anchor:
//       scale = relativeDepth × realDistanceInMetres
//   That scale is EMA-smoothed across detections. Once it's been seeded
//   (calibrationScale != nil), every subsequent depth pixel converts to
//   metres via:
//       metres = scale / relativeDepth
//
// Until the first calibration anchor arrives the processor still runs
// inference (so the depth map is ready for sampling at detection time)
// but its onZones callback yields nil for all three zones. The host
// engine treats that the same as "no depth", letting non-depth layers
// (object detection, mesh classifier on Pro devices, cloud AI) do the
// safety work alone for the first few seconds.

import CoreML
import CoreImage
import CoreVideo
import Foundation

final class DepthAnythingProcessor {

    // MARK: - Static preload
    //
    // The CoreML model is ~47MB and its first-load JIT compile takes
    // 1-5s on non-Pro devices. When the model loads synchronously inside
    // NavigationEngine.init (which runs on the main thread in response
    // to the engineStart message), the UI freezes for that window — the
    // help screen is dismissed but the live camera feed hasn't appeared
    // yet, so it looks like the app is hung.
    //
    // preload() lets the caller kick the load off earlier — typically
    // from ViewController.viewDidLoad — so by the time the user taps
    // through privacy + help and engineStart fires, the model is
    // already JIT-compiled and init() returns instantly.

    private static var preloadedModel: DepthAnythingSmall?
    private static var preloadInFlight = false
    private static let preloadLock = NSLock()

    /// Begin loading the depth model on a background queue. Safe to call
    /// repeatedly — subsequent calls are no-ops if a load is already
    /// in flight or already complete. Only worth calling on non-LiDAR
    /// devices where DepthAnythingProcessor actually gets instantiated.
    static func preload() {
        preloadLock.lock()
        if preloadedModel != nil || preloadInFlight {
            preloadLock.unlock()
            return
        }
        preloadInFlight = true
        preloadLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            do {
                let m = try DepthAnythingSmall(configuration: config)
                preloadLock.lock()
                preloadedModel = m
                preloadInFlight = false
                preloadLock.unlock()
                print("[DepthAnything] Preload complete — model ready for engineStart")
            } catch {
                preloadLock.lock()
                preloadInFlight = false
                preloadLock.unlock()
                print("[DepthAnything] Preload failed: \(error). Will retry synchronously on demand.")
            }
        }
    }

    // MARK: - Model

    private let model: DepthAnythingSmall?
    private let queue = DispatchQueue(label: "guidedog.depth-anything", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Inference state

    private var inFlight: Bool = false
    /// Latest depth array, flattened in row-major order. Used to sample
    /// at specific bounding-box centres for calibration.
    private var latestDepth: [Float]?
    /// Output spatial size that the converted model emits. We declared
    /// a 256 input and the model internally downsamples to 252.
    private let outputWidth = 252
    private let outputHeight = 252

    // MARK: - Calibration

    /// Multiplier s.t. metres ≈ scale / relativeDepth.
    private var calibrationScale: Float?
    /// EMA blend factor. Higher = react faster, more noisy.
    private let calibrationAlpha: Float = 0.3

    // MARK: - Output

    /// Fires on the main thread after each successful inference. Values
    /// are in metres if calibrated, nil otherwise.
    var onZones: ((_ leftM: Float?, _ centerM: Float?, _ rightM: Float?) -> Void)?

    var isReady: Bool { return model != nil }
    var isCalibrated: Bool { return calibrationScale != nil }

    // MARK: - Init

    init() {
        // Fast path: preload() was called early and finished. The shared
        // instance is reused — engine init returns essentially instantly.
        Self.preloadLock.lock()
        let preloaded = Self.preloadedModel
        Self.preloadLock.unlock()

        if let m = preloaded {
            self.model = m
            print("[DepthAnything] Using preloaded model — non-Pro depth path active (instant init)")
            return
        }

        // Slow path: preload either wasn't called or is still in flight
        // (rare — the user blasted through privacy + help in under a
        // second). Load synchronously here. Same behaviour as before the
        // preload optimisation was added.
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let wrapper = try DepthAnythingSmall(configuration: config)
            self.model = wrapper
            print("[DepthAnything] Model loaded synchronously — non-Pro depth path active")
        } catch {
            print("[DepthAnything] Failed to load model: \(error)")
            self.model = nil
        }
    }

    // MARK: - Public

    /// Provide a known-distance anchor to the calibrator. Called from
    /// NavigationEngine after pinhole triangulation produces a metre
    /// estimate for a detected object.
    ///
    /// - Parameters:
    ///   - triangulatedDistance: estimated metres from bounding-box size
    ///   - bboxCenterNormalized: detection centre in [0,1]×[0,1]
    func provideCalibration(triangulatedDistance: Float, bboxCenterNormalized: CGPoint) {
        // Constrain to a sensible mid-range where triangulation is most
        // reliable. Very near / very far estimates from bbox size carry
        // too much error to be useful calibration anchors.
        guard triangulatedDistance >= 0.5, triangulatedDistance <= 5.0 else { return }
        guard let depth = latestDepth else { return }

        // Map normalized coords to output array indices.
        let cx = max(0.0, min(1.0, Double(bboxCenterNormalized.x)))
        let cy = max(0.0, min(1.0, Double(bboxCenterNormalized.y)))
        let xi = max(0, min(outputWidth - 1, Int(Double(outputWidth) * cx)))
        let yi = max(0, min(outputHeight - 1, Int(Double(outputHeight) * cy)))
        let rel = depth[yi * outputWidth + xi]

        // Skip if the sampled pixel is near the noise floor — calibrating
        // off a near-zero relative value blows the scale up.
        guard rel > 1.0 else { return }

        let newScale = rel * triangulatedDistance
        if let existing = calibrationScale {
            calibrationScale = existing * (1.0 - calibrationAlpha) + newScale * calibrationAlpha
        } else {
            calibrationScale = newScale
            print("[DepthAnything] Initial calibration locked in: scale=\(newScale)")
        }
    }

    /// Kick off one inference if none is in flight. Safe to call from
    /// any thread; result is delivered to onZones on the main thread.
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !inFlight, let model = model else { return }
        inFlight = true

        queue.async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.inFlight = false } }

            guard let resized = self.resize(pixelBuffer, to: 256) else { return }

            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "pixel_values": MLFeatureValue(pixelBuffer: resized)
                ])
                let prediction = try model.model.prediction(from: provider)
                guard let arr = prediction.featureValue(for: "depth")?.multiArrayValue else {
                    return
                }

                // Flatten the multi-array into a plain Float buffer.
                let count = arr.count
                var flat = [Float](repeating: 0, count: count)
                let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
                for i in 0..<count { flat[i] = ptr[i] }
                self.latestDepth = flat

                // Sample L / C / R representative values.
                let zones = self.sampleZones(flat)
                let (leftM, centerM, rightM) = self.zonesInMeters(zones)

                DispatchQueue.main.async {
                    self.onZones?(leftM, centerM, rightM)
                }
            } catch {
                print("[DepthAnything] inference error: \(error)")
            }
        }
    }

    // MARK: - Sampling

    /// Returns representative relative-depth values per zone:
    ///   left, right → median (rejects edge noise)
    ///   center      → 80th percentile (biased toward the closest pixel,
    ///                 since higher relative = closer)
    /// nil if a zone had no usable samples.
    private func sampleZones(_ depth: [Float]) -> (left: Float?, center: Float?, right: Float?) {
        // Match LiDAR processing: scan top 25%–65% vertical band (skip
        // floor / sky). 3 columns.
        let yStart = Int(Float(outputHeight) * 0.25)
        let yEnd   = Int(Float(outputHeight) * 0.65)
        let col1   = outputWidth / 3
        let col2   = (outputWidth / 3) * 2
        let step   = 2

        var lefts: [Float] = []
        var centers: [Float] = []
        var rights: [Float] = []

        for y in stride(from: yStart, to: yEnd, by: step) {
            let row = y * outputWidth
            for x in stride(from: 0, to: outputWidth, by: step) {
                let v = depth[row + x]
                // Sanity bounds on Depth-Anything output (typical range
                // a few units to a couple dozen). Reject inf/nan.
                guard v.isFinite, v > 0.5, v < 100.0 else { continue }
                if x < col1       { lefts.append(v) }
                else if x < col2  { centers.append(v) }
                else              { rights.append(v) }
            }
        }
        return (
            left:   median(lefts),
            center: percentile(centers, 0.8),
            right:  median(rights)
        )
    }

    /// Convert per-zone relative depths to metres via the current
    /// calibration. Returns nil triple if not yet calibrated.
    private func zonesInMeters(_ zones: (left: Float?, center: Float?, right: Float?))
        -> (Float?, Float?, Float?) {
        guard let scale = calibrationScale, scale > 0 else { return (nil, nil, nil) }
        func toM(_ rel: Float?) -> Float? {
            guard let rel = rel, rel > 0 else { return nil }
            // Clamp absurd values that fall through any sanity check.
            let m = scale / rel
            return max(0.2, min(20.0, m))
        }
        return (toM(zones.left), toM(zones.center), toM(zones.right))
    }

    // MARK: - Utilities

    private func resize(_ buffer: CVPixelBuffer, to size: Int) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let scaleX = CGFloat(size) / ciImage.extent.width
        let scaleY = CGFloat(size) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let out = output else { return nil }
        context.render(scaled, to: out)
        return out
    }
}

// MARK: - Free-standing array helpers (file-private)

private func median(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func percentile(_ values: [Float], _ p: Float) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let idx = max(0, min(sorted.count - 1, Int(Float(sorted.count) * p)))
    return sorted[idx]
}
