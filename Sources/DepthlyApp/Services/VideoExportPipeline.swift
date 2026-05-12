import AVFoundation
import Foundation

struct ExportRequest {
    let sourceURL: URL
    let destinationURL: URL
    let settings: EffectSettings
}

protocol VideoExportPipeline {
    func export(_ request: ExportRequest) async throws
}

final class CoreImageExportPipeline: VideoExportPipeline {
    func export(_ request: ExportRequest) async throws {
        // TODO: Implement offline export with AVAssetReader + AVAssetWriter.
        // Read frames from request.sourceURL, run the same mask/render pipeline,
        // and write the transformed frames into request.destinationURL.
        _ = request
        throw CocoaError(.featureUnsupported)
    }
}
