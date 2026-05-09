import CoreImage
import CoreVideo
import Foundation
import Vision

enum VisionSaliencyForegroundMaskEstimatorError: Error {
    case missingObservation
    case pixelBufferCreationFailed
}

final class VisionSaliencyForegroundMaskEstimator: ForegroundMaskEstimating, @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let targetLongSide: CGFloat

    init(targetLongSide: CGFloat = 384) {
        self.targetLongSide = targetLongSide
    }

    func estimateForegroundMask(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        let preparedPixelBuffer = try prepareInputPixelBuffer(pixelBuffer)
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        request.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1

        let handler = VNImageRequestHandler(cvPixelBuffer: preparedPixelBuffer, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first.flatMap(SaliencyImageObservation.init) else {
            throw VisionSaliencyForegroundMaskEstimatorError.missingObservation
        }

        let sourceExtent = CIImage(cvPixelBuffer: pixelBuffer).extent.integral
        let heatMap = try CIImage(cgImage: observation.heatMap.cgImage)
        let heatMask = scale(image: heatMap, toFit: sourceExtent)
            .cropped(to: sourceExtent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.7,
                kCIInputBrightnessKey: -0.06
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 1.4
            ])
            .cropped(to: sourceExtent)

        let salientObjectsMask = makeSalientObjectsMask(observation.salientObjects, extent: sourceExtent)

        guard let salientObjectsMask else {
            return heatMask
        }

        return heatMask.applyingFilter("CIMaximumCompositing", parameters: [
            kCIInputBackgroundImageKey: salientObjectsMask
        ])
        .cropped(to: sourceExtent)
    }

    private func prepareInputPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let currentWidth = CVPixelBufferGetWidth(pixelBuffer)
        let currentHeight = CVPixelBufferGetHeight(pixelBuffer)
        let longerSide = max(currentWidth, currentHeight)
        guard CGFloat(longerSide) > targetLongSide else {
            return pixelBuffer
        }

        let scale = targetLongSide / CGFloat(longerSide)
        let targetWidth = max(1, Int(round(CGFloat(currentWidth) * scale)))
        let targetHeight = max(1, Int(round(CGFloat(currentHeight) * scale)))

        var resizedBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &resizedBuffer
        )
        guard status == kCVReturnSuccess, let resizedBuffer else {
            throw VisionSaliencyForegroundMaskEstimatorError.pixelBufferCreationFailed
        }

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(targetWidth) / max(sourceImage.extent.width, 1)
        let sy = CGFloat(targetHeight) / max(sourceImage.extent.height, 1)
        let resizedImage = sourceImage
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        context.render(resizedImage, to: resizedBuffer)
        return resizedBuffer
    }

    private func scale(image: CIImage, toFit extent: CGRect) -> CIImage {
        let sourceExtent = image.extent.integral
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return image }

        let scaleX = extent.width / sourceExtent.width
        let scaleY = extent.height / sourceExtent.height
        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: extent)
    }

    private func makeSalientObjectsMask(_ objects: [RectangleObservation], extent: CGRect) -> CIImage? {
        guard !objects.isEmpty else { return nil }

        let transparent = CIImage(color: .clear).cropped(to: extent)
        var mask = transparent
        let paddingX = extent.width * 0.035
        let paddingY = extent.height * 0.035

        for rectObservation in objects.prefix(3) {
            let left = min(rectObservation.topLeft.x, rectObservation.bottomLeft.x)
            let right = max(rectObservation.topRight.x, rectObservation.bottomRight.x)
            let top = max(rectObservation.topLeft.y, rectObservation.topRight.y)
            let bottom = min(rectObservation.bottomLeft.y, rectObservation.bottomRight.y)

            let rect = CGRect(
                x: extent.minX + CGFloat(left) * extent.width,
                y: extent.minY + CGFloat(1.0 - top) * extent.height,
                width: CGFloat(right - left) * extent.width,
                height: CGFloat(top - bottom) * extent.height
            )
            .insetBy(dx: -paddingX, dy: -paddingY)
            .intersection(extent)
            .integral

            guard rect.width > 1, rect.height > 1 else { continue }

            let rectMask = CIImage(color: .white)
                .cropped(to: rect)
            mask = rectMask.composited(over: mask)
        }

        return mask.cropped(to: extent)
    }
}
