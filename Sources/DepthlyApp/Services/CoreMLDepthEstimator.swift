import CoreML
import CoreMedia
import CoreVideo
import Foundation

final class CoreMLDepthEstimator: DepthEstimating {
    private let model: MLModel?

    init(modelURL: URL? = nil) throws {
        guard let modelURL else {
            self.model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    func estimateDepth(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMap {
        guard let model else {
            throw DepthEstimatorError.modelUnavailable
        }

        // TODO: adapt these assumptions to the actual Core ML export of Depth Anything V2 Small.
        // The model's input name, preprocessing, output name, and output shape are model-specific.
        // Typical adaptation points:
        // - resize to the model's required input size on the long edge
        // - convert to RGB if the export does not accept CVPixelBuffer directly
        // - normalize per the export config
        // - map the model output tensor back into a one-channel depth map
        //
        // Wire the real Core ML feature provider here once the model is exported.
        _ = model
        _ = pixelBuffer
        _ = timestamp
        throw DepthEstimatorError.unsupportedModelShape
    }
}
