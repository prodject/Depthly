import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

protocol ForegroundMaskEstimating: Sendable {
    func estimateForegroundMask(for pixelBuffer: CVPixelBuffer) async throws -> CIImage
}

typealias DepthEstimating = ForegroundMaskEstimating
