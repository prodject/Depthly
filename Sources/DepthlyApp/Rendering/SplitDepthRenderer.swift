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
        let canvasExtent = extent
        let transparentBackground = CIImage(color: .clear).cropped(to: canvasExtent)
        let foregroundShift = measuredForegroundShift(from: mask, extent: extent, settings: settings)
        let background = renderStripedBackground(frameImage: frameImage, extent: extent, settings: settings, foregroundShift: foregroundShift)

        let foreground = frameImage.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparentBackground,
            kCIInputMaskImageKey: mask
        ])

        let horizontalScale = 1.0 + (0.12 * settings.effectStrength)
        let horizontalPush = foregroundShift + max(settings.borderThickness, 0) * 0.08 * settings.effectStrength
        let transform = CGAffineTransform(translationX: canvasExtent.midX, y: canvasExtent.midY)
            .scaledBy(x: horizontalScale, y: 1.0)
            .translatedBy(x: -extent.midX + horizontalPush, y: -extent.midY)

        let transformedForeground = foreground.transformed(by: transform)
        let composited = transformedForeground.composited(over: background)

        return context.createCGImage(composited, from: canvasExtent)
    }

    private func renderStripedBackground(
        frameImage: CIImage,
        extent: CGRect,
        settings: EffectSettings,
        foregroundShift: CGFloat
    ) -> CIImage {
        let barCount = 3
        let barWidth = max(settings.borderThickness, 12)
        let sliceWidth = extent.width / CGFloat(barCount + 1)

        var overlay = CIImage(color: .black).cropped(to: extent)
        let displacement = max(settings.borderThickness, 0) * 0.18 * settings.effectStrength
        let sceneShift = foregroundShift * 0.35
        let sliceOffsets: [CGFloat] = [
            sceneShift - displacement * 0.75,
            sceneShift - displacement * 0.25,
            sceneShift + displacement * 0.25,
            sceneShift + displacement * 0.75
        ]

        for index in 0...barCount {
            let sliceRect = CGRect(
                x: extent.minX + CGFloat(index) * sliceWidth,
                y: extent.minY,
                width: index == barCount ? extent.maxX - (extent.minX + CGFloat(index) * sliceWidth) : sliceWidth,
                height: extent.height
            ).integral

            let slice = frameImage.cropped(to: sliceRect)
            let movedSlice = slice.transformed(by: CGAffineTransform(translationX: sliceOffsets[index], y: 0))
            overlay = movedSlice.composited(over: overlay)
        }

        for index in 1...barCount {
            let centerX = extent.minX + sliceWidth * CGFloat(index)
            let barRect = CGRect(
                x: centerX - barWidth / 2,
                y: extent.minY,
                width: barWidth,
                height: extent.height
            ).integral

            let bar = renderBarStripe(in: barRect)
            overlay = bar.composited(over: overlay)
        }

        return overlay
    }

    private func renderBarStripe(in rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)).cropped(to: rect)
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
        let maxShift = max(settings.borderThickness, 6) * 1.2 * settings.effectStrength
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
