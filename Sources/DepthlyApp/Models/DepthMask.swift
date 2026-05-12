import CoreMedia
import CoreVideo
import Foundation

struct DepthMask {
    let pixelBuffer: CVPixelBuffer
    let confidence: Float
    let timestamp: CMTime
}
