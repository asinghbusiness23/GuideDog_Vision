import Foundation
import CoreVideo
import CoreML
import Vision

/// Detection result
public struct Detection {
    public let label: String
    public let confidence: Float
    public let boundingBox: CGRect  // Normalized coordinates (0-1)
    public let classIndex: Int
    public let source: String       // "custom", "yolov8", or "finetune"
}

/// Multi-model CoreML detector for blind navigation
/// Model 1: YOLOv8n (80 COCO classes — people, vehicles, furniture, etc.) — PRIMARY
/// Model 2: Fine-tuned model (55 navigation classes — doors, stairs, columns, etc.) — SUPPLEMENTARY
public class ONNXDetector {
    // MARK: - Constants
    static let YOLOV8_CONF_THRESHOLD: Float = 0.3
    static let FINETUNE_CONF_THRESHOLD: Float = 0.45  // Higher threshold for less accurate model
    static let NMS_IOU_THRESHOLD: Float = 0.45

    // COCO 80 classes (YOLOv8n) — primary model
    static let cocoClassNames = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
        "chair", "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop",
        "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]

    // Safety-relevant COCO classes for blind navigation
    static let safetyRelevantCoco: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "bus", "truck", "train", "bench",
        "dog", "cat", "bird", "backpack", "suitcase", "handbag", "umbrella",
        "chair", "couch", "bed", "dining table", "toilet",
        "bottle", "cup", "knife", "scissors", "laptop", "cell phone", "book",
        "fire hydrant", "stop sign", "parking meter", "traffic light",
        "microwave", "oven", "toaster", "sink", "refrigerator",
        "clock", "vase", "tv"
    ]

    // Fine-tuned model classes (55 Obstacles for Blind classes)
    // Indices match the data.yaml sorted order: '0','1','10','11',...
    // The YAML sorts as strings, so index 0='0', 1='1', 2='10', 3='11', etc.
    // Actual class names mapped from the Roboflow dataset
    static let finetuneClassNames: [Int: String] = {
        // Numeric string sorted order from data.yaml: 0,1,10,11,12,...,19,2,20,...,29,3,...
        let yamlOrder = ["0","1","10","11","12","13","14","15","16","17","18","19",
                         "2","20","21","22","23","24","25","26","27","28","29",
                         "3","30","31","32","33","34","35","36","37","38","39",
                         "4","40","41","42","43","44","45","46","47","48","49",
                         "5","50","51","52","53","54","6","7","8","9"]
        // Real names in original numeric index order (0-54)
        let realNames = [
            "dish", "fish", "flask", "handle", "lamppost", "staircase", "train",
            "glass", "sofa", "airplane", "bag", "ball", "battery charger", "bed",
            "beside table", "bicycle", "bird", "bus", "car", "cat", "chair",
            "chicken", "child", "column", "computer", "cow", "cup", "desk",
            "dog", "donkey", "door", "glasses", "goat", "headphones", "horse",
            "hour", "jug", "monkey", "motorcycle", "oven", "person", "phone",
            "pigeon", "rabbit", "refrigerator", "sheep", "table", "tap",
            "television", "toilet", "tree", "wardrobe", "wash basin",
            "washing machine", "window"
        ]
        // Build mapping: yaml sorted index -> real name
        var mapping: [Int: String] = [:]
        for (idx, numStr) in yamlOrder.enumerated() {
            if let origIdx = Int(numStr), origIdx < realNames.count {
                mapping[idx] = realNames[origIdx]
            }
        }
        return mapping
    }()

    // Safety-relevant fine-tune classes
    static let safetyRelevantFinetune: Set<String> = [
        "door", "staircase", "column", "lamppost", "handle", "tap",
        "window", "desk", "table", "chair", "sofa", "bed", "beside table",
        "wardrobe", "wash basin", "washing machine", "refrigerator", "oven",
        "television", "computer", "phone", "toilet", "tree", "glass", "flask",
        "person", "child", "bicycle", "motorcycle", "bus", "car", "train",
        "bag", "cup", "dog", "cat"
    ]

    // MARK: - Properties
    private var yolov8Request: VNCoreMLRequest?
    private var finetuneRequest: VNCoreMLRequest?
    public private(set) var isReady = false
    private var hasYolov8Model = false
    private var hasFinetuneModel = false

    // MARK: - Initialization
    public init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModels()
        }
    }

    // MARK: - Model Loading
    private func loadModels() {
        // Load YOLOv8n — primary model (always available)
        if let yoloURL = findModelURL(name: "YOLOv8n") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let mlModel = try MLModel(contentsOf: yoloURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: mlModel)
                yolov8Request = VNCoreMLRequest(model: vnModel)
                yolov8Request?.imageCropAndScaleOption = .scaleFill
                hasYolov8Model = true
                print("CoreMLDetector: YOLOv8n loaded (80 COCO classes)")
            } catch {
                print("CoreMLDetector: Failed to load YOLOv8n — \(error.localizedDescription)")
            }
        }

        // Load fine-tuned model — supplementary (55 navigation classes)
        if let finetuneURL = findModelURL(name: "BlindGuideNav") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let mlModel = try MLModel(contentsOf: finetuneURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: mlModel)
                finetuneRequest = VNCoreMLRequest(model: vnModel)
                finetuneRequest?.imageCropAndScaleOption = .scaleFill
                hasFinetuneModel = true
                print("CoreMLDetector: BlindGuideNav loaded (55 navigation classes)")
            } catch {
                print("CoreMLDetector: Failed to load BlindGuideNav — \(error.localizedDescription)")
            }
        }

        isReady = hasYolov8Model || hasFinetuneModel
        print("CoreMLDetector: Ready=\(isReady) (yolov8=\(hasYolov8Model), finetune=\(hasFinetuneModel))")
    }

    private func findModelURL(name: String) -> URL? {
        // Check main bundle for compiled model
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            print("CoreMLDetector: Found \(name).mlmodelc in main bundle")
            return url
        }

        // Check BlindGuideModels resource bundle
        if let bundlePath = Bundle.main.path(forResource: "BlindGuideModels", ofType: "bundle"),
           let bundle = Bundle(path: bundlePath) {
            if let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
                print("CoreMLDetector: Found \(name).mlmodelc in BlindGuideModels bundle")
                return url
            }
        }

        // Try runtime compilation from .mlpackage
        if let packageURL = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            do {
                print("CoreMLDetector: Compiling \(name).mlpackage at runtime...")
                let compiledURL = try MLModel.compileModel(at: packageURL)
                return compiledURL
            } catch {
                print("CoreMLDetector: Runtime compile failed for \(name) — \(error)")
            }
        }

        // Check BlindGuideModels for .mlpackage too
        if let bundlePath = Bundle.main.path(forResource: "BlindGuideModels", ofType: "bundle"),
           let bundle = Bundle(path: bundlePath),
           let packageURL = bundle.url(forResource: name, withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                return compiledURL
            } catch {
                print("CoreMLDetector: Runtime compile failed for \(name) in bundle — \(error)")
            }
        }

        print("CoreMLDetector: Model '\(name)' not found in any bundle")
        return nil
    }

    // MARK: - Inference
    public func detect(pixelBuffer: CVPixelBuffer) -> [Detection] {
        guard isReady else { return [] }

        var allDetections: [Detection] = []

        // Run YOLOv8n first (primary, most reliable)
        if let request = yolov8Request {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([request])
                let detections = parseYolov8Results(request)
                allDetections.append(contentsOf: detections)
            } catch {
                print("CoreMLDetector: YOLOv8n inference failed — \(error)")
            }
        }

        // Run fine-tuned model (supplementary, higher threshold)
        if let request = finetuneRequest {
            let handler2 = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler2.perform([request])
                let detections = parseFinetuneResults(request)
                allDetections.append(contentsOf: detections)
            } catch {
                print("CoreMLDetector: Fine-tune model inference failed — \(error)")
            }
        }

        // Deduplicate — YOLOv8n takes priority for overlapping detections
        let merged = deduplicateDetections(allDetections)
        return merged.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Parse YOLOv8n Results
    private func parseYolov8Results(_ request: VNCoreMLRequest) -> [Detection] {
        // Vision auto-detected objects (NMS-exported model)
        if let results = request.results as? [VNRecognizedObjectObservation] {
            return results.compactMap { obs in
                guard let topLabel = obs.labels.first,
                      topLabel.confidence >= Self.YOLOV8_CONF_THRESHOLD,
                      Self.safetyRelevantCoco.contains(topLabel.identifier) else { return nil }

                let classIdx = Self.cocoClassNames.firstIndex(of: topLabel.identifier) ?? 0
                return Detection(
                    label: topLabel.identifier,
                    confidence: topLabel.confidence,
                    boundingBox: obs.boundingBox,
                    classIndex: classIdx,
                    source: "yolov8"
                )
            }
        }

        // Raw tensor output fallback [1, 84, 8400]
        if let results = request.results as? [VNCoreMLFeatureValueObservation] {
            return decodeYolov8RawOutput(results)
        }

        return []
    }

    private func decodeYolov8RawOutput(_ observations: [VNCoreMLFeatureValueObservation]) -> [Detection] {
        guard let firstObs = observations.first,
              let multiArray = firstObs.featureValue.multiArrayValue else { return [] }

        let pointer = multiArray.dataPointer.bindMemory(to: Float.self, capacity: multiArray.count)
        var detections: [Detection] = []

        let numDetections = 8400
        let numClasses = 80

        guard multiArray.count >= (4 + numClasses) * numDetections else {
            print("CoreMLDetector: YOLOv8 unexpected output size \(multiArray.count)")
            return []
        }

        for i in 0..<numDetections {
            let cx = pointer[0 * numDetections + i]
            let cy = pointer[1 * numDetections + i]
            let w = pointer[2 * numDetections + i]
            let h = pointer[3 * numDetections + i]

            var maxProb: Float = 0
            var maxIdx = 0
            for c in 0..<numClasses {
                let prob = pointer[(4 + c) * numDetections + i]
                if prob > maxProb {
                    maxProb = prob
                    maxIdx = c
                }
            }

            guard maxProb >= Self.YOLOV8_CONF_THRESHOLD else { continue }

            let label = maxIdx < Self.cocoClassNames.count ? Self.cocoClassNames[maxIdx] : "unknown"
            guard Self.safetyRelevantCoco.contains(label) else { continue }

            let left = max(0, (cx - w / 2) / 640)
            let top = max(0, (cy - h / 2) / 640)
            let bw = min(1, w / 640)
            let bh = min(1, h / 640)

            detections.append(Detection(
                label: label,
                confidence: maxProb,
                boundingBox: CGRect(x: CGFloat(left), y: CGFloat(top),
                                    width: CGFloat(bw), height: CGFloat(bh)),
                classIndex: maxIdx,
                source: "yolov8"
            ))
        }

        return applyNMS(detections)
    }

    // MARK: - Parse Fine-tuned Model Results
    private func parseFinetuneResults(_ request: VNCoreMLRequest) -> [Detection] {
        // Vision auto-detected objects
        if let results = request.results as? [VNRecognizedObjectObservation] {
            return results.compactMap { obs in
                guard let topLabel = obs.labels.first,
                      topLabel.confidence >= Self.FINETUNE_CONF_THRESHOLD else { return nil }

                // Map numeric label to real name if needed
                var labelName = topLabel.identifier
                if let idx = Int(labelName), let realName = Self.finetuneClassNames[idx] {
                    labelName = realName
                }

                guard Self.safetyRelevantFinetune.contains(labelName) else { return nil }

                return Detection(
                    label: labelName,
                    confidence: topLabel.confidence,
                    boundingBox: obs.boundingBox,
                    classIndex: 0,
                    source: "finetune"
                )
            }
        }

        // Raw tensor output fallback [1, 59, 8400] (4 bbox + 55 classes)
        if let results = request.results as? [VNCoreMLFeatureValueObservation] {
            return decodeFinetuneRawOutput(results)
        }

        return []
    }

    private func decodeFinetuneRawOutput(_ observations: [VNCoreMLFeatureValueObservation]) -> [Detection] {
        guard let firstObs = observations.first,
              let multiArray = firstObs.featureValue.multiArrayValue else { return [] }

        let pointer = multiArray.dataPointer.bindMemory(to: Float.self, capacity: multiArray.count)
        var detections: [Detection] = []

        let numClasses = 55
        // Try to determine number of detections from output shape
        let totalElements = multiArray.count
        let elementsPerDetection = 4 + numClasses
        let numDetections = totalElements / elementsPerDetection

        guard numDetections > 0 else {
            print("CoreMLDetector: Fine-tune unexpected output size \(totalElements)")
            return []
        }

        for i in 0..<numDetections {
            let cx = pointer[0 * numDetections + i]
            let cy = pointer[1 * numDetections + i]
            let w = pointer[2 * numDetections + i]
            let h = pointer[3 * numDetections + i]

            var maxProb: Float = 0
            var maxIdx = 0
            for c in 0..<numClasses {
                let prob = pointer[(4 + c) * numDetections + i]
                if prob > maxProb {
                    maxProb = prob
                    maxIdx = c
                }
            }

            guard maxProb >= Self.FINETUNE_CONF_THRESHOLD else { continue }

            let label = Self.finetuneClassNames[maxIdx] ?? "object_\(maxIdx)"
            guard Self.safetyRelevantFinetune.contains(label) else { continue }

            let left = max(0, (cx - w / 2) / 640)
            let top = max(0, (cy - h / 2) / 640)
            let bw = min(1, w / 640)
            let bh = min(1, h / 640)

            detections.append(Detection(
                label: label,
                confidence: maxProb,
                boundingBox: CGRect(x: CGFloat(left), y: CGFloat(top),
                                    width: CGFloat(bw), height: CGFloat(bh)),
                classIndex: maxIdx,
                source: "finetune"
            ))
        }

        return applyNMS(detections)
    }

    // MARK: - Deduplication
    private func deduplicateDetections(_ detections: [Detection]) -> [Detection] {
        // YOLOv8n is primary — keep all its detections
        // Fine-tuned model only adds detections that don't overlap with YOLOv8n
        var result: [Detection] = []
        let yoloDets = detections.filter { $0.source == "yolov8" }
        let finetuneDets = detections.filter { $0.source == "finetune" }

        result.append(contentsOf: yoloDets)

        for ftDet in finetuneDets {
            let overlaps = yoloDets.contains { yoloDet in
                calculateIoU(yoloDet.boundingBox, ftDet.boundingBox) > 0.3
            }
            if !overlaps {
                result.append(ftDet)
            }
        }

        return result
    }

    // MARK: - NMS
    private func applyNMS(_ detections: [Detection]) -> [Detection] {
        var result: [Detection] = []
        var remaining = detections.sorted { $0.confidence > $1.confidence }
        while !remaining.isEmpty {
            let current = remaining.removeFirst()
            result.append(current)
            remaining.removeAll { calculateIoU(current.boundingBox, $0.boundingBox) > Self.NMS_IOU_THRESHOLD }
        }
        return result
    }

    private func calculateIoU(_ box1: CGRect, _ box2: CGRect) -> Float {
        let intersection = box1.intersection(box2)
        let intersectionArea = intersection.width * intersection.height
        let union = box1.width * box1.height + box2.width * box2.height - intersectionArea
        guard union > 0 else { return 0 }
        return Float(intersectionArea / union)
    }
}
