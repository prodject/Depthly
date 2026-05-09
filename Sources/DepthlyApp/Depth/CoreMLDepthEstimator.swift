import CoreImage
import CoreML
import CoreVideo

enum CoreMLForegroundMaskEstimatorError: Error {
    case missingImageOutput(String)
    case unsupportedModelFormat(URL)
    case invalidImageConstraint(String)
    case pixelBufferCreationFailed
}

final class CoreMLForegroundMaskEstimator: ForegroundMaskEstimating, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let outputImageProvider: (MLFeatureProvider) throws -> CIImage
    private let inputImageConstraint: MLImageConstraint?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    init(
        model: MLModel,
        inputName: String? = nil,
        outputImageProvider: @escaping (MLFeatureProvider) throws -> CIImage
    ) {
        self.model = model
        self.inputName = inputName ?? Self.defaultImageInputName(for: model) ?? "image"
        self.outputImageProvider = outputImageProvider
        self.inputImageConstraint = model.modelDescription.inputDescriptionsByName[self.inputName]?.imageConstraint
    }

    convenience init(modelURL: URL, inputName: String? = nil, outputName: String? = nil) async throws {
        let model = try await CoreMLForegroundMaskEstimator.loadModel(at: modelURL)
        let resolvedOutputName = outputName ?? Self.defaultImageOutputName(for: model) ?? "predicted_depth"
        self.init(model: model, inputName: inputName) { provider in
            guard let buffer = provider.featureValue(for: resolvedOutputName)?.imageBufferValue else {
                throw CoreMLForegroundMaskEstimatorError.missingImageOutput(resolvedOutputName)
            }
            return CIImage(cvPixelBuffer: buffer)
        }
    }

    private static func loadModel(at url: URL) async throws -> MLModel {
        let configuration = MLModelConfiguration()

        switch url.pathExtension.lowercased() {
        case "mlmodelc":
            return try await MLModel.load(contentsOf: url, configuration: configuration)
        case "mlpackage", "mlmodel":
            let compiledURL = try await MLModel.compileModel(at: url)
            return try await MLModel.load(contentsOf: compiledURL, configuration: configuration)
        default:
            throw CoreMLForegroundMaskEstimatorError.unsupportedModelFormat(url)
        }
    }

    func estimateForegroundMask(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        let preparedPixelBuffer = try prepareInputPixelBuffer(pixelBuffer)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: preparedPixelBuffer)
        ])
        let output = try await model.prediction(from: features)
        return try outputImageProvider(output)
    }

    private func prepareInputPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let constraint = inputImageConstraint else {
            return pixelBuffer
        }

        let targetWidth = constraint.pixelsWide
        let targetHeight = constraint.pixelsHigh
        guard targetWidth > 0, targetHeight > 0 else {
            throw CoreMLForegroundMaskEstimatorError.invalidImageConstraint(inputName)
        }

        let currentWidth = CVPixelBufferGetWidth(pixelBuffer)
        let currentHeight = CVPixelBufferGetHeight(pixelBuffer)
        if currentWidth == targetWidth, currentHeight == targetHeight {
            return pixelBuffer
        }

        let pixelFormat = constraint.pixelFormatType
        var resizedBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            pixelFormat,
            attrs as CFDictionary,
            &resizedBuffer
        )
        guard status == kCVReturnSuccess, let resizedBuffer else {
            throw CoreMLForegroundMaskEstimatorError.pixelBufferCreationFailed
        }

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(targetWidth) / max(sourceImage.extent.width, 1)
        let sy = CGFloat(targetHeight) / max(sourceImage.extent.height, 1)
        let resizedImage = sourceImage
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        context.render(resizedImage, to: resizedBuffer)
        return resizedBuffer
    }

    private static func defaultImageInputName(for model: MLModel) -> String? {
        model.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }?.key
            ?? model.modelDescription.inputDescriptionsByName.keys.first
    }

    private static func defaultImageOutputName(for model: MLModel) -> String? {
        model.modelDescription.outputDescriptionsByName.first { $0.value.type == .image }?.key
            ?? model.modelDescription.outputDescriptionsByName.keys.first
    }
}

typealias CoreMLDepthEstimator = CoreMLForegroundMaskEstimator
