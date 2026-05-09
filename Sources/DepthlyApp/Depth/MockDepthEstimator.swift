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
                kCIInputContrastKey: 1.28,
                kCIInputBrightnessKey: 0.02
            ])
            .cropped(to: extent)

        let smoothedLuma = grayscale
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.015,
                "inputSharpness": 0.28
            ])
            .cropped(to: extent)

        let subjectContrast = smoothedLuma
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.55
            ])
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.55,
                "inputHighlightAmount": 0.15
            ])
            .cropped(to: extent)

        let edges = smoothedLuma
            .applyingFilter("CIEdges", parameters: [
                kCIInputIntensityKey: 6.0
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 2.0
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 2.0,
                kCIInputBrightnessKey: -0.08
            ])
            .cropped(to: extent)

        let centerBias = CIImage(color: .black)
            .cropped(to: extent)
            .applyingFilter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": max(extent.width, extent.height) * 0.18,
                "inputRadius1": max(extent.width, extent.height) * 0.78,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])
            .cropped(to: extent)

        let saliency = subjectContrast
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: centerBias
            ])
            .cropped(to: extent)

        let combined = saliency
            .applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: edges
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 4.0
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.45,
                kCIInputBrightnessKey: -0.03
            ])
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: centerBias
            ])
            .cropped(to: extent)

        return combined
    }
}
