import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
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
        let hostTime = CACurrentMediaTime()
        let fallbackTime = output.itemTime(forHostTime: hostTime)
        let requestTime = time.isValid ? time : fallbackTime
        var itemTime = CMTime.zero
        guard output.hasNewPixelBuffer(forItemTime: requestTime),
              let buffer = output.copyPixelBuffer(forItemTime: requestTime, itemTimeForDisplay: &itemTime)
        else {
            guard fallbackTime.isValid,
                  fallbackTime != requestTime,
                  output.hasNewPixelBuffer(forItemTime: fallbackTime),
                  let buffer = output.copyPixelBuffer(forItemTime: fallbackTime, itemTimeForDisplay: &itemTime)
            else {
                return nil
            }
            return (buffer, itemTime)
        }
        return (buffer, itemTime)
    }
}
