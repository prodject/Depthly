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
        let scaledMask = try makeScaledMaskImage(foregroundMask, extent: extent, settings: settings)

        if settings.viewMaskOnly {
            let maskPreview = scaledMask
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.0,
                    kCIInputContrastKey: 1.15,
                    kCIInputBrightnessKey: 0.0
                ])
            guard let cgImage = context.createCGImage(maskPreview, from: extent) else {
                throw DepthEstimatorError.modelUnavailable
            }
            return cgImage
        }

        let clearBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let foregroundImage = frameImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clearBackground,
                kCIInputMaskImageKey: scaledMask
            ]
        )
        let barsImage = try makeBarsImage(extent: extent, settings: settings)
        let finalImage = foregroundImage.composited(over: barsImage)

        guard let cgImage = context.createCGImage(finalImage, from: extent) else {
            throw DepthEstimatorError.modelUnavailable
        }
        return cgImage
    }

    private func makeScaledMaskImage(
        _ foregroundMask: CVPixelBuffer?,
        extent: CGRect,
        settings: EffectSettings
    ) throws -> CIImage {
        guard let foregroundMask else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        }

        let maskImage = CIImage(cvPixelBuffer: foregroundMask)
        let maskExtent = maskImage.extent
        let scaleX = extent.width / max(maskExtent.width, 1.0)
        let scaleY = extent.height / max(maskExtent.height, 1.0)
        let scaled = maskImage
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: extent)

        let softened = scaled.applyingGaussianBlur(sigma: max(0.0, settings.edgeSoftness * 12.0))
        return softened
    }

    private func makeBarsImage(extent: CGRect, settings: EffectSettings) throws -> CIImage {
        let width = Int(max(1.0, extent.width.rounded(.up)))
        let height = Int(max(1.0, extent.height.rounded(.up)))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DepthEstimatorError.modelUnavailable
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DepthEstimatorError.modelUnavailable
        }

        context.setAllowsAntialiasing(false)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(NSColor.black.cgColor)

        let border = max(0.0, min(0.25, settings.borderThickness))
        let borderX = max(1, Int(round(Double(width) * border)))
        let borderY = max(1, Int(round(Double(height) * border)))

        if borderX > 0 {
            context.fill(CGRect(x: 0, y: 0, width: borderX, height: height))
            context.fill(CGRect(x: width - borderX, y: 0, width: borderX, height: height))
        }
        if borderY > 0 {
            context.fill(CGRect(x: 0, y: 0, width: width, height: borderY))
            context.fill(CGRect(x: 0, y: height - borderY, width: width, height: borderY))
        }

        if settings.verticalBarsEnabled, settings.verticalBarDivisionCount.rawValue >= 2 {
            let thickness = max(0.0, min(0.45, settings.verticalBarThickness))
            let barWidth = max(1, Int(round(Double(width) * thickness)))
            let divisions = settings.verticalBarDivisionCount.rawValue
            for index in 1..<divisions {
                let center = Double(width) * Double(index) / Double(divisions)
                let x = max(0, Int(round(center)) - barWidth / 2)
                context.fill(CGRect(x: x, y: 0, width: barWidth, height: height))
            }
        }

        if settings.horizontalBarsEnabled {
            let thickness = max(0.0, min(0.45, settings.horizontalBarThickness))
            let barHeight = max(1, Int(round(Double(height) * thickness)))
            context.fill(CGRect(x: 0, y: 0, width: width, height: barHeight))
            context.fill(CGRect(x: 0, y: height - barHeight, width: width, height: barHeight))
        }

        guard let cgImage = context.makeImage() else {
            throw DepthEstimatorError.modelUnavailable
        }
        return CIImage(cgImage: cgImage).cropped(to: extent)
    }
}
