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

    func estimateMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMask {
        guard let model else {
            throw DepthEstimatorError.modelUnavailable
        }

        // TODO: adapt these assumptions to the actual Core ML export of Depth Anything V2 Small.
        // The model's input name, preprocessing, output name, and output shape are model-specific.
        // For example, the model may expect:
        // - a resized RGB pixel buffer tensor
        // - normalized float input
        // - a single-channel depth logits output
        //
        // Wire the actual feature provider here once the model is exported.
        _ = model
        _ = pixelBuffer
        _ = timestamp
        throw DepthEstimatorError.unsupportedModelShape
    }
}
