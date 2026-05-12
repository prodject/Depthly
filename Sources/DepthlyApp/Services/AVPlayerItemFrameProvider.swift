import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class AVPlayerItemFrameProvider: VideoFrameProvider {
    private let output: AVPlayerItemVideoOutput
    private weak var currentItem: AVPlayerItem?

    init() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
    }

    func attach(to playerItem: AVPlayerItem) {
        detach()
        currentItem = playerItem
        playerItem.add(output)
    }

    func detach() {
        currentItem?.remove(output)
        currentItem = nil
    }

    func copyCurrentPixelBuffer(at time: CMTime) -> (pixelBuffer: CVPixelBuffer, itemTime: CMTime)? {
        var itemTime = CMTime.zero
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &itemTime)
        else {
            return nil
        }
        return (buffer, itemTime)
    }
}
