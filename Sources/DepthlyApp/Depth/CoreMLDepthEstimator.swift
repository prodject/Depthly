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
        inputName: String? = nil,
        outputImageProvider: @escaping (MLFeatureProvider) throws -> CIImage
    ) {
        self.model = model
        self.inputName = inputName ?? Self.defaultImageInputName(for: model) ?? "image"
        self.outputImageProvider = outputImageProvider
    }

    convenience init(modelURL: URL, inputName: String? = nil, outputName: String? = nil) async throws {
        let model = try await CoreMLDepthEstimator.loadModel(at: modelURL)
        let resolvedOutputName = outputName ?? Self.defaultImageOutputName(for: model) ?? "predicted_depth"
        self.init(model: model, inputName: inputName) { provider in
            guard let buffer = provider.featureValue(for: resolvedOutputName)?.imageBufferValue else {
                throw CoreMLDepthEstimatorError.missingImageOutput(resolvedOutputName)
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

    private static func defaultImageInputName(for model: MLModel) -> String? {
        model.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }?.key
            ?? model.modelDescription.inputDescriptionsByName.keys.first
    }

    private static func defaultImageOutputName(for model: MLModel) -> String? {
        model.modelDescription.outputDescriptionsByName.first { $0.value.type == .image }?.key
            ?? model.modelDescription.outputDescriptionsByName.keys.first
    }
}
