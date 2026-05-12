import CoreMedia
import CoreVideo
import Foundation

struct ForegroundMask {
    let pixelBuffer: CVPixelBuffer
    let confidence: Float
    let timestamp: CMTime
}
