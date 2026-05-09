import AVFoundation
import CoreImage

enum MockDepthEstimatorError: Error {
    case bufferCreationFailed
}

final class MockDepthEstimator: DepthEstimating, @unchecked Sendable {
    func estimateDepthMap(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = input.extent

        let grayscale = input
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.15
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 1.6
            ])

        let focus = CIImage(color: .black)
            .cropped(to: extent)
            .applyingFilter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": max(extent.width, extent.height) * 0.10,
                "inputRadius1": max(extent.width, extent.height) * 0.62,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])

        let combined = grayscale
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: focus
            ])
            .cropped(to: extent)

        return combined
    }
}
