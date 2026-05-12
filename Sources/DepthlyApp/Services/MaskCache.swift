import CoreMedia
import Foundation

final class MaskCache {
    private let lock = NSLock()
    private var storage: [Int64: ForegroundMask] = [:]
    private let capacity: Int

    init(capacity: Int = 48) {
        self.capacity = capacity
    }

    func store(_ mask: ForegroundMask, for time: CMTime) {
        let key = timeKey(for: time)
        lock.lock()
        storage[key] = mask
        trimIfNeeded()
        lock.unlock()
    }

    func mask(for time: CMTime) -> ForegroundMask? {
        let key = timeKey(for: time)
        lock.lock()
        defer { lock.unlock() }

        if let mask = storage[key] {
            return mask
        }

        let tolerance: Int64 = 35
        if let nearestKey = storage.keys.min(by: { abs($0 - key) < abs($1 - key) }),
           abs(nearestKey - key) <= tolerance {
            return storage[nearestKey]
        }

        return nil
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func trimIfNeeded() {
        guard storage.count > capacity else { return }
        let excessCount = storage.count - capacity
        let keysToRemove = storage.keys.sorted().prefix(excessCount)
        for key in keysToRemove {
            storage.removeValue(forKey: key)
        }
    }

    private func timeKey(for time: CMTime) -> Int64 {
        guard time.seconds.isFinite else { return 0 }
        return Int64((time.seconds * 1000.0).rounded())
    }
}
