import CoreMedia
import CoreVideo
import Foundation

actor ForegroundMaskTimeline {
    struct Entry {
        let time: Double
        let mask: ForegroundMask
    }

    private var entries: [Entry] = []

    func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    func append(_ mask: ForegroundMask) {
        let time = mask.timestamp.seconds
        guard time.isFinite else { return }

        if let last = entries.last, time <= last.time {
            return
        }

        entries.append(Entry(time: time, mask: mask))
    }

    func isEmpty() -> Bool {
        entries.isEmpty
    }

    func mask(at timestamp: CMTime, maxGap: Double) async throws -> ForegroundMask? {
        let time = timestamp.seconds
        guard time.isFinite, !entries.isEmpty else { return nil }

        if entries.count == 1 {
            let only = entries[0]
            return abs(only.time - time) <= maxGap ? only.mask : nil
        }

        var low = 0
        var high = entries.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let midTime = entries[mid].time
            if midTime < time {
                low = mid + 1
            } else if midTime > time {
                high = mid - 1
            } else {
                return entries[mid].mask
            }
        }

        let nextIndex = min(low, entries.count - 1)
        let previousIndex = max(0, nextIndex - 1)
        let previous = entries[previousIndex]
        let next = entries[nextIndex]

        let previousDelta = abs(time - previous.time)
        let nextDelta = abs(next.time - time)

        if previousIndex == nextIndex {
            return previousDelta <= maxGap ? previous.mask : nil
        }

        guard previousDelta <= maxGap || nextDelta <= maxGap else {
            return nil
        }

        let span = max(next.time - previous.time, 0.0001)
        let alpha = max(0.0, min(1.0, (time - previous.time) / span))
        let blended = try MaskPixelBufferBlender.blend(previous.mask.pixelBuffer, next.mask.pixelBuffer, alpha: alpha)
        return ForegroundMask(
            pixelBuffer: blended,
            confidence: max(previous.mask.confidence, next.mask.confidence),
            timestamp: timestamp
        )
    }
}
