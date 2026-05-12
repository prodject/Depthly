import CoreMedia
import CoreVideo
import Foundation

final class MaskCache: @unchecked Sendable {
    private struct DiskMaskHeader {
        static let magic: UInt32 = 0x444D534B // "DMSK"
        static let version: UInt32 = 1
        static let byteCount = MemoryLayout<UInt32>.size * 4 + MemoryLayout<Double>.size + MemoryLayout<Float>.size

        let width: UInt32
        let height: UInt32
        let bytesPerRow: UInt32
        let timestampSeconds: Double
        let confidence: Float

        func encodedData() -> Data {
            var data = Data()
            Self.appendValue(&data, DiskMaskHeader.magic)
            Self.appendValue(&data, DiskMaskHeader.version)
            Self.appendValue(&data, width)
            Self.appendValue(&data, height)
            Self.appendValue(&data, bytesPerRow)
            Self.appendValue(&data, timestampSeconds)
            Self.appendValue(&data, confidence)
            return data
        }

        static func decode(from data: Data) -> DiskMaskHeader? {
            guard data.count >= byteCount else { return nil }

            var offset = 0
            guard
                read(UInt32.self, from: data, offset: &offset) == magic,
                read(UInt32.self, from: data, offset: &offset) == version
            else {
                return nil
            }

            guard
                let width = read(UInt32.self, from: data, offset: &offset),
                let height = read(UInt32.self, from: data, offset: &offset),
                let bytesPerRow = read(UInt32.self, from: data, offset: &offset),
                let timestampSeconds = read(Double.self, from: data, offset: &offset),
                let confidence = read(Float.self, from: data, offset: &offset)
            else {
                return nil
            }

            return DiskMaskHeader(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestampSeconds: timestampSeconds,
                confidence: confidence
            )
        }

        private static func appendValue<T>(_ data: inout Data, _ value: T) {
            var value = value
            withUnsafeBytes(of: &value) { buffer in
                data.append(contentsOf: buffer)
            }
        }

        private static func read<T>(_ type: T.Type, from data: Data, offset: inout Int) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let value = data.withUnsafeBytes { rawBuffer -> T in
                rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: T.self).pointee
            }
            offset += size
            return value
        }
    }

    private let lock = NSLock()
    private var memoryStorage: [Int64: ForegroundMask] = [:]
    private let memoryCapacity: Int
    private let fileManager: FileManager
    private let cacheRootURL: URL
    private var sessionDirectoryURL: URL?

    init(memoryCapacity: Int = 24, fileManager: FileManager = .default) {
        self.memoryCapacity = memoryCapacity
        self.fileManager = fileManager
        self.cacheRootURL = fileManager.temporaryDirectory.appendingPathComponent("DepthlyMaskCache", isDirectory: true)
    }

    func configure(for videoURL: URL) {
        configure(for: videoURL, persistent: true)
    }

    func configure(for videoURL: URL, persistent: Bool) {
        lock.lock()
        defer { lock.unlock() }

        memoryStorage.removeAll(keepingCapacity: true)
        if let sessionDirectoryURL {
            try? fileManager.removeItem(at: sessionDirectoryURL)
        }

        guard persistent else {
            sessionDirectoryURL = nil
            return
        }

        let sessionName = Self.sessionIdentifier(for: videoURL)
        let directory = cacheRootURL.appendingPathComponent(sessionName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectoryURL = directory
    }

    func store(_ mask: ForegroundMask, for time: CMTime) {
        store(mask, for: time, persistent: true)
    }

    func store(_ mask: ForegroundMask, for time: CMTime, persistent: Bool) {
        let key = timeKey(for: time)

        lock.lock()
        memoryStorage[key] = mask
        trimMemoryIfNeeded()
        let directory = persistent ? sessionDirectoryURL : nil
        lock.unlock()

        guard let directory else { return }
        do {
            try write(mask: mask, to: directory, key: key)
        } catch {
            // Disk cache is a performance optimization. If it fails, the
            // in-memory hot cache still keeps playback functional.
        }
    }

    func mask(for time: CMTime) -> ForegroundMask? {
        let key = timeKey(for: time)

        lock.lock()
        if let cached = memoryStorage[key] {
            lock.unlock()
            return cached
        }
        let directory = sessionDirectoryURL
        lock.unlock()

        guard
            let directory,
            let loaded = try? readMask(from: directory, key: key)
        else {
            return nil
        }

        lock.lock()
        memoryStorage[key] = loaded
        trimMemoryIfNeeded()
        lock.unlock()
        return loaded
    }

    func removeAll() {
        lock.lock()
        memoryStorage.removeAll(keepingCapacity: true)
        let directory = sessionDirectoryURL
        sessionDirectoryURL = nil
        lock.unlock()

        if let directory {
            try? fileManager.removeItem(at: directory)
        }
    }

    func clearMemory() {
        lock.lock()
        memoryStorage.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func trimMemoryIfNeeded() {
        guard memoryCapacity > 0 else { return }
        guard memoryStorage.count > memoryCapacity else { return }

        let excessCount = memoryStorage.count - memoryCapacity
        let keysToRemove = memoryStorage.keys.sorted().prefix(excessCount)
        for key in keysToRemove {
            memoryStorage.removeValue(forKey: key)
        }
    }

    private func write(mask: ForegroundMask, to directory: URL, key: Int64) throws {
        let buffer = mask.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return
        }

        let width = UInt32(CVPixelBufferGetWidth(buffer))
        let height = UInt32(CVPixelBufferGetHeight(buffer))
        let bytesPerRow = UInt32(CVPixelBufferGetBytesPerRow(buffer))
        let rowCount = Int(height)
        let sourcePointer = base.assumingMemoryBound(to: UInt8.self)

        var payload = Data()
        payload.reserveCapacity(DiskMaskHeader.byteCount + Int(bytesPerRow) * rowCount)

        let header = DiskMaskHeader(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            timestampSeconds: mask.timestamp.seconds.isFinite ? mask.timestamp.seconds : 0,
            confidence: mask.confidence
        )
        payload.append(header.encodedData())

        let sourceStride = Int(bytesPerRow)
        for row in 0..<rowCount {
            let start = row * sourceStride
            let slice = UnsafeBufferPointer(start: sourcePointer.advanced(by: start), count: sourceStride)
            payload.append(contentsOf: slice)
        }

        let fileURL = fileURL(for: directory, key: key)
        try payload.write(to: fileURL, options: .atomic)
    }

    private func readMask(from directory: URL, key: Int64) throws -> ForegroundMask? {
        let fileURL = fileURL(for: directory, key: key)
        guard let payload = try? Data(contentsOf: fileURL),
              let header = DiskMaskHeader.decode(from: payload)
        else {
            return nil
        }

        let width = Int(header.width)
        let height = Int(header.height)
        let sourceBytesPerRow = Int(header.bytesPerRow)
        let dataStart = DiskMaskHeader.byteCount
        guard payload.count >= dataStart + sourceBytesPerRow * height else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let destinationBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        payload.withUnsafeBytes { rawBuffer in
            guard let sourceBase = rawBuffer.baseAddress?.advanced(by: dataStart) else {
                return
            }

            let sourcePointer = sourceBase.assumingMemoryBound(to: UInt8.self)
            let destinationPointer = destinationBase.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let sourceOffset = row * sourceBytesPerRow
                let destinationOffset = row * destinationStride
                let copyCount = min(sourceBytesPerRow, destinationStride)
                memcpy(destinationPointer.advanced(by: destinationOffset), sourcePointer.advanced(by: sourceOffset), copyCount)
                if destinationStride > copyCount {
                    memset(destinationPointer.advanced(by: destinationOffset + copyCount), 0, destinationStride - copyCount)
                }
            }
        }

        let seconds = header.timestampSeconds
        let timestamp = CMTime(seconds: seconds, preferredTimescale: 600)
        return ForegroundMask(pixelBuffer: pixelBuffer, confidence: header.confidence, timestamp: timestamp)
    }

    private func fileURL(for directory: URL, key: Int64) -> URL {
        directory.appendingPathComponent("\(key).maskbin", isDirectory: false)
    }

    private func timeKey(for time: CMTime) -> Int64 {
        guard time.seconds.isFinite else { return 0 }
        return Int64((time.seconds * 1000.0).rounded())
    }

    private static func sessionIdentifier(for videoURL: URL) -> String {
        let encoded = Data(videoURL.standardizedFileURL.absoluteString.utf8).base64EncodedString()
        let sanitized = encoded
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return sanitized
    }
}
