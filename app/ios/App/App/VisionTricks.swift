import Foundation
import Vision
import CoreImage
import CoreVideo
import UIKit

/// On-demand vision helpers for user-initiated voice commands:
///   • "read this"        → on-device OCR
///   • "what color"       → dominant color of the center region
///   • "what bill"        → US currency denomination via OCR + cross-check
///
/// All three run fully on-device. No cloud, no API keys, works offline.
final class VisionTricks {

    static let shared = VisionTricks()
    private init() {}

    // MARK: - OCR ("read this")

    func recognizeText(in pixelBuffer: CVPixelBuffer,
                       completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, _ in
            guard let obs = request.results as? [VNRecognizedTextObservation], !obs.isEmpty else {
                DispatchQueue.main.async { completion("No text found.") }
                return
            }

            // Sort top-to-bottom so the spoken text reads in natural order.
            let lines = obs
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            let combined = lines.joined(separator: ". ")
            // Cap length so the user isn't trapped listening to a wall of text.
            let trimmed = combined.count > 240 ? String(combined.prefix(240)) + "…" : combined
            DispatchQueue.main.async {
                completion(trimmed.isEmpty ? "No text found." : trimmed)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([request]) }
            catch {
                DispatchQueue.main.async { completion("Couldn't read text. Try again.") }
            }
        }
    }

    // MARK: - Color ("what color is this")

    /// Returns a human-friendly color name for the dominant color in the
    /// center 30% of the frame. Uses CIAreaAverage → HSL classification.
    func identifyColor(in pixelBuffer: CVPixelBuffer) -> String {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let side = min(extent.width, extent.height) * 0.3
        let centerRect = CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )

        guard let avgFilter = CIFilter(name: "CIAreaAverage") else { return "unknown color" }
        avgFilter.setValue(ciImage.cropped(to: centerRect), forKey: kCIInputImageKey)
        avgFilter.setValue(CIVector(cgRect: centerRect), forKey: kCIInputExtentKey)
        guard let output = avgFilter.outputImage else { return "unknown color" }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        let r = Float(bitmap[0]) / 255
        let g = Float(bitmap[1]) / 255
        let b = Float(bitmap[2]) / 255
        return Self.classify(r: r, g: g, b: b)
    }

    private static func classify(r: Float, g: Float, b: Float) -> String {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let delta = maxC - minC

        // Greyscale axis
        if delta < 0.08 {
            switch l {
            case ..<0.12: return "black"
            case ..<0.35: return "dark gray"
            case ..<0.65: return "gray"
            case ..<0.88: return "light gray"
            default:      return "white"
            }
        }

        // Hue (degrees)
        var h: Float
        if maxC == r      { h = (g - b) / delta + (g < b ? 6 : 0) }
        else if maxC == g { h = (b - r) / delta + 2 }
        else              { h = (r - g) / delta + 4 }
        h *= 60

        let lightPrefix = l < 0.28 ? "dark " : (l > 0.78 ? "light " : "")

        switch h {
        case 0..<12, 348...360: return "\(lightPrefix)red"
        case 12..<40:           return "\(lightPrefix)orange"
        case 40..<65:           return "\(lightPrefix)yellow"
        case 65..<165:          return "\(lightPrefix)green"
        case 165..<200:         return "\(lightPrefix)teal"
        case 200..<255:         return "\(lightPrefix)blue"
        case 255..<290:         return "\(lightPrefix)purple"
        case 290..<348:         return "\(lightPrefix)pink"
        default:                return "\(lightPrefix)color"
        }
    }

    // MARK: - Currency ("what's this bill")

    /// Identifies a US bill by OCR'ing the denomination digits AND requiring
    /// at least one corroborating word (e.g. "TWENTY", "FEDERAL", "DOLLARS").
    /// This avoids false positives from random "20" signs or speed limits.
    func identifyCurrency(in pixelBuffer: CVPixelBuffer,
                          completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, _ in
            guard let obs = request.results as? [VNRecognizedTextObservation], !obs.isEmpty else {
                DispatchQueue.main.async { completion("No bill detected. Hold it flat in good light.") }
                return
            }
            let lines = obs.compactMap { $0.topCandidates(1).first?.string.uppercased() }
            let allText = lines.joined(separator: " ")

            let hasCurrencyMarker =
                allText.contains("FEDERAL RESERVE") ||
                allText.contains("UNITED STATES") ||
                allText.contains("DOLLARS") ||
                allText.contains("THE UNITED STATES")

            // Match larger denominations first so "100" doesn't get caught by "10" or "1".
            let denominations: [(digits: String, word: String, spoken: String)] = [
                ("100", "HUNDRED", "one hundred dollars"),
                ("50",  "FIFTY",   "fifty dollars"),
                ("20",  "TWENTY",  "twenty dollars"),
                ("10",  "TEN",     "ten dollars"),
                ("5",   "FIVE",    "five dollars"),
                ("1",   "ONE",     "one dollar"),
            ]

            for d in denominations {
                let digitRegex = "\\b\(d.digits)\\b"
                let hasDigit = lines.contains { $0.range(of: digitRegex, options: .regularExpression) != nil }
                let hasWord  = allText.contains(d.word)

                // Confident: digit + word, or digit + currency marker.
                if hasDigit && (hasWord || hasCurrencyMarker) {
                    DispatchQueue.main.async { completion(d.spoken + ".") }
                    return
                }
            }

            DispatchQueue.main.async {
                completion("Can't identify the bill. Hold it flat with the front facing the camera.")
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([request]) }
            catch {
                DispatchQueue.main.async { completion("Couldn't read bill. Try again.") }
            }
        }
    }
}
