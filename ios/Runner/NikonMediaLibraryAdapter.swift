import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import OpenZCineCore

/// The canonical file and main-actor authority remain the actual app's store.
@MainActor final class NikonMediaLibraryByteStore: MonitorMediaCatalogByteStore {
    let store: MediaClipStore
    let bucket: String
    private let admitted: () -> Bool
    private(set) var generation: UInt64 = 0
    let namespace: String
    init(store: MediaClipStore, bucket: String, admitted: @escaping () -> Bool) {
        self.store = store
        self.bucket = bucket
        namespace = store.directory(for: bucket).standardizedFileURL.path
        self.admitted = admitted
    }
    func retire() { generation &+= 1 }
    func read() throws -> Data? {
        guard admitted() else { throw MediaServiceError.retired }
        return try store.catalogBytes(cameraID: bucket)
    }
    func write(_ bytes: Data, ifCurrent: () -> Bool) throws {
        try store.writeCatalogBytes(bytes, cameraID: bucket) { admitted() && ifCurrent() }
    }
    // MainActor has no suspension between authoritative read, pure preparation and atomic write.
    func update(ifCurrent: () -> Bool, encode: (Data?) throws -> Data?) throws {
        guard admitted(), ifCurrent() else { throw MediaServiceError.retired }
        let current = try read()
        guard admitted(), ifCurrent() else { throw MediaServiceError.retired }
        guard let bytes = try encode(current) else { return }
        try write(bytes, ifCurrent: ifCurrent)
    }
}

/// Favorites continue through NativeAppModel.toggleClipFavorite/setMediaStarRating.
/// This port projects the already-persisted flags; no generic toggle is exposed by Nikon UI.
@MainActor final class NikonMediaLibraryFavorites: MonitorMediaFavoritesStore {
    private let store: MediaClipStore
    private let buckets: [String]
    init(store: MediaClipStore, buckets: [String]) {
        self.store = store
        self.buckets = buckets
    }
    func favorites() -> Set<String> {
        Set(buckets.flatMap { store.list(cameraID: $0) }.filter(\.isFavorite).map(\.id))
    }
    func saveFavorites(_ keys: Set<String>) {
        // Actual native actions own durable writes. Catalog projection cannot rewrite them.
    }

}

/// Pure schema/address mapping and binding-qualified capture. Source enumeration stays in Nikon.
@MainActor final class NikonMediaLibraryCodec: MonitorMediaCatalogCodec {
    typealias Payload = MediaClip
    let store: MediaClipStore
    let bucket: String
    /// The library owner's current source; a new camera service rebinds it, never replaces it.
    var service: NikonMediaService?
    private let downloaded: (MediaClip) -> Bool
    // Immutable captured tombstones are checked against current bytes, never filename alone.
    private var acceptedRemovals: [NikonMediaObjectRecord] = []
    init(
        store: MediaClipStore, bucket: String, service: NikonMediaService?,
        downloaded: @escaping (MediaClip) -> Bool
    ) {
        self.store = store
        self.bucket = bucket
        self.service = service
        self.downloaded = downloaded
    }
    func record(_ clip: MediaClip) throws -> MonitorMediaRecord<MediaClip> {
        let asset = NikonMediaLibraryAssets.asset(
            namespace: clip.cameraID, identity: clip.id,
            filename: clip.filename, captureDate: clip.captureDate, sizeBytes: clip.sizeBytes,
            pixelWidth: clip.pixelWidth, pixelHeight: clip.pixelHeight)
        let root = store.root.standardizedFileURL.path + "/"
        let media = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
            .standardizedFileURL.path
        let thumb = try store.thumbURL(cameraID: clip.cameraID, filename: clip.filename)
            .standardizedFileURL.path
        guard media.hasPrefix(root), thumb.hasPrefix(root) else {
            throw MonitorMediaCacheError.invalidAddress
        }
        let representation = asset.representations[0].id
        return .init(
            asset: asset, payload: clip,
            address: .init(
                thumbnail: String(thumb.dropFirst(root.count)),
                representations: [representation: String(media.dropFirst(root.count))],
                favoriteKey: clip.id),
            favorite: clip.isFavorited,
            facts: .init(
                orderKey: clip.captureDate.isEmpty ? clip.filename : clip.captureDate,
                playbackEligible: clip.mediaKind == .photo
                    || MediaClipFilename.isPlayableProxy(clip.filename)),
            favoriteAuthority: .legacyCombined,
            sourceFavorite: clip.starRating.map { $0 >= 1 })
    }
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<MediaClip>] {
        try MediaClipStore.decodeCatalogBytes(bytes).map(record)
    }
    func encode(_ records: [MonitorMediaRecord<MediaClip>]) throws -> Data {
        try MediaClipStore.encodeCatalogBytes(
            records.map(\.payload).filter { $0.cameraID == bucket })
    }
    func encodeForPersistence(_ records: [MonitorMediaRecord<MediaClip>], currentBytes: Data?)
        throws -> Data?
    {
        let current = try currentBytes.map(MediaClipStore.decodeCatalogBytes) ?? []
        let candidate = records.map(\.payload).filter { $0.cameraID == bucket }
        var rows = Dictionary(
            current.map { ($0.filename, $0) }, uniquingKeysWith: { _, last in last })
        let candidateNames = Set(candidate.map(\.filename))
        for old in current where !candidateNames.contains(old.filename) {
            let matched = NikonMediaCatalogAdapter.records([old]).contains { live in
                acceptedRemovals.contains {
                    $0.location == live.location && $0.identity == live.identity
                }
            }
            if matched { rows[old.filename] = nil }
        }
        for clip in candidate {
            if let live = rows[clip.filename] {
                var merged = MediaClipStore.mergeCameraDiscovery(existing: live, incoming: clip)
                // Source-removal survivors carry their exact remaining locations, not the old union.
                let removed = acceptedRemovals.filter { tombstone in
                    NikonMediaCatalogAdapter.records([live]).contains {
                        $0.location == tombstone.location && $0.identity == tombstone.identity
                    }
                }.map(\.location)
                let survivors = merged.allLocations.filter { !removed.contains($0) }
                if !removed.isEmpty {
                    let primary = survivors.min {
                        MediaClipStore.locationRank($0) < MediaClipStore.locationRank($1)
                    }
                    merged.handle = primary?.handle
                    merged.storageID = primary?.storageID
                    merged.storageLocations = survivors.isEmpty ? nil : survivors
                }
                rows[clip.filename] = merged
            } else {
                rows[clip.filename] = clip
            }
        }
        return try MediaClipStore.encodeCatalogBytes(Array(rows.values))
    }
    func prepareCatalog(
        _ capture: MonitorMediaCatalogCapture<MediaClip>, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<MediaClip>]
    ) async throws -> MonitorMediaCatalogCapture<MediaClip> {
        // Only canonical local metadata is reread here. No camera/source lookup follows suspension.
        let current = Dictionary(
            store.list(cameraID: bucket).map { ($0.filename, $0) },
            uniquingKeysWith: { _, newer in newer })
        func prepared(_ value: MonitorMediaRecord<MediaClip>) throws -> MonitorMediaRecord<
            MediaClip
        > {
            guard let live = current[value.payload.filename] else { return value }
            var clip = MediaClipStore.mergeCameraDiscovery(existing: live, incoming: value.payload)
            // Captured camera removals remain exact; merging local flags must not restore old locations.
            clip.handle = value.payload.handle
            clip.storageID = value.payload.storageID
            clip.storageLocations = value.payload.storageLocations
            return try record(clip)
        }
        return .init(
            resetLibrary: capture.resetLibrary,
            upserts: try capture.upserts.map(prepared), removed: capture.removed,
            amendments: try capture.amendments.map(prepared), order: capture.order,
            sourceFavoriteKeys: Set(current.values.filter(\.isFavorite).map(\.id)))
    }

    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
        MediaClip
    > {
        guard let service, service.isCurrent(binding),
            let value = service.mediaCatalogRecord(asset.id, binding: binding)
        else { throw MediaServiceError.retired }
        return try record(NikonMediaCatalogAdapter.clip(value.object, bucket: bucket))
    }
    func captureCatalog(
        _ delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<MediaClip>]
    ) throws -> MonitorMediaCatalogCapture<MediaClip> {
        guard let service, service.isCurrent(binding) else { throw MediaServiceError.retired }
        let additions = try delta.upserts.map { try capture($0, binding: binding).payload }
        let removals = try delta.removed.map { id -> NikonMediaObjectRecord in
            guard let value = service.mediaCatalogRecord(id, binding: binding) else {
                throw MediaServiceError.retired
            }
            return value.object
        }
        guard let pairing = service.mediaPairingUpdates(binding: binding) else {
            throw MediaServiceError.retired
        }
        let old = existing.map(\.payload)
        let indexed = NikonMediaCatalogAdapter.records(old)
        let accepted = removals.filter { tombstone in
            indexed.contains {
                $0.location == tombstone.location && $0.identity == tombstone.identity
            }
        }
        let locations = Set(accepted.map(\.location))
        let remoteOnly = Set(
            old.filter { clip in
                !clip.allLocations.isEmpty
                    && clip.allLocations.allSatisfy { locations.contains($0) } && !downloaded(clip)
            }.map(\.filename))
        var next = NikonMediaCatalogAdapter.merged(
            old, additions: additions,
            removedFilenames: remoteOnly, removedLocations: locations)
        for update in pairing {
            guard
                let index = next.firstIndex(where: {
                    NikonMediaCatalogAdapter.pairingRecord($0) == update.previous
                })
            else { continue }
            next[index].sourcePixelWidth = update.width
            next[index].sourcePixelHeight = update.height
            next[index].linkedR3DFilename = update.masterFilename
        }
        guard service.isCurrent(binding) else { throw MediaServiceError.retired }
        let incomingObjects = NikonMediaCatalogAdapter.records(additions)
        acceptedRemovals.removeAll { old in
            incomingObjects.contains { $0.location == old.location && $0.identity == old.identity }
        }
        acceptedRemovals.append(contentsOf: accepted)
        let records = try next.map(record)
        let nextIDs = Set(records.map { $0.asset.id })
        let oldIDs = Set(existing.map { $0.asset.id })
        return .init(
            resetLibrary: false,
            upserts: records.filter { !oldIDs.contains($0.asset.id) },
            removed: existing.filter { !nextIDs.contains($0.asset.id) }.map { $0.asset.id },
            amendments: records.filter { oldIDs.contains($0.asset.id) },
            sourceFavoriteKeys: Set(next.filter(\.isFavorite).map(\.id)))
    }
}

/// Captured host authority for an already-admitted native action. Wire policy is unchanged.
@MainActor final class NikonMediaLibraryAction {
    let owner: MonitorMediaLibraryModel<MediaClip>?
    private let capturedToken: MonitorMediaLibraryActionToken?
    private var deletionAuthority: MonitorMediaLibraryDeletionAuthority?
    var token: MonitorMediaLibraryActionToken? { deletionAuthority?.actionToken ?? capturedToken }
    private let store: MediaClipStore
    private let codec: NikonMediaLibraryCodec
    private let bytes: NikonMediaLibraryByteStore?
    private let generation: UInt64
    private let namespace: String
    private let admitted: () -> Bool
    private let canonicalCurrent: (() -> Bool)?
    private let expected: [String: MediaClip]
    private let previouslyAbsent: Set<String>
    private let capturedRecords: [MonitorMediaRecord<MediaClip>]
    init(
        owner: MonitorMediaLibraryModel<MediaClip>?, store: MediaClipStore,
        codec: NikonMediaLibraryCodec, bytes: NikonMediaLibraryByteStore?,
        clips: [MediaClip], canonicalCurrent: (() -> Bool)? = nil,
        admitted: @escaping () -> Bool
    ) {
        self.owner = owner
        capturedToken = owner?.actionToken
        self.store = store
        self.codec = codec
        self.bytes = bytes
        generation = bytes?.generation ?? 0
        namespace = bytes?.namespace ?? store.root.absoluteString
        self.admitted = admitted
        self.canonicalCurrent = canonicalCurrent
        var expected: [String: MediaClip] = [:]
        var absent: Set<String> = []
        for clip in clips {
            if let row = store.list(cameraID: clip.cameraID).first(where: {
                $0.filename == clip.filename
            }) {
                expected[clip.id] = Self.sameContent(clip, row) ? row : clip
            } else {
                expected[clip.id] = clip
                absent.insert(clip.id)
            }
        }
        self.expected = expected
        previouslyAbsent = absent
        capturedRecords = (owner?.records ?? []).filter { row in
            expected[row.payload.id].map { Self.sameContent($0, row.payload) } == true
        }
    }
    /// Captured source/content check independent of the one explicit catalog preparation.
    var sourceIsCurrent: Bool {
        admitted() && (bytes?.generation ?? 0) == generation
            && (bytes?.namespace ?? store.root.absoluteString) == namespace
            && capturedIndexMatches
            && admitted() && (bytes?.generation ?? 0) == generation
            && (bytes?.namespace ?? store.root.absoluteString) == namespace
    }
    /// Prepared content facts only. Delivery must also own its explicit route lease after a hop;
    /// this value never admits a native camera action or a fresh library publication.
    var contentIsCurrent: Bool {
        if let canonicalCurrent {
            return canonicalCurrent()
                && (bytes?.namespace ?? store.root.absoluteString) == namespace
                && capturedIndexMatches && canonicalCurrent()
                && (bytes?.namespace ?? store.root.absoluteString) == namespace
        }
        return (bytes?.generation ?? 0) == generation
            && (bytes?.namespace ?? store.root.absoluteString) == namespace
            && capturedIndexMatches && (bytes?.generation ?? 0) == generation
            && (bytes?.namespace ?? store.root.absoluteString) == namespace
    }
    private var capturedIndexMatches: Bool {
        expected.values.allSatisfy { old in
            let current = store.list(cameraID: old.cameraID).first {
                $0.filename == old.filename
            }
            return current.map { Self.sameContent(old, $0) } ?? true
        }
    }
    var isCurrent: Bool {
        sourceIsCurrent && (deletionAuthority?.isCurrent ?? true)
            && (token.map { owner?.isCurrent($0) == true } ?? true)
    }
    func admitDeletion(_ authority: MonitorMediaLibraryDeletionAuthority) {
        deletionAuthority = authority
    }
    func capturedClip(_ clip: MediaClip) -> MediaClip { expected[clip.id] ?? clip }
    func canMutate(_ clip: MediaClip) -> Bool {
        guard isCurrent, let old = expected[clip.id] else { return false }
        let current = store.list(cameraID: clip.cameraID).first { $0.filename == clip.filename }
        if previouslyAbsent.contains(clip.id) {
            return current.map { Self.sameContent(old, $0) } ?? true
        }
        guard let current else { return false }
        return Self.sameContent(old, current)
    }
    static func sameContent(_ old: MediaClip, _ current: MediaClip) -> Bool {
        guard old.cameraID == current.cameraID, old.filename == current.filename else {
            return false
        }
        if !old.captureDate.isEmpty, !current.captureDate.isEmpty,
            old.captureDate != current.captureDate
        {
            return false
        }
        // Unknown size can acquire a real size. Only two conflicting known sizes prove replacement.
        if old.sizeBytes > 0, old.sizeBytes != 0xFFFF_FFFF,
            current.sizeBytes > 0, current.sizeBytes != 0xFFFF_FFFF,
            old.sizeBytes != current.sizeBytes
        {
            return false
        }
        return true
    }
    /// One batch publication; actual store mutations have already completed under captured admission.
    func publish() {
        guard isCurrent, let owner, let token else { return }
        var amendments: [MonitorMediaRecord<MediaClip>] = []
        var removed: [MediaAssetID] = []
        for old in capturedRecords {
            let current = store.list(cameraID: old.payload.cameraID).first {
                $0.filename == old.payload.filename
            }
            if let current {
                guard Self.sameContent(old.payload, current), let row = try? codec.record(current)
                else { continue }
                // Richer size/location metadata may retain the captured row identity.
                if row.asset.id == old.asset.id { amendments.append(row) }
            } else {
                removed.append(old.asset.id)
            }
        }
        let buckets = Set(owner.records.map { $0.payload.cameraID })
        let favorites = Set(
            buckets.flatMap { store.list(cameraID: $0) }.filter(\.isFavorite).map(\.id))
        try? owner.applyLocalRecords(
            .init(
                resetLibrary: false, upserts: [], removed: removed,
                amendments: amendments, sourceFavoriteKeys: favorites), token: token, persist: false
        )
    }
}
