import CoreMedia
import CoreVideo
import Foundation

final class HumanForegroundMaskProvider: ForegroundMaskProviding {
    private let visionProvider: VisionPersonSegmentationProvider
    private var lastStableMask: ForegroundMask?

    init(visionProvider: VisionPersonSegmentationProvider = VisionPersonSegmentationProvider()) {
        self.visionProvider = visionProvider
    }

    func makeForegroundMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> ForegroundMask {
        if let visionMask = try? await visionProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp) {
            lastStableMask = visionMask
            return visionMask
        }

        if let lastStableMask {
            return ForegroundMask(
                pixelBuffer: lastStableMask.pixelBuffer,
                confidence: lastStableMask.confidence,
                timestamp: timestamp
            )
        }

        throw DepthEstimatorError.modelUnavailable
    }
}
