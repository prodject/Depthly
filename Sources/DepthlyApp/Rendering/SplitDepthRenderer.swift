import CoreGraphics
import CoreImage

final class SplitDepthRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var previousMask: CIImage?
    private var previousInputMask: CIImage?

    private static let thresholdKernel: CIColorKernel = {
        guard let kernel = CIColorKernel(source: """
        kernel vec4 thresholdMask(__sample s, float cutoff, float softness, float strength) {
            float lower = max(0.0, cutoff - softness);
            float upper = min(1.0, cutoff + softness);
            float value = smoothstep(lower, upper, s.r);
            value = pow(clamp(value, 0.0, 1.0), mix(1.6, 0.65, clamp(strength, 0.0, 1.0)));
            return vec4(value, value, value, value);
        }
        """) else {
            fatalError("Failed to build threshold kernel")
        }
        return kernel
    }()

    func reset() {
        previousMask = nil
        previousInputMask = nil
    }

    func renderOverlay(
        frame: CVPixelBuffer,
        foregroundMask: CIImage?,
        settings: EffectSettings
    ) -> CGImage? {
        let frameImage = CIImage(cvPixelBuffer: frame)
        let extent = frameImage.extent.integral

        guard let foregroundMask else {
            let fallbackMask = previousMask ?? makeEmptyMask(extent: extent)
            return renderForegroundOverlay(frameImage: frameImage, mask: fallbackMask, settings: settings)
        }

        let preparedMask = preparedForegroundMask(from: foregroundMask, extent: extent, settings: settings)
        let smoothedMask = smooth(mask: preparedMask, with: previousMask, factor: settings.temporalSmoothing, extent: extent)
        previousInputMask = preparedMask
        previousMask = smoothedMask

        return renderForegroundOverlay(frameImage: frameImage, mask: smoothedMask, settings: settings)
    }

    private func renderForegroundOverlay(frameImage: CIImage, mask: CIImage, settings: EffectSettings) -> CGImage? {
        let extent = frameImage.extent.integral
        let canvasExtent = extent
        if settings.showMaskPreview {
            let preview = debugMaskPreview(mask: mask, sourceMask: previousInputMask, frameImage: frameImage, extent: extent)
            return context.createCGImage(preview, from: canvasExtent)
        }

        let stripeMask = verticalStripeMask(extent: extent, settings: settings)
        let cutoutMask = mask
            .applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: max(1.0, settings.borderThickness * 0.05)
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(0.5, settings.edgeSoftness * 0.12)
            ])
            .cropped(to: extent)

        let transparentBackground = CIImage(color: .clear).cropped(to: canvasExtent)
        let bars = CIImage(color: .black)
            .cropped(to: canvasExtent)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: transparentBackground,
                kCIInputMaskImageKey: stripeMask
            ])

        let horizontalScale = 1.0 + (0.004 * settings.effectStrength)
        let transform = CGAffineTransform(translationX: canvasExtent.midX, y: canvasExtent.midY)
            .scaledBy(x: horizontalScale, y: 1.0)
            .translatedBy(x: -extent.midX, y: -extent.midY)

        let transformedCutoutMask = cutoutMask
            .transformed(by: transform)
            .cropped(to: extent)

        let overlay = transparentBackground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bars,
            kCIInputMaskImageKey: transformedCutoutMask
        ])

        return context.createCGImage(overlay, from: canvasExtent)
    }

    private func debugMaskPreview(mask: CIImage, sourceMask: CIImage?, frameImage: CIImage, extent: CGRect) -> CIImage {
        let baseFrame = frameImage
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.15,
                kCIInputBrightnessKey: -0.02
            ])
            .cropped(to: extent)

        let sourcePreview = (sourceMask ?? mask)
            .applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 0.0),
                "inputColor1": CIColor(red: 0.45, green: 0.74, blue: 1.0, alpha: 0.55)
            ])
            .cropped(to: extent)

        let cleanedMask = mask.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0),
            "inputColor1": CIColor(red: 1.0, green: 0.86, blue: 0.22, alpha: 1.0)
        ])

        return cleanedMask
            .composited(over: sourcePreview)
            .composited(over: baseFrame)
    }

    private func inverted(image: CIImage, extent: CGRect) -> CIImage {
        image
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)
    }

    private func measuredForegroundShift(from mask: CIImage, extent: CGRect, settings: EffectSettings) -> CGFloat {
        let targetWidth: CGFloat = 72
        let scale = targetWidth / max(extent.width, 1)
        let scaledExtent = CGRect(
            x: 0,
            y: 0,
            width: targetWidth,
            height: max(1, round(extent.height * scale))
        ).integral

        let scaledMask = mask
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: scaledExtent)

        guard let cgImage = context.createCGImage(scaledMask, from: scaledMask.extent),
              let centroidX = centroidX(of: cgImage) else {
            return 0
        }

        let normalized = (centroidX / CGFloat(max(cgImage.width, 1))) - 0.5
        let maxShift = max(settings.borderThickness, 6) * 0.45 * settings.effectStrength
        return normalized * maxShift
    }

    private func centroidX(of cgImage: CGImage) -> CGFloat? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total: Double = 0
        var weightedX: Double = 0

        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let value = Double(buffer[rowStart + x]) / 255.0
                total += value
                weightedX += Double(x) * value
            }
        }

        guard total > 0 else { return nil }
        return CGFloat(weightedX / total)
    }

    private func preparedForegroundMask(from inputMask: CIImage, extent: CGRect, settings: EffectSettings) -> CIImage {
        let scaledMask = scale(image: inputMask, toFit: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.8,
                kCIInputBrightnessKey: -0.08
            ])
            .applyingFilter("CIMedianFilter")
            .cropped(to: extent)

        let correctedMask = settings.invertDepthMask ? inverted(image: scaledMask, extent: extent) : scaledMask

        let thresholded = Self.thresholdKernel.apply(
            extent: extent,
            arguments: [
                correctedMask,
                settings.depthCutoff,
                max(0.002, Double(settings.edgeSoftness / max(extent.width, extent.height))),
                max(0.001, settings.effectStrength)
            ]
        ) ?? correctedMask

        let eroded = thresholded.applyingFilter("CIMorphologyMinimum", parameters: [
            kCIInputRadiusKey: max(1.0, settings.edgeSoftness / 7.0)
        ])

        let expanded = eroded
            .applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: max(1.0, settings.edgeSoftness / 5.5)
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(0.5, settings.edgeSoftness * 0.30)
            ])
            .cropped(to: extent)

        return expanded
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 2.1
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

    private func makeEmptyMask(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }

    private func verticalStripeMask(extent: CGRect, settings: EffectSettings) -> CIImage {
        let barCount = 3
        let barWidth = max(settings.borderThickness, 8)
        let step = extent.width / CGFloat(barCount + 1)

        var mask = makeEmptyMask(extent: extent)
        for index in 1...barCount {
            let centerX = extent.minX + step * CGFloat(index)
            let rect = CGRect(
                x: centerX - (barWidth / 2),
                y: extent.minY,
                width: barWidth,
                height: extent.height
            ).integral

            let stripe = CIImage(color: .white).cropped(to: rect)
            mask = stripe.composited(over: mask)
        }

        return mask.cropped(to: extent)
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
