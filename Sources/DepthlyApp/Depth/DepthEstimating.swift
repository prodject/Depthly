import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

protocol DepthEstimating: Sendable {
    func estimateDepthMap(for pixelBuffer: CVPixelBuffer) async throws -> CIImage
}
