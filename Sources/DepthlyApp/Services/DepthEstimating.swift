import CoreMedia
import CoreVideo
import Foundation

protocol DepthEstimating {
    func estimateMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMask
}

enum DepthEstimatorError: Error {
    case modelUnavailable
    case unsupportedModelShape
}
