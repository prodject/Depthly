import CoreMedia
import CoreVideo
import Foundation

struct DepthMap {
    enum Source {
        case synthetic
        case coreML
    }

    let pixelBuffer: CVPixelBuffer
    let confidence: Float
    let timestamp: CMTime
    let source: Source
}
