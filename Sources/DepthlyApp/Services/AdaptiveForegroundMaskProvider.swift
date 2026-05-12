import CoreMedia
import CoreVideo
import Foundation

final class AdaptiveForegroundMaskProvider: ForegroundMaskProviding {
    private let visionProvider: VisionPersonSegmentationProvider
    private let fallbackProvider: ForegroundMaskProviding

    init(
        visionProvider: VisionPersonSegmentationProvider = VisionPersonSegmentationProvider(),
        fallbackProvider: ForegroundMaskProviding = MockForegroundMaskProvider()
    ) {
        self.visionProvider = visionProvider
        self.fallbackProvider = fallbackProvider
    }

    func makeForegroundMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> ForegroundMask {
        if let visionMask = try? await visionProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp) {
            return visionMask
        }

        return try await fallbackProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
    }
}
