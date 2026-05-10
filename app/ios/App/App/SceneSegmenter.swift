import Vision
import CoreML
import ARKit

// MARK: - Scene Segmentation (DeepLabV3)
// Segments the camera frame into semantic regions (floor, wall, person, chair, etc.)
// This replaces cloud AI for detecting stairs, furniture, and other scene elements
// that the ARKit mesh classifier doesn't cover.

class SceneSegmenter {

    // MARK: - PASCAL VOC Class Labels
    // DeepLabV3 outputs 21 classes from the PASCAL VOC dataset.
    // We map these to navigation-relevant categories.

    enum SceneClass: Int, CaseIterable {
        case background = 0
        case aeroplane = 1
        case bicycle = 2
        case bird = 3
        case boat = 4
        case bottle = 5
        case bus = 6
        case car = 7
        case cat = 8
        case chair = 9
        case cow = 10
        case diningTable = 11
        case dog = 12
        case horse = 13
        case motorbike = 14
        case person = 15
        case pottedPlant = 16
        case sheep = 17
        case sofa = 18
        case train = 19
        case tvMonitor = 20

        var label: String {
            switch self {
            case .background: return "Background"
            case .aeroplane: return "Aeroplane"
            case .bicycle: return "Bicycle"
            case .bird: return "Bird"
            case .boat: return "Boat"
            case .bottle: return "Bottle"
            case .bus: return "Bus"
            case .car: return "Car"
            case .cat: return "Cat"
            case .chair: return "Chair"
            case .cow: return "Cow"
            case .diningTable: return "Dining Table"
            case .dog: return "Dog"
            case .horse: return "Horse"
            case .motorbike: return "Motorbike"
            case .person: return "Person"
            case .pottedPlant: return "Potted Plant"
            case .sheep: return "Sheep"
            case .sofa: return "Sofa"
            case .train: return "Train"
            case .tvMonitor: return "TV"
            }
        }

        /// Is this class relevant for navigation safety?
        var isNavigationRelevant: Bool {
            switch self {
            case .person, .bicycle, .car, .bus, .motorbike:
                return true  // Moving hazards
            case .chair, .diningTable, .sofa, .tvMonitor:
                return true  // Static obstacles
            case .dog, .cat, .horse, .cow, .sheep, .train, .pottedPlant:
                return false // Not relevant for walking (plants are noise, not hazards)
            case .background, .aeroplane, .boat, .bird, .bottle:
                return false
            }
        }

        /// Priority for announcement (lower = more urgent)
        var priority: Int {
            switch self {
            case .car, .bus, .motorbike: return 1  // Vehicles — highest danger
            case .bicycle: return 2
            case .person: return 3
            case .dog, .horse, .cow: return 4              // Animals
            case .chair, .diningTable, .sofa: return 5     // Furniture
            default: return 10
            }
        }
    }

    // MARK: - Segmentation Result

    struct SegmentationResult {
        /// The dominant class in the center of the frame (where the user is walking)
        let centerClass: SceneClass

        /// The dominant class on the left third
        let leftClass: SceneClass

        /// The dominant class on the right third
        let rightClass: SceneClass

        /// All non-background classes detected, sorted by pixel coverage (highest first)
        let detectedClasses: [(sceneClass: SceneClass, coverage: Float)]
    }

    // MARK: - Properties

    private var vnModel: VNCoreMLModel?
    private var request: VNCoreMLRequest?
    private var isProcessing = false

    private(set) var latestResult: SegmentationResult?
    private(set) var isReady = false

    // MARK: - Init

    init() {
        // Load model in background to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModel()
        }
    }

    // MARK: - Model Loading

    private func loadModel() {
        do {
            // Xcode compiles both .mlmodel and .mlpackage into .mlmodelc at build time
            guard let modelURL = Bundle.main.url(forResource: "DeepLabV3", withExtension: "mlmodelc") else {
                print("❌ SEGMENTER: DeepLabV3.mlmodelc not found in bundle.")
                print("   Run convert_deeplabv3.py on your Mac, then add the .mlpackage to Xcode.")
                return
            }

            let mlModel = try MLModel(contentsOf: modelURL)
            vnModel = try VNCoreMLModel(for: mlModel)

            request = VNCoreMLRequest(model: vnModel!) { [weak self] request, error in
                self?.handleResults(request: request, error: error)
            }
            request?.imageCropAndScaleOption = .scaleFill

            isReady = true
            print("✅ SEGMENTER: DeepLabV3 loaded successfully")

        } catch {
            print("❌ SEGMENTER: Failed to load model — \(error.localizedDescription)")
        }
    }

    // MARK: - Run Segmentation

    /// Call with the AR frame's capturedImage. Runs async on background thread.
    func segment(pixelBuffer: CVPixelBuffer) {
        guard let request = request, !isProcessing else { return }

        isProcessing = true

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isProcessing = false }

            do {
                try handler.perform([request])
            } catch {
                print("❌ SEGMENTER: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Process Results

    private func handleResults(request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let firstResult = results.first,
              let multiArray = firstResult.featureValue.multiArrayValue else {
            return
        }

        // Output shape may be [1, 21, H, W] (4D) or [21, H, W] (3D)
        // CoreML sometimes strips the batch dimension
        let numClasses = 21
        let dims = multiArray.shape.count
        let height: Int
        let width: Int

        if dims == 4 {
            height = multiArray.shape[2].intValue
            width = multiArray.shape[3].intValue
        } else if dims == 3 {
            height = multiArray.shape[1].intValue
            width = multiArray.shape[2].intValue
        } else {
            print("❌ SEGMENTER: Unexpected output shape with \(dims) dimensions")
            return
        }

        guard height > 0 && width > 0 else { return }

        // Get raw pointer for fast access
        guard multiArray.dataType == .float32 else {
            print("❌ SEGMENTER: Expected Float32, got \(multiArray.dataType.rawValue)")
            return
        }
        let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)

        // Split into three zones (left, center, right)
        let col1 = width / 3
        let col2 = (width / 3) * 2

        // Sample the center rows (middle 60%)
        let startRow = Int(Float(height) * 0.2)
        let endRow = Int(Float(height) * 0.8)
        let rowStep = 8  // Sample every 8th row for speed

        // Class vote counters per zone
        var leftVotes = [Int](repeating: 0, count: numClasses)
        var centerVotes = [Int](repeating: 0, count: numClasses)
        var rightVotes = [Int](repeating: 0, count: numClasses)
        var totalVotes = [Int](repeating: 0, count: numClasses)

        for y in stride(from: startRow, to: endRow, by: rowStep) {
            for x in stride(from: 0, to: width, by: 8) {  // Sample every 8th column
                // Find argmax class for this pixel
                var maxVal: Float = -Float.greatestFiniteMagnitude
                var maxClass = 0

                for c in 0..<numClasses {
                    let idx = c * height * width + y * width + x
                    let val = pointer[idx]
                    if val > maxVal {
                        maxVal = val
                        maxClass = c
                    }
                }

                // Vote
                totalVotes[maxClass] += 1
                if x < col1 {
                    leftVotes[maxClass] += 1
                } else if x < col2 {
                    centerVotes[maxClass] += 1
                } else {
                    rightVotes[maxClass] += 1
                }
            }
        }

        // Find dominant class per zone (ignoring background)
        let leftClass = dominantClass(from: leftVotes)
        let centerClass = dominantClass(from: centerVotes)
        let rightClass = dominantClass(from: rightVotes)

        // Calculate coverage for all detected classes
        let totalPixels = totalVotes.reduce(0, +)
        var detected: [(SceneClass, Float)] = []
        for i in 1..<numClasses {  // Skip background (0)
            if totalVotes[i] > 0, let sc = SceneClass(rawValue: i) {
                let coverage = Float(totalVotes[i]) / Float(max(totalPixels, 1))
                if coverage > 0.02 {  // At least 2% of frame
                    detected.append((sc, coverage))
                }
            }
        }
        detected.sort { $0.1 > $1.1 }  // Sort by coverage descending

        latestResult = SegmentationResult(
            centerClass: centerClass,
            leftClass: leftClass,
            rightClass: rightClass,
            detectedClasses: detected
        )
    }

    /// Returns the dominant non-background class, or .background if nothing else found
    private func dominantClass(from votes: [Int]) -> SceneClass {
        var maxVotes = 0
        var maxClass = 0

        for i in 1..<votes.count {  // Skip background
            if votes[i] > maxVotes {
                maxVotes = votes[i]
                maxClass = i
            }
        }

        // Only return non-background if it has meaningful coverage
        let totalZoneVotes = votes.reduce(0, +)
        if maxVotes > 0 && Float(maxVotes) / Float(max(totalZoneVotes, 1)) > 0.05 {
            return SceneClass(rawValue: maxClass) ?? .background
        }

        return .background
    }
}
