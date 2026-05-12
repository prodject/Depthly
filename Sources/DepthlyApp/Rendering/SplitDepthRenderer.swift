import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

final class SplitDepthRenderer {
    private let context: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: nil)
        }
    }

    func renderOverlay(frameBuffer: CVPixelBuffer, foregroundMask: CVPixelBuffer?, settings: EffectSettings) throws -> CGImage {
        let frameImage = CIImage(cvPixelBuffer: frameBuffer)
        let extent = frameImage.extent
        let clearBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)

        var foregroundImage: CIImage?
        if let foregroundMask {
            let maskExtent = CIImage(cvPixelBuffer: foregroundMask).extent
            let scaleX = extent.width / max(maskExtent.width, 1.0)
            let scaleY = extent.height / max(maskExtent.height, 1.0)
            let morphologyRadius = max(1.0, settings.edgeSoftness * 10.0 + 1.5)
            let maskImage = CIImage(cvPixelBuffer: foregroundMask)
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: extent)
                .applyingFilter(
                    "CIMorphologyMaximum",
                    parameters: ["inputRadius": morphologyRadius]
                )
                .applyingFilter(
                    "CIGammaAdjust",
                    parameters: ["inputPower": 0.75]
                )
            let softenedMask = maskImage
                .clampedToExtent()
                .applyingGaussianBlur(sigma: max(0.0, settings.edgeSoftness * 6.0))
                .cropped(to: extent)
            let extractedForeground = frameImage.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: clearBackground,
                    kCIInputMaskImageKey: softenedMask
                ]
            )

            let strength = max(0.0, min(1.0, settings.effectStrength))
            if strength < 1.0 {
                foregroundImage = extractedForeground.applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: strength)
                    ]
                )
            } else {
                foregroundImage = extractedForeground
            }
        }

        let finalImage = foregroundImage ?? clearBackground

        guard let cgImage = context.createCGImage(finalImage, from: extent) else {
            throw DepthEstimatorError.modelUnavailable
        }
        return cgImage
    }
}
