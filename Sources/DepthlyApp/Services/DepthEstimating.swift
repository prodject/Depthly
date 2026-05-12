import CoreMedia
import CoreVideo
import Foundation

protocol DepthEstimating {
    func estimateDepth(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMap
}

enum DepthEstimatorError: Error {
    case modelUnavailable
    case unsupportedModelShape
}
