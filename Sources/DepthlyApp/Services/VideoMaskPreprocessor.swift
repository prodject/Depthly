import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class VideoMaskPreprocessor {
    private let foregroundMaskProvider: ForegroundMaskProviding

    init(foregroundMaskProvider: ForegroundMaskProviding = HumanForegroundMaskProvider()) {
        self.foregroundMaskProvider = foregroundMaskProvider
    }

    func preprocess(
        asset: AVAsset,
        settings: EffectSettings,
        timeline: ForegroundMaskTimeline,
        progressHandler: (@MainActor @Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        await timeline.reset()

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadUnknown)
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = max(duration.seconds, 0.0001)
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw CocoaError(.coderInvalidValue)
        }

        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }

        let stabilizer = ForegroundMaskStabilizer()
        var processedFrames = 0

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = timestamp.seconds
            guard seconds.isFinite else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            let rawMask = try await foregroundMaskProvider.makeForegroundMask(from: pixelBuffer, timestamp: timestamp)
            let stabilizedMask = try stabilizer.stabilize(mask: rawMask, settings: settings)
            await timeline.append(stabilizedMask)
            processedFrames += 1

            if let progressHandler, processedFrames.isMultiple(of: 6) {
                let progress = max(0.0, min(1.0, seconds / durationSeconds))
                await progressHandler(progress, "Preparing masks \(Int(progress * 100))%")
            }
        }

        if reader.status == .failed {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }

        if let progressHandler {
            await progressHandler(1.0, "Masks ready")
        }
    }
}
