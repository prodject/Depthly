import CoreGraphics
import CoreImage

final class SplitDepthRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var previousMask: CIImage?

    private static let thresholdKernel: CIColorKernel = {
        guard let kernel = CIColorKernel(source: """
        kernel vec4 thresholdMask(__sample s, float cutoff, float softness, float strength) {
            float lower = max(0.0, cutoff - softness);
            float upper = min(1.0, cutoff + softness);
            float value = smoothstep(lower, upper, s.r);
            value = pow(clamp(value, 0.0, 1.0), max(strength, 0.001));
            return vec4(value, value, value, value);
        }
        """) else {
            fatalError("Failed to build threshold kernel")
        }
        return kernel
    }()

    func renderOverlay(
        frame: CVPixelBuffer,
        depthMap: CIImage?,
        settings: EffectSettings
    ) -> CGImage? {
        let frameImage = CIImage(cvPixelBuffer: frame)
        let extent = frameImage.extent.integral

        guard let depthMap else {
            return renderForegroundOverlay(frameImage: frameImage, mask: previousMask ?? makeFullMask(extent: extent), settings: settings)
        }

        let mask = foregroundMask(from: depthMap, extent: extent, settings: settings)
        let smoothedMask = smooth(mask: mask, with: previousMask, factor: settings.temporalSmoothing, extent: extent)
        previousMask = smoothedMask

        return renderForegroundOverlay(frameImage: frameImage, mask: smoothedMask, settings: settings)
    }

    private func renderForegroundOverlay(frameImage: CIImage, mask: CIImage, settings: EffectSettings) -> CGImage? {
        let extent = frameImage.extent.integral
        let border = max(settings.borderThickness, 0)
        let canvasExtent = CGRect(
            x: extent.minX - border,
            y: extent.minY,
            width: extent.width + border * 2,
            height: extent.height
        ).integral
        let transparentBackground = CIImage(color: .clear).cropped(to: canvasExtent)

        let foreground = frameImage.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparentBackground,
            kCIInputMaskImageKey: mask
        ])

        let horizontalScale = 1.0 + (0.12 * settings.effectStrength)
        let horizontalPush = border * 0.12 * settings.effectStrength
        let transform = CGAffineTransform(translationX: canvasExtent.midX, y: canvasExtent.midY)
            .scaledBy(x: horizontalScale, y: 1.0)
            .translatedBy(x: -extent.midX + horizontalPush, y: -extent.midY)

        let transformedForeground = foreground.transformed(by: transform)
        let canvas = CIImage(color: .clear).cropped(to: canvasExtent)
        let composited = transformedForeground.composited(over: canvas)

        return context.createCGImage(composited, from: canvasExtent)
    }

    private func foregroundMask(from depthMap: CIImage, extent: CGRect, settings: EffectSettings) -> CIImage {
        let depthScaled = scale(image: depthMap, toFit: extent)
        let normalizedDepth = depthScaled
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.2
            ])
            .cropped(to: extent)

        let thresholded = Self.thresholdKernel.apply(
            extent: extent,
            arguments: [
                normalizedDepth,
                settings.depthCutoff,
                max(0.002, Double(settings.edgeSoftness / max(extent.width, extent.height))),
                max(0.001, settings.effectStrength)
            ]
        ) ?? normalizedDepth

        return thresholded
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: settings.edgeSoftness
            ])
            .cropped(to: extent)
    }

    private func scale(image: CIImage, toFit extent: CGRect) -> CIImage {
        let sourceExtent = image.extent.integral
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return image }

        let scaleX = extent.width / sourceExtent.width
        let scaleY = extent.height / sourceExtent.height
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        return image.transformed(by: transform).cropped(to: extent)
    }

    private func makeFullMask(extent: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: extent)
    }

    private func smooth(mask: CIImage, with previous: CIImage?, factor: Double, extent: CGRect) -> CIImage {
        guard let previous else { return mask }
        let clamped = max(0.0, min(1.0, factor))
        guard clamped > 0 else { return mask }

        let mix = CIImage(color: CIColor(red: clamped, green: clamped, blue: clamped, alpha: clamped))
            .cropped(to: extent)

        return mask.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: previous,
            kCIInputMaskImageKey: mix
        ])
    }
}
