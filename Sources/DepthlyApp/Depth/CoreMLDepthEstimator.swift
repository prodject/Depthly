import CoreImage
import CoreML

enum CoreMLDepthEstimatorError: Error {
    case missingImageOutput(String)
}

final class CoreMLDepthEstimator: DepthEstimating, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let outputImageProvider: (MLFeatureProvider) throws -> CIImage

    init(
        model: MLModel,
        inputName: String = "image",
        outputImageProvider: @escaping (MLFeatureProvider) throws -> CIImage
    ) {
        self.model = model
        self.inputName = inputName
        self.outputImageProvider = outputImageProvider
    }

    convenience init(compiledModelURL: URL, inputName: String = "image", outputName: String = "depth") throws {
        let model = try MLModel(contentsOf: compiledModelURL, configuration: MLModelConfiguration())
        self.init(model: model, inputName: inputName) { provider in
            guard let buffer = provider.featureValue(for: outputName)?.imageBufferValue else {
                throw CoreMLDepthEstimatorError.missingImageOutput(outputName)
            }
            return CIImage(cvPixelBuffer: buffer)
        }
    }

    func estimateDepthMap(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        let features = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try await model.prediction(from: features)
        return try outputImageProvider(output)
    }
}
