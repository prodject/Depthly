import CoreMedia
import CoreVideo
import Foundation

struct DepthMap {
    let pixelBuffer: CVPixelBuffer
    let confidence: Float
    let timestamp: CMTime
}
