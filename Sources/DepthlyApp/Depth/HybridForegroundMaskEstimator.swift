import CoreImage
import CoreVideo
import Foundation

enum HybridForegroundMaskEstimatorError: Error {
    case noMaskProduced
}

final class HybridForegroundMaskEstimator: ForegroundMaskEstimating, @unchecked Sendable {
    private let saliencyEstimator: any ForegroundMaskEstimating
    private let personEstimator: any ForegroundMaskEstimating

    init(
        saliencyEstimator: any ForegroundMaskEstimating = VisionSaliencyForegroundMaskEstimator(),
        personEstimator: any ForegroundMaskEstimating = VisionForegroundMaskEstimator()
    ) {
        self.saliencyEstimator = saliencyEstimator
        self.personEstimator = personEstimator
    }

    func estimateForegroundMask(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        var masks: [CIImage] = []

        if let saliencyMask = try? await saliencyEstimator.estimateForegroundMask(for: pixelBuffer) {
            masks.append(saliencyMask)
        }

        if let personMask = try? await personEstimator.estimateForegroundMask(for: pixelBuffer) {
            masks.append(personMask)
        }

        guard let firstMask = masks.first else {
            throw HybridForegroundMaskEstimatorError.noMaskProduced
        }

        return masks.dropFirst().reduce(firstMask) { current, next in
            current.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: next
            ])
        }
    }
}
