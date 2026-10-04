import Foundation
import OpenCineCore
import OpenCineMedia
import OpenZCineCore

/// The exact native/common pair. Each primitive also checks actual root ownership.
@MainActor final class NikonMediaCatalogAdapter: NikonMediaIO {
    let native: NativeCameraSession
    let common: NikonCameraSession
    let cameraNamespace: String
    private let isCurrent: @MainActor () -> Bool
    init(
        native: NativeCameraSession, common: NikonCameraSession, namespace: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.native = native
        self.common = common
        cameraNamespace = namespace
        self.isCurrent = isCurrent
    }
    var sourceIdentity: NikonMediaSourceIdentity? {
        let snapshot = common.refresh()
        guard isCurrent(), snapshot.connection == .ready, snapshot.authority == .owner else {
            return nil
        }
        return .init(
            native: ObjectIdentifier(native), session: snapshot.session, epoch: snapshot.epoch)
    }
    private func require(_ source: NikonMediaSourceIdentity) throws {
        try Task.checkCancellation()
        guard sourceIdentity == source else { throw MediaServiceError.retired }
    }
    func storage(source: NikonMediaSourceIdentity) async throws -> [NikonMediaStorageRecord] {
        try require(source)
        let records = try await native.mediaStorageRecords { try await self.require(source) }
        try require(source)
        return records
    }
    func handles(source: NikonMediaSourceIdentity) async throws -> NikonMediaHandleSnapshot {
        try require(source)
        let value = try await native.mediaHandleSnapshot { try await self.require(source) }
        try require(source)
        return value
    }
    func handles(formats: [UInt32], source: NikonMediaSourceIdentity) async throws
        -> [MediaObjectHandle]
    {
        try require(source)
        let value = try await native.mediaFilteredHandles(formats: formats) {
            try await self.require(source)
        }
        try require(source)
        return value
    }
    func object(_ location: MediaObjectHandle, source: NikonMediaSourceIdentity) async throws
        -> NikonMediaObjectRecord?
    {
        try require(source)
        let value = await native.fetchMediaClip(
            handle: location.handle, storageID: location.storageID)
        try require(source)
        guard let value else { return nil }
        return .init(
            location: location, filename: value.info.filename, captureDate: value.info.captureDate,
            sizeBytes: UInt64(value.info.compressedSize),
            pixelWidth: value.info.imagePixWidth > 0 ? value.info.imagePixWidth : nil,
            pixelHeight: value.info.imagePixHeight > 0 ? value.info.imagePixHeight : nil)
    }
    func header(_ location: MediaObjectHandle, source: NikonMediaSourceIdentity) async throws
        -> Data?
    {
        try require(source)
        let value = try await native.getPartialObject(
            handle: location.handle, offset: 0,
            length: UInt32(R3DHeaderParser.minimumHeaderBytes))
        try require(source)
        return value
    }
    static func records(_ clips: [MediaClip]) -> [NikonMediaObjectRecord] {
        clips.flatMap { clip in
            clip.allLocations.map { location in
                .init(
                    location: location, filename: clip.filename, captureDate: clip.captureDate,
                    sizeBytes: clip.sizeBytes, pixelWidth: clip.pixelWidth,
                    pixelHeight: clip.pixelHeight,
                    sourcePixelWidth: clip.sourcePixelWidth,
                    sourcePixelHeight: clip.sourcePixelHeight,
                    linkedR3DFilename: clip.linkedR3DFilename)
            }
        }
    }
    static func pairingRecord(_ clip: MediaClip) -> NikonMediaPairingRecord {
        .init(
            filename: clip.filename, captureDate: clip.captureDate, sizeBytes: clip.sizeBytes,
            pixelWidth: clip.pixelWidth, pixelHeight: clip.pixelHeight,
            sourcePixelWidth: clip.sourcePixelWidth, sourcePixelHeight: clip.sourcePixelHeight,
            linkedR3DFilename: clip.linkedR3DFilename)
    }
    static func pairingRecords(_ clips: [MediaClip]) -> [NikonMediaPairingRecord] {
        clips.map(pairingRecord)
    }
    private static func applyPairing(_ update: NikonMediaPairingUpdate, to clip: inout MediaClip) {
        clip.sourcePixelWidth = update.width
        clip.sourcePixelHeight = update.height
        clip.linkedR3DFilename = update.masterFilename
    }
    static func clip(_ record: NikonMediaObjectRecord, bucket: String) -> MediaClip {
        .init(
            cameraID: bucket, filename: record.filename, handle: record.location.handle,
            storageID: record.location.storageID, sizeBytes: record.sizeBytes,
            captureDate: record.captureDate,
            pixelWidth: record.pixelWidth, pixelHeight: record.pixelHeight,
            sourcePixelWidth: record.sourcePixelWidth, sourcePixelHeight: record.sourcePixelHeight,
            linkedR3DFilename: record.linkedR3DFilename)
    }
    static func displayStorage(_ records: [NikonMediaStorageRecord], cameraName: String)
        -> [MediaStorageSlotDisplay]
    {
        records.enumerated().map { index, slot in
            let physicalSlot = Int((slot.id >> 16) & 0xFF)
            return .init(
                storageID: slot.id, slotNumber: physicalSlot > 0 ? physicalSlot : index + 1,
                cameraName: cameraName, usedGigabytes: slot.info.gigabytesUsed,
                freeGigabytes: slot.info.gigabytesFree, totalGigabytes: slot.info.gigabytesTotal)
        }.sorted { $0.slotNumber < $1.slotNumber }
    }
    /// Exact legacy persistence composition used by NativeAppModel's actual catalog caller.
    static func apply(
        _ delta: MediaCatalogDelta, service: NikonMediaService, binding: MediaBrowseBinding,
        bucket: String, store: MediaClipStore, current: [MediaClip],
        isDownloaded: (MediaClip) -> Bool,
        admit: () -> Bool
    ) throws -> [MediaClip] {
        guard admit(), service.isCurrent(binding) else { throw MediaServiceError.retired }
        let additions = try delta.upserts.map { asset -> MediaClip in
            guard let capture = service.mediaCatalogRecord(asset.id, binding: binding) else {
                throw MediaServiceError.retired
            }
            return clip(capture.object, bucket: bucket)
        }
        let removed = try delta.removed.map { id -> NikonMediaObjectRecord in
            guard let capture = service.mediaCatalogRecord(id, binding: binding) else {
                throw MediaServiceError.retired
            }
            return capture.object
        }
        guard let pairingUpdates = service.mediaPairingUpdates(binding: binding) else {
            throw MediaServiceError.retired
        }
        let stored = store.list(cameraID: bucket)
        let acceptedPairing = pairingUpdates.filter { update in
            stored.contains { pairingRecord($0) == update.previous }
        }
        let indexed = records(stored)
        let removedLocations = Set(
            removed.filter { old in
                indexed.contains { $0.location == old.location && $0.identity == old.identity }
            }.map(\.location))
        guard admit(), service.isCurrent(binding) else { throw MediaServiceError.retired }
        let removedFilenames = store.applyCameraRemoval(
            cameraID: bucket,
            removedHandles: removedLocations, hasLocalFile: isDownloaded)
        for update in acceptedPairing {
            guard
                store.list(cameraID: bucket).contains(where: {
                    pairingRecord($0) == update.previous
                })
            else { continue }
            store.update(cameraID: bucket, filename: update.previous.filename) { clip in
                guard pairingRecord(clip) == update.previous else { return }
                applyPairing(update, to: &clip)
            }
        }
        store.upsertBatch(additions, cameraID: bucket)
        var values = merged(
            current, additions: additions, removedFilenames: removedFilenames,
            removedLocations: removedLocations)
        for update in acceptedPairing {
            guard let index = values.firstIndex(where: { pairingRecord($0) == update.previous })
            else { continue }
            applyPairing(update, to: &values[index])
        }
        return values
    }
    static func merged(
        _ existing: [MediaClip], additions: [MediaClip], removedFilenames: Set<String>,
        removedLocations: Set<MediaObjectHandle>
    ) -> [MediaClip] {
        var byFilename: [String: MediaClip] = [:]
        for var clip in existing where !removedFilenames.contains(clip.filename) {
            let locations = clip.allLocations
            let survivors = locations.filter { !removedLocations.contains($0) }
            if survivors.count != locations.count {
                let primary = survivors.min {
                    MediaClipStore.locationRank($0) < MediaClipStore.locationRank($1)
                }
                clip.handle = primary?.handle
                clip.storageID = primary?.storageID
                clip.storageLocations = survivors.isEmpty ? nil : survivors
            }
            byFilename[clip.filename] = clip
        }
        for incoming in additions {
            if let old = byFilename[incoming.filename] {
                byFilename[incoming.filename] = MediaClipStore.mergeCameraDiscovery(
                    existing: old, incoming: incoming)
            } else {
                byFilename[incoming.filename] = incoming
            }
        }
        return Array(byFilename.values)
    }
}

extension MediaCategoryTab {
    var nikonMediaCategory: NikonMediaCategory {
        switch self {
        case .all: .all
        case .videos: .videos
        case .photos: .photos
        case .favorites: .favorites
        }
    }
    init(_ value: NikonMediaCategory) {
        switch value {
        case .all: self = .all
        case .videos: self = .videos
        case .photos: self = .photos
        case .favorites: self = .favorites
        }
    }
}
