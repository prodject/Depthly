import AVFoundation
import CoreMedia
import QuartzCore

final class VideoFrameProvider {
    struct FrameSample: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let time: CMTime
    }

    var onFrameAvailable: (@Sendable (FrameSample) -> Void)?

    private let queue = DispatchQueue(label: "Depthly.VideoFrameProvider", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var attachedPlayerItem: AVPlayerItem?

    func attach(to playerItem: AVPlayerItem) {
        detach()

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        playerItem.add(output)
        videoOutput = output
        attachedPlayerItem = playerItem
    }

    func detach() {
        if let videoOutput, let attachedPlayerItem {
            attachedPlayerItem.remove(videoOutput)
        }

        videoOutput = nil
        attachedPlayerItem = nil
    }

    func start() {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        detach()
    }

    private func poll() {
        guard let videoOutput else { return }

        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)

        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }

        onFrameAvailable?(FrameSample(pixelBuffer: pixelBuffer, time: itemTime))
    }
}
