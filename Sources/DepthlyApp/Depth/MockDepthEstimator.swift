import AVFoundation
import CoreImage

enum MockDepthEstimatorError: Error {
    case bufferCreationFailed
}

final class MockDepthEstimator: DepthEstimating, @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func estimateDepthMap(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = input.extent

        let grayscale = input
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.35
            ])

        let vignette = CIImage(color: .white)
            .cropped(to: extent)
            .applyingFilter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": max(extent.width, extent.height) * 0.08,
                "inputRadius1": max(extent.width, extent.height) * 0.75,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])

        let combined = grayscale
            .applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: vignette
            ])
            .cropped(to: extent)

        return combined
    }
}
