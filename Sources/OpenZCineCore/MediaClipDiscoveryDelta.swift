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

/// Camera-reported object identity used to detect PTP handle reuse after a card
/// format or generation change. Handle values are recycled; filename + capture
/// date name the actual file.
public struct MediaClipObjectIdentity: Hashable, Sendable, Equatable {
    public let location: MediaObjectHandle
    public let filename: String
    public let captureDate: String
    public let sizeBytes: UInt64

    public init(
        location: MediaObjectHandle,
        filename: String,
        captureDate: String,
        sizeBytes: UInt64
    ) {
        self.location = location
        self.filename = filename
        self.captureDate = captureDate
        self.sizeBytes = sizeBytes
    }

    /// True when this cached identity still names the same camera object.
    /// A zero or PTP UINT32-sentinel size is unknown and does not count as a mismatch.
    public func matchesCameraObject(_ camera: MediaClipObjectIdentity) -> Bool {
        guard filename == camera.filename, captureDate == camera.captureDate else { return false }
        if !hasKnownSize || !camera.hasKnownSize { return true }
        return sizeBytes == camera.sizeBytes
    }

    private var hasKnownSize: Bool {
        sizeBytes > 0 && sizeBytes != 0xFFFF_FFFF
    }
}

/// Result of comparing a cached library index with the camera's current handle set.
public struct MediaClipDiscoveryDelta: Sendable, Equatable {
    /// Locations present on both camera and cache — `GetObjectInfo` can be skipped
    /// only after identity verification confirms the object did not change.
    public let reuseHandles: Set<MediaObjectHandle>
    /// Locations on camera but absent from cache — require `GetObjectInfo`.
    public let fetchHandles: Set<MediaObjectHandle>
    /// Locations in cache but no longer on camera — evict or clear references.
    public let removedHandles: Set<MediaObjectHandle>
    /// Cached locations the camera still reports whose object identity changed
    /// (format / handle recycle). Drop the old row, then fetch the new object.
    public let supersededHandles: Set<MediaObjectHandle>

    public init(
        reuseHandles: Set<MediaObjectHandle>,
        fetchHandles: Set<MediaObjectHandle>,
        removedHandles: Set<MediaObjectHandle>,
        supersededHandles: Set<MediaObjectHandle> = []
    ) {
        self.reuseHandles = reuseHandles
        self.fetchHandles = fetchHandles
        self.removedHandles = removedHandles
        self.supersededHandles = supersededHandles
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

    /// Spread of reused handles to `GetObjectInfo` for identity checks. Newest first
    /// so a formatted card that recycled low handles is still sampled at both ends.
    public func identityProbeHandles(budget: Int) -> [MediaObjectHandle] {
        guard budget > 0 else { return [] }
        let reused = reuseHandles.sorted {
            if $0.storageID != $1.storageID { return $0.storageID < $1.storageID }
            return $0.handle > $1.handle
        }
        if reused.count <= budget { return reused }
        if budget == 1 { return [reused[0]] }
        var selected: [MediaObjectHandle] = []
        selected.reserveCapacity(budget)
        for step in 0..<budget {
            let index = step * (reused.count - 1) / (budget - 1)
            let handle = reused[index]
            if selected.last != handle { selected.append(handle) }
        }
        return selected
    }

    /// Splits reuse vs superseded using probed camera objects. A mismatch on one
    /// handle invalidates every reused handle on that storage — after a format the
    /// whole card's handles are recycled, and sampling one is enough to know.
    public func verifyingReusedIdentities(
        cached: [MediaObjectHandle: MediaClipObjectIdentity],
        probed: [MediaObjectHandle: MediaClipObjectIdentity]
    ) -> MediaClipDiscoveryDelta {
        var dirtyStorages = Set<UInt32>()
        for (location, cameraObject) in probed {
            guard reuseHandles.contains(location) else { continue }
            if let cachedObject = cached[location], cachedObject.matchesCameraObject(cameraObject) {
                continue
            }
            dirtyStorages.insert(location.storageID)
        }
        guard !dirtyStorages.isEmpty else { return self }
        let superseded = Set(reuseHandles.filter { dirtyStorages.contains($0.storageID) })
        return MediaClipDiscoveryDelta(
            reuseHandles: reuseHandles.subtracting(superseded),
            fetchHandles: fetchHandles.union(superseded),
            removedHandles: removedHandles,
            supersededHandles: supersededHandles.union(superseded)
        )
    }
}
