import CoreMedia
import CoreVideo
import Foundation

final class AdaptiveDepthEstimator: DepthEstimating {
    private let coreMLDepthEstimator: CoreMLDepthEstimator?
    private let fallbackEstimator: MockDepthEstimator

    init(modelURL: URL? = nil, fallbackEstimator: MockDepthEstimator = MockDepthEstimator()) {
        if let modelURL {
            self.coreMLDepthEstimator = try? CoreMLDepthEstimator(modelURL: modelURL)
        } else {
            self.coreMLDepthEstimator = nil
        }
        self.fallbackEstimator = fallbackEstimator
    }

    func estimateDepth(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMap {
        if let coreMLDepthEstimator {
            return try await coreMLDepthEstimator.estimateDepth(from: pixelBuffer, timestamp: timestamp)
        }

        return try await fallbackEstimator.estimateDepth(from: pixelBuffer, timestamp: timestamp)
    }
}
