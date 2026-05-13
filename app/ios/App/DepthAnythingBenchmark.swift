// DepthAnythingBenchmark.swift
//
// Standalone validation tool for the non-Pro iPhone path. Loads the
// converted Depth-Anything CoreML model, runs N inferences on a dummy
// 256x256 frame, prints median / min / max / p95 to the Xcode console.
//
// How to run:
//   1. Make sure DepthAnythingSmall.mlpackage is in the App target
//      (drag it into Xcode's project navigator, check the App target).
//   2. Call DepthAnythingBenchmark.run() from
//      AppDelegate.application(_:didFinishLaunchingWithOptions:)
//   3. Build + run on a physical iPhone 11 (or whatever non-Pro device
//      you want to validate).
//   4. Watch the Xcode console for the "=== Depth-Anything benchmark"
//      block.
//
// Remove the call when done. This file is throwaway diagnostic code.

import CoreML
import CoreVideo
import Foundation
import UIKit

final class DepthAnythingBenchmark {

    static func run() {
        print("=== Depth-Anything benchmark starting ===")

        // Load model with all compute units enabled (CPU / GPU / Neural Engine).
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model: MLModel
        do {
            // Xcode auto-generates a class from the .mlpackage. The
            // generated class is named after the file (DepthAnythingSmall).
            // If the auto-generated initializer isn't available yet
            // (because the project hasn't been built since adding the
            // model), this code may not compile — Xcode will surface
            // the right error.
            let inst = try DepthAnythingSmall(configuration: config)
            model = inst.model
        } catch {
            print("[Benchmark] ERROR loading model: \(error)")
            return
        }

        // Inspect the model spec so we have visibility into what shape
        // the input wants and what the device picked for execution.
        print("[Benchmark] Model description:")
        print("  Inputs:")
        for (name, desc) in model.modelDescription.inputDescriptionsByName {
            print("    \(name): \(desc.type) — \(desc)")
        }
        print("  Outputs:")
        for (name, desc) in model.modelDescription.outputDescriptionsByName {
            print("    \(name): \(desc.type) — \(desc)")
        }

        // Build a dummy 256x256 BGRA pixel buffer. The model's image input
        // accepts RGB; iOS pixel buffers are BGRA by default. CoreML
        // handles the channel reorder automatically for ImageType inputs.
        guard let buffer = makePixelBuffer(width: 256, height: 256) else {
            print("[Benchmark] ERROR: pixel buffer creation failed")
            return
        }

        // Build the MLFeatureProvider input — name must match the model's
        // declared input name (we set it to "pixel_values" during convert).
        let inputProvider: MLFeatureProvider
        do {
            inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "pixel_values": MLFeatureValue(pixelBuffer: buffer)
            ])
        } catch {
            print("[Benchmark] ERROR building feature provider: \(error)")
            return
        }

        // Warm up — first inference always carries one-time loading cost.
        for _ in 0..<3 {
            _ = try? model.prediction(from: inputProvider)
        }

        // Real benchmark: 20 timed runs.
        var times: [Double] = []
        for _ in 0..<20 {
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                _ = try model.prediction(from: inputProvider)
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                times.append(elapsed)
            } catch {
                print("[Benchmark] prediction error: \(error)")
                return
            }
        }

        times.sort()
        let median = times[times.count / 2]
        let minMs = times.first ?? 0
        let maxMs = times.last ?? 0
        let p95 = times[Int(Double(times.count) * 0.95)]
        let avg = times.reduce(0, +) / Double(times.count)

        print("=== RESULTS ===")
        print(String(format: "  avg:    %6.1f ms", avg))
        print(String(format: "  median: %6.1f ms", median))
        print(String(format: "  min:    %6.1f ms", minMs))
        print(String(format: "  p95:    %6.1f ms", p95))
        print(String(format: "  max:    %6.1f ms", maxMs))
        print("================")

        // Interpretation guide
        print("[Benchmark] Targets:")
        print("    < 200ms  → ship as Phase B at 5 fps in protection loop")
        print("    200-400  → ship at 2.5 fps; consider INT8 quantization later")
        print("    400-800  → enable iPhone 12+ only; iPhone 11 stays camera-only without depth")
        print("    > 800ms  → too slow; need a smaller model")
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}
