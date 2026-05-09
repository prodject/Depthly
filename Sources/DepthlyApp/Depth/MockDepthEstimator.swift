import AVFoundation
import CoreImage

enum MockForegroundMaskEstimatorError: Error {
    case bufferCreationFailed
}

final class MockForegroundMaskEstimator: ForegroundMaskEstimating, @unchecked Sendable {
    func estimateForegroundMask(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
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
                kCIInputContrastKey: 1.8,
                kCIInputBrightnessKey: 0.03
            ])
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.75,
                "inputHighlightAmount": 0.15
            ])
            .cropped(to: extent)

        let portraitBias = CIImage(color: .black)
            .cropped(to: extent)
            .applyingFilter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY * 1.08),
                "inputRadius0": extent.width * 0.16,
                "inputRadius1": max(extent.width, extent.height) * 0.62,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])
            .cropped(to: extent)

        let verticalBias = CIImage(color: .clear)
            .cropped(to: extent)
            .applyingFilter("CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: extent.midX, y: extent.maxY),
                "inputPoint1": CIVector(x: extent.midX, y: extent.minY + extent.height * 0.22),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0.28, green: 0.28, blue: 0.28, alpha: 1)
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.25
            ])
            .cropped(to: extent)

        let edgeGate = smoothedLuma
            .applyingFilter("CIEdges", parameters: [
                kCIInputIntensityKey: 4.5
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 1.8
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.7,
                kCIInputBrightnessKey: -0.04
            ])
            .cropped(to: extent)

        let portraitWeighted = subjectContrast
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: portraitBias
            ])
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: verticalBias
            ])
            .cropped(to: extent)

        let combined = portraitWeighted
            .applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: edgeGate
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 5.0
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 2.1,
                kCIInputBrightnessKey: -0.16
            ])
            .applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: 3.0
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 6.0
            ])
            .cropped(to: extent)

        return combined
    }
}
