import CoreMedia
import CoreVideo
import Foundation

protocol ForegroundMaskProviding {
    func makeForegroundMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> ForegroundMask
}
