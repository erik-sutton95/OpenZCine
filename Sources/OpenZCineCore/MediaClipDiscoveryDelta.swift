import Foundation

/// A media object handle reported by the camera on one storage volume.
public struct MediaObjectHandle: Hashable, Sendable, Equatable {
    public let storageID: UInt32
    public let handle: UInt32

    public init(storageID: UInt32, handle: UInt32) {
        self.storageID = storageID
        self.handle = handle
    }
}

/// Result of comparing a cached library index with the camera's current handle set.
public struct MediaClipDiscoveryDelta: Sendable, Equatable {
    /// Handles present on both camera and cache — `GetObjectInfo` can be skipped.
    public let reuseHandles: Set<UInt32>
    /// Handles on camera but absent from cache — require `GetObjectInfo`.
    public let fetchHandles: Set<MediaObjectHandle>
    /// Handles in cache but no longer on camera — evict or clear references.
    public let removedHandles: Set<UInt32>

    public init(
        reuseHandles: Set<UInt32>,
        fetchHandles: Set<MediaObjectHandle>,
        removedHandles: Set<UInt32>
    ) {
        self.reuseHandles = reuseHandles
        self.fetchHandles = fetchHandles
        self.removedHandles = removedHandles
    }

    /// Plans incremental discovery: reuse cached metadata for stable handles, fetch only new ones,
    /// and surface handles that disappeared from the card since the last sync.
    public static func compute(
        cachedHandles: Set<UInt32>,
        cameraHandles: [MediaObjectHandle]
    ) -> MediaClipDiscoveryDelta {
        let cameraHandleSet = Set(cameraHandles.map(\.handle))
        let reuse = cachedHandles.intersection(cameraHandleSet)
        let fetch = Set(cameraHandles.filter { !cachedHandles.contains($0.handle) })
        let removed = cachedHandles.subtracting(cameraHandleSet)
        return MediaClipDiscoveryDelta(
            reuseHandles: reuse,
            fetchHandles: fetch,
            removedHandles: removed
        )
    }
}
