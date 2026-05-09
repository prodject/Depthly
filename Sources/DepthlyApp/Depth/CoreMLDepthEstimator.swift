import CoreImage
import CoreML

enum CoreMLDepthEstimatorError: Error {
    case missingImageOutput(String)
    case unsupportedModelFormat(URL)
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

    convenience init(modelURL: URL, inputName: String = "image", outputName: String = "depth") async throws {
        let model = try await CoreMLDepthEstimator.loadModel(at: modelURL)
        self.init(model: model, inputName: inputName) { provider in
            guard let buffer = provider.featureValue(for: outputName)?.imageBufferValue else {
                throw CoreMLDepthEstimatorError.missingImageOutput(outputName)
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
            throw CoreMLDepthEstimatorError.unsupportedModelFormat(url)
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
