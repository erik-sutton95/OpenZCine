import Foundation

/// A media object handle reported by the camera on one storage volume. Identity is the
/// (storageID, handle) pair end-to-end: backup mode writes one shot to both cards as two
/// distinct objects (sharing a filename), and handle values are only unique per storage.
public struct MediaObjectHandle: Hashable, Sendable, Equatable, Codable {
    public let storageID: UInt32
    public let handle: UInt32

    public init(storageID: UInt32, handle: UInt32) {
        self.storageID = storageID
        self.handle = handle
    }
}

/// Result of comparing a cached library index with the camera's current handle set.
public struct MediaClipDiscoveryDelta: Sendable, Equatable {
    /// Locations present on both camera and cache — `GetObjectInfo` can be skipped.
    public let reuseHandles: Set<MediaObjectHandle>
    /// Locations on camera but absent from cache — require `GetObjectInfo`.
    public let fetchHandles: Set<MediaObjectHandle>
    /// Locations in cache but no longer on camera — evict or clear references.
    public let removedHandles: Set<MediaObjectHandle>

    public init(
        reuseHandles: Set<MediaObjectHandle>,
        fetchHandles: Set<MediaObjectHandle>,
        removedHandles: Set<MediaObjectHandle>
    ) {
        self.reuseHandles = reuseHandles
        self.fetchHandles = fetchHandles
        self.removedHandles = removedHandles
    }

    /// Plans incremental discovery: reuse cached metadata for stable locations, fetch only new
    /// ones, and surface locations that disappeared from the cards since the last sync.
    public static func compute(
        cachedHandles: Set<MediaObjectHandle>,
        cameraHandles: [MediaObjectHandle]
    ) -> MediaClipDiscoveryDelta {
        let cameraSet = Set(cameraHandles)
        return MediaClipDiscoveryDelta(
            reuseHandles: cachedHandles.intersection(cameraSet),
            fetchHandles: cameraSet.subtracting(cachedHandles),
            removedHandles: cachedHandles.subtracting(cameraSet)
        )
    }
}
