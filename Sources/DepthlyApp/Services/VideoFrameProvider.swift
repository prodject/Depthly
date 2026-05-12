import AVFoundation
import CoreVideo
import Foundation

protocol VideoFrameProvider: AnyObject {
    func attach(to playerItem: AVPlayerItem)
    func detach()
    func copyCurrentPixelBuffer(at time: CMTime) -> (pixelBuffer: CVPixelBuffer, itemTime: CMTime)?
}
