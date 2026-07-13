import Foundation

/// Accumulates bytes received from a stream socket and hands back exact-length frames without
/// shifting the underlying storage on every read.
///
/// `readExact`-style consumers `append` received chunks and `take` fixed-length frames. A read
/// cursor advances in O(1) instead of removing from the front of the storage on every read, so a
/// large frame (a multi-MB live-view JPEG) isn't repeatedly memmoved as it is parsed. The storage
/// is compacted only when the consumed prefix grows past `compactionThreshold`, which bounds memory
/// without paying a shift per read.
public struct PTPIPReadBuffer: Sendable {
    private var storage = Data()
    /// Bytes already consumed from the front of `storage` (the read cursor).
    private var offset = 0
    private let compactionThreshold: Int

    public init(compactionThreshold: Int = 64 * 1024) {
        self.compactionThreshold = compactionThreshold
    }

    /// The number of unread bytes available to `take`.
    public var availableCount: Int { storage.count - offset }

    /// Appends newly received bytes to the unread tail.
    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    /// Removes and returns the next `count` unread bytes, or `nil` if fewer than `count` are
    /// available. `count == 0` returns an empty `Data` and consumes nothing.
    public mutating func take(_ count: Int) -> Data? {
        guard count >= 0, availableCount >= count else { return nil }
        let start = storage.startIndex + offset
        let frame = Data(storage[start..<(start + count)])
        offset += count
        compactIfNeeded()
        return frame
    }

    /// Advances/clears the storage so consumed bytes don't accumulate. When everything has been
    /// consumed (the common case) the storage is reset but keeps its capacity, so the next frame
    /// reuses the same allocation. Otherwise the consumed prefix is dropped only once it grows past
    /// the threshold — bounding memory without shifting on every read.
    private mutating func compactIfNeeded() {
        if offset == storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset >= compactionThreshold {
            storage = Data(storage[(storage.startIndex + offset)...])
            offset = 0
        }
    }
}
