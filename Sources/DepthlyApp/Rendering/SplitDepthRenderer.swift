import CoreGraphics
import CoreImage

final class SplitDepthRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var previousMask: CIImage?
    private var previousRawDepth: CIImage?

    private static let normalizeKernel: CIColorKernel = {
        guard let kernel = CIColorKernel(source: """
        kernel vec4 normalizeDepth(__sample s, float minValue, float maxValue) {
            float range = max(maxValue - minValue, 0.0001);
            float value = clamp((s.r - minValue) / range, 0.0, 1.0);
            return vec4(value, value, value, 1.0);
        }
        """) else {
            fatalError("Failed to build normalize kernel")
        }
        return kernel
    }()

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
        previousRawDepth = nil
    }

    func renderOverlay(
        frame: CVPixelBuffer,
        depthMap: CIImage?,
        settings: EffectSettings
    ) -> CGImage? {
        let frameImage = CIImage(cvPixelBuffer: frame)
        let extent = frameImage.extent.integral

        guard let depthMap else {
            let fallbackMask = previousMask ?? makeEmptyMask(extent: extent)
            return renderForegroundOverlay(frameImage: frameImage, mask: fallbackMask, settings: settings)
        }

        let stabilizedDepth = stabilizedDepthMap(from: depthMap, extent: extent, settings: settings)
        let mask = foregroundMask(from: stabilizedDepth, extent: extent, settings: settings)
        let smoothedMask = smooth(mask: mask, with: previousMask, factor: settings.temporalSmoothing, extent: extent)
        previousRawDepth = stabilizedDepth
        previousMask = smoothedMask

        return renderForegroundOverlay(frameImage: frameImage, mask: smoothedMask, settings: settings)
    }

    private func renderForegroundOverlay(frameImage: CIImage, mask: CIImage, settings: EffectSettings) -> CGImage? {
        let extent = frameImage.extent.integral
        let canvasExtent = extent
        let maskForForeground = settings.invertDepthMask ? inverted(mask: mask, extent: extent) : mask
        if settings.showMaskPreview {
            let preview = debugMaskPreview(mask: maskForForeground, depthMap: previousRawDepth, extent: extent)
            return context.createCGImage(preview, from: canvasExtent)
        }

        let stripeMask = verticalStripeMask(extent: extent, settings: settings)
        let expandedStripeMask = stripeMask
            .applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: max(2.0, settings.edgeSoftness * 0.7)
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(1.0, settings.edgeSoftness * 0.35)
            ])
            .cropped(to: extent)

        let transparentBackground = CIImage(color: .clear).cropped(to: canvasExtent)
        let bars = CIImage(color: .black)
            .cropped(to: canvasExtent)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: transparentBackground,
                kCIInputMaskImageKey: stripeMask
            ])

        let foreground = frameImage.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparentBackground,
            kCIInputMaskImageKey: maskForForeground
        ])

        let bandLimitedForeground = foreground.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparentBackground,
            kCIInputMaskImageKey: expandedStripeMask
        ])

        let foregroundShift = measuredForegroundShift(from: maskForForeground, extent: extent, settings: settings)
        let horizontalScale = 1.0 + (0.03 * settings.effectStrength)
        let horizontalPush = foregroundShift + max(settings.foregroundDisplacement, 0) * settings.effectStrength * 0.12
        let transform = CGAffineTransform(translationX: canvasExtent.midX, y: canvasExtent.midY)
            .scaledBy(x: horizontalScale, y: 1.0)
            .translatedBy(x: -extent.midX + horizontalPush, y: -extent.midY)

        let transformedForeground = bandLimitedForeground.transformed(by: transform)
        let composited = transformedForeground.composited(over: bars)
        return context.createCGImage(composited, from: canvasExtent)
    }

    private func debugMaskPreview(mask: CIImage, depthMap: CIImage?, extent: CGRect) -> CIImage {
        let normalizedDepth = depthMap.map {
            normalizeDepthDynamicRange($0, extent: extent)
        } ?? CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0)).cropped(to: extent)

        let depthBackground = normalizedDepth.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0),
            "inputColor1": CIColor(red: 0.72, green: 0.86, blue: 1.0, alpha: 1.0)
        ])

        let highlightedMask = mask
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.65,
                kCIInputBrightnessKey: 0.02
            ])
            .applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0),
                "inputColor1": CIColor(red: 1.0, green: 0.88, blue: 0.46, alpha: 1.0)
            ])

        return highlightedMask.composited(over: depthBackground.cropped(to: extent))
    }

    private func inverted(mask: CIImage, extent: CGRect) -> CIImage {
        mask
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

    private func stabilizedDepthMap(from depthMap: CIImage, extent: CGRect, settings: EffectSettings) -> CIImage {
        let scaled = scale(image: depthMap, toFit: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.0,
                kCIInputBrightnessKey: 0.0
            ])
            .applyingFilter("CIMedianFilter")
            .cropped(to: extent)

        let normalized = normalizeDepthDynamicRange(scaled, extent: extent)

        guard let previousRawDepth else { return normalized }
        let carry = min(max(settings.temporalSmoothing * 0.55, 0.0), 0.92)
        let mix = CIImage(color: CIColor(red: carry, green: carry, blue: carry, alpha: carry))
            .cropped(to: extent)

        return normalized.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: previousRawDepth,
            kCIInputMaskImageKey: mix
        ])
    }

    private func foregroundMask(from depthMap: CIImage, extent: CGRect, settings: EffectSettings) -> CIImage {
        let thresholded = Self.thresholdKernel.apply(
            extent: extent,
            arguments: [
                depthMap,
                settings.depthCutoff,
                max(0.002, Double(settings.edgeSoftness / max(extent.width, extent.height))),
                max(0.001, settings.effectStrength)
            ]
        ) ?? depthMap

        let eroded = thresholded.applyingFilter("CIMorphologyMinimum", parameters: [
            kCIInputRadiusKey: max(1.0, settings.edgeSoftness / 8.0)
        ])

        let expanded = eroded
            .applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: max(1.0, settings.edgeSoftness / 5.0)
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(0.5, settings.edgeSoftness * 0.7)
            ])
            .cropped(to: extent)

        return expanded
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.45
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

    private func normalizeDepthDynamicRange(_ image: CIImage, extent: CGRect) -> CIImage {
        guard let stats = minMax(for: image, extent: extent) else {
            return image.cropped(to: extent)
        }

        let dynamicRange = stats.max - stats.min
        guard dynamicRange > 0.0001 else {
            return image.cropped(to: extent)
        }

        return Self.normalizeKernel.apply(
            extent: extent,
            arguments: [image, stats.min, stats.max]
        )?.cropped(to: extent) ?? image.cropped(to: extent)
    }

    private func minMax(for image: CIImage, extent: CGRect) -> (min: Float, max: Float)? {
        let sampledImage = image.cropped(to: extent)
        let minimumImage = sampledImage.applyingFilter("CIAreaMinimum", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])
        let maximumImage = sampledImage.applyingFilter("CIAreaMaximum", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])

        guard let minValue = sampleSingleChannelValue(from: minimumImage),
              let maxValue = sampleSingleChannelValue(from: maximumImage) else {
            return nil
        }

        return (minValue, maxValue)
    }

    private func sampleSingleChannelValue(from image: CIImage) -> Float? {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .Rf,
            colorSpace: nil
        )
        return pixel[0].isFinite ? pixel[0] : nil
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
