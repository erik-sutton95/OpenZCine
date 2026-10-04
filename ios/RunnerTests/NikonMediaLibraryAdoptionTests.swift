import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import XCTest

@testable import Runner

@MainActor final class NikonMediaLibraryAdoptionTests: XCTestCase {
    func testLocationlessRowUsesExactExistingAddressWithoutInventingCameraFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var clip = sample()
        clip.handle = nil
        clip.storageID = nil
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let bytes = try XCTUnwrap(store.catalogBytes(cameraID: clip.cameraID))
        let codec = NikonMediaLibraryCodec(
            store: store, bucket: clip.cameraID, service: nil, downloaded: { _ in true })
        let record = try XCTUnwrap(codec.decode(bytes).first)
        XCTAssertEqual(record.payload, clip)
        XCTAssertNil(record.asset.volumeID)
        XCTAssertNil(record.asset.capturedAt)
        XCTAssertEqual(record.asset.filename, clip.filename)
        XCTAssertEqual(
            record.address.representations[record.asset.representations[0].id],
            "SIMULATED/Göteborg.MOV")
        XCTAssertEqual(try store.catalogBytes(cameraID: clip.cameraID), bytes)
    }

    func testCapturedCanonicalMetadataAmendsPayloadWithoutSourceCatalogOrSecondWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clip = sample()
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let codec = NikonMediaLibraryCodec(
            store: store, bucket: clip.cameraID, service: nil, downloaded: { _ in true })
        let byteStore = NikonMediaLibraryByteStore(
            store: store, bucket: clip.cameraID, admitted: { true })
        let cache = MonitorMediaCache(
            directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "SIMULATED/index.json", preservedMetadata: [], catalogStore: byteStore)
        let initial = try codec.record(clip)
        let owner = MonitorMediaLibraryModel(
            cache: cache,
            favorites: NikonMediaLibraryFavorites(store: store, buckets: [clip.cameraID]),
            cacheScanning: .background, initialCatalog: .init(), initialRecords: [initial])
        owner.selecting = true
        owner.selectedIDs = [initial.asset.id]
        let token = owner.actionToken
        store.update(cameraID: clip.cameraID, filename: clip.filename) {
            $0.isFavorite = false
            $0.starRating = 0
            $0.exportStatus = .exported
        }
        let changedBytes = try XCTUnwrap(store.catalogBytes(cameraID: clip.cameraID))
        let changed = try XCTUnwrap(codec.decode(changedBytes).first)
        try owner.applyLocalRecords(
            .init(
                resetLibrary: false, upserts: [], amendments: [changed],
                sourceFavoriteKeys: []), token: token)
        XCTAssertEqual(owner.records.first?.payload.starRating, 0)
        XCTAssertEqual(owner.records.first?.payload.exportStatus, .exported)
        XCTAssertEqual(owner.records.first?.favorite, false)
        XCTAssertEqual(owner.selectedIDs, [initial.asset.id])
        XCTAssertTrue(owner.catalog.assets.isEmpty)
        XCTAssertEqual(try store.catalogBytes(cameraID: clip.cameraID), changedBytes)
        owner.close()
    }

    func testCurrentDurableOperatorFlagsSurviveStaleDiscoveryCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let original = sample()
        store.upsertBatch([original], cameraID: original.cameraID)
        let codec = NikonMediaLibraryCodec(
            store: store, bucket: original.cameraID, service: nil, downloaded: { _ in true })
        var incoming = original
        incoming.sizeBytes = 8
        let captured = try codec.record(incoming)
        store.update(cameraID: original.cameraID, filename: original.filename) {
            $0.isFavorite = false
            $0.starRating = 0
            $0.frameioStatus = .uploaded
            $0.frameioFileID = "SIMULATED-upload"
            $0.exportStatus = .exported
        }
        let current = try XCTUnwrap(store.catalogBytes(cameraID: original.cameraID))
        let output = try XCTUnwrap(codec.encodeForPersistence([captured], currentBytes: current))
        let persisted = try XCTUnwrap(MediaClipStore.decodeCatalogBytes(output).first)
        XCTAssertEqual(persisted.sizeBytes, 8)
        XCTAssertFalse(persisted.isFavorite)
        XCTAssertEqual(persisted.starRating, 0)
        XCTAssertEqual(persisted.frameioStatus, .uploaded)
        XCTAssertEqual(persisted.frameioFileID, "SIMULATED-upload")
        XCTAssertEqual(persisted.exportStatus, .exported)
        XCTAssertEqual(try store.catalogBytes(cameraID: original.cameraID), current)
    }

    func testRetiredByteStoreCannotRewriteCanonicalIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clip = sample()
        store.upsertBatch([clip], cameraID: clip.cameraID)
        var admitted = true
        let bytes = NikonMediaLibraryByteStore(
            store: store, bucket: clip.cameraID, admitted: { admitted })
        let original = try XCTUnwrap(bytes.read())
        admitted = false
        XCTAssertThrowsError(try bytes.write(Data("retired".utf8), ifCurrent: { true }))
        XCTAssertEqual(try store.catalogBytes(cameraID: clip.cameraID), original)
    }

    func testStaleCatalogProjectionCannotRewriteActualFavoriteAndUploadActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let original = sample()
        store.upsertBatch([original], cameraID: original.cameraID)
        let codec = NikonMediaLibraryCodec(
            store: store, bucket: original.cameraID, service: nil, downloaded: { _ in true })
        var camera = original
        camera.sizeBytes = 8
        camera.handle = nil
        camera.storageID = nil
        let captured = try codec.record(camera)
        store.update(cameraID: original.cameraID, filename: original.filename) {
            $0.isFavorite = false
            $0.starRating = 0
            $0.frameioStatus = .uploaded
            $0.frameioFileID = "SIMULATED-successor"
            $0.exportStatus = .exported
        }
        let afterAction = try XCTUnwrap(store.catalogBytes(cameraID: original.cameraID))
        let favorites = NikonMediaLibraryFavorites(store: store, buckets: [original.cameraID])
        favorites.saveFavorites([original.id])
        XCTAssertEqual(try store.catalogBytes(cameraID: original.cameraID), afterAction)
        let prepared = try await codec.prepareCatalog(
            .init(
                resetLibrary: false, upserts: [],
                amendments: [captured], sourceFavoriteKeys: [original.id]),
            binding: .init(session: .init(), epoch: .init(1)), existing: [captured])
        let actual = try XCTUnwrap(prepared.amendments.first)
        XCTAssertFalse(actual.payload.isFavorite)
        XCTAssertEqual(actual.payload.starRating, 0)
        XCTAssertEqual(actual.payload.frameioStatus, .uploaded)
        XCTAssertEqual(actual.payload.frameioFileID, "SIMULATED-successor")
        XCTAssertEqual(actual.payload.exportStatus, .exported)
        XCTAssertEqual(actual.payload.sizeBytes, 8)
        XCTAssertNil(actual.payload.handle)
        XCTAssertNil(actual.payload.storageID)
        XCTAssertTrue(actual.payload.allLocations.isEmpty)
        XCTAssertEqual(prepared.sourceFavoriteKeys, [])
        XCTAssertEqual(try store.catalogBytes(cameraID: original.cameraID), afterAction)
    }

    func testActualBackgroundCallerRetiresOpenBeforeFetchingAndDrainsLateBrowse() async throws {
        // SIMULATED common service only. The actual NativeAppModel pause caller is exercised.
        let model = NativeAppModel()
        model.refreshMediaClips()
        let owner = try XCTUnwrap(model.mediaLibrary)
        XCTAssertFalse(model.pauseMediaListingForBackground())
        let source = LibraryGatedOpen()
        owner.bind(source)
        owner.begin()
        await source.entered.wait()
        XCTAssertTrue(owner.browsing)
        XCTAssertFalse(owner.fetching)
        XCTAssertNil(owner.binding)
        XCTAssertTrue(model.pauseMediaListingForBackground())
        XCTAssertFalse(owner.browsing)
        XCTAssertFalse(model.pauseMediaListingForBackground())
        source.release.signal()
        await source.browse.closed.wait()
        XCTAssertEqual(source.browse.closes, 1)
        XCTAssertNil(owner.binding)
        await owner.dispose()
    }

    func testActualDelayedRatingCompletionCannotRewriteSameKeyNewContentOrReboundGallery()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var old = sample()
        old.cameraID = MediaClipStore.localBucketID
        store.upsertBatch([old], cameraID: old.cameraID)
        model.refreshMediaClips()
        let owner = try XCTUnwrap(model.mediaLibrary)
        let entered = LibrarySignal()
        let release = LibrarySignal()
        let task = Task {
            await model.performCapturedMediaRating(for: old) {
                entered.signal()
                await release.wait()
                return 0
            }
        }
        await entered.wait()
        var successor = old
        successor.sizeBytes = 8
        store.upsertBatch([successor], cameraID: old.cameraID)
        model.refreshMediaClips()
        let successorBytes = try XCTUnwrap(store.catalogBytes(cameraID: old.cameraID))
        // The shared action token can remain current on same-key metadata replacement.
        XCTAssertTrue(owner === model.mediaLibrary)
        release.signal()
        let confirmed = await task.value
        XCTAssertEqual(confirmed, 0)
        XCTAssertEqual(try store.catalogBytes(cameraID: old.cameraID), successorBytes)
        XCTAssertEqual(model.mediaClips.first?.sizeBytes, 8)
        XCTAssertEqual(model.mediaClips.first?.starRating, 4)
        // A genuinely rebound gallery is independently protected even with unchanged content.
        let enteredAgain = LibrarySignal()
        let releaseAgain = LibrarySignal()
        let taskAgain = Task {
            await model.performCapturedMediaRating(for: successor) {
                enteredAgain.signal()
                await releaseAgain.wait()
                return 0
            }
        }
        await enteredAgain.wait()
        let capturedLifetime = owner.actionToken
        owner.close()
        model.mediaBrowserSource = .camera
        model.refreshMediaClips()
        let rebound = try XCTUnwrap(model.mediaLibrary)
        // Both offline sources resolve to the real local bucket: retirement is a token change.
        XCTAssertTrue(owner === rebound)
        XCTAssertFalse(owner.isCurrent(capturedLifetime))
        releaseAgain.signal()
        _ = await taskAgain.value
        XCTAssertEqual(try store.catalogBytes(cameraID: old.cameraID), successorBytes)
        await owner.dispose()
        await rebound.dispose()
    }

    func testActualDelayedDeleteCannotPurgeSuccessorBytesOrCleanupSuccessorProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var old = sample()
        old.cameraID = MediaClipStore.localBucketID
        store.upsertBatch([old], cameraID: old.cameraID)
        model.refreshMediaClips()
        let entered = LibrarySignal()
        let release = LibrarySignal()
        let task = Task {
            await model.deleteMediaClips(
                [old],
                deleteLocation: { location in
                    XCTAssertEqual(location.handle, old.handle)
                    entered.signal()
                    await release.wait()
                    return true
                })
        }
        await entered.wait()
        var successor = old
        successor.sizeBytes = 8
        store.upsertBatch([successor], cameraID: old.cameraID)
        let url = try store.localURL(cameraID: old.cameraID, filename: old.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let successorFile = Data(repeating: 9, count: 8)
        try successorFile.write(to: url)
        model.refreshMediaClips()
        model.mediaDeletionProgress = .init(completed: 2, total: 3, selectedCount: 3)
        let successorBytes = try XCTUnwrap(store.catalogBytes(cameraID: old.cameraID))
        release.signal()
        let removed = await task.value
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try Data(contentsOf: url), successorFile)
        XCTAssertEqual(try store.catalogBytes(cameraID: old.cameraID), successorBytes)
        XCTAssertEqual(model.mediaDeletionProgress?.completed, 2)
        XCTAssertEqual(model.mediaClips.first?.sizeBytes, 8)
        await model.mediaLibrary?.dispose()
    }

    func testActualDeleteBatchPublishesOnceAndRetainsProtectedBackupAndLocalFlags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var removed = sample()
        removed.cameraID = MediaClipStore.localBucketID
        var protected = removed
        protected.filename = "SIMULATED-protected.MOV"
        protected.handle = 5
        protected.storageLocations = [
            .init(storageID: 65_537, handle: 5), .init(storageID: 131_073, handle: 6),
        ]
        protected.frameioStatus = .uploaded
        protected.frameioFileID = "SIMULATED-protected"
        store.upsertBatch([removed, protected], cameraID: removed.cameraID)
        model.refreshMediaClips()
        let owner = try XCTUnwrap(model.mediaLibrary)
        owner.selecting = true
        owner.selectedIDs = Set(owner.records.map { $0.asset.id })
        let originalRows = model.mediaClips
        let count = await model.deleteMediaClips(
            [removed, protected],
            deleteLocation: { location in
                // Canonical mutations occur per object, while the original visible grid stays steady.
                XCTAssertEqual(model.mediaClips, originalRows)
                return location.handle != 6
            })
        XCTAssertEqual(count, 1)
        let survivor = try XCTUnwrap(model.mediaClips.first)
        XCTAssertEqual(model.mediaClips.count, 1)
        XCTAssertEqual(survivor.filename, protected.filename)
        XCTAssertEqual(survivor.allLocations, [.init(storageID: 131_073, handle: 6)])
        XCTAssertEqual(survivor.starRating, 4)
        XCTAssertTrue(survivor.isFavorite)
        XCTAssertEqual(survivor.frameioFileID, "SIMULATED-protected")
        XCTAssertEqual(owner.selectedIDs, Set(owner.records.map { $0.asset.id }))
        XCTAssertTrue(owner.catalog.assets.isEmpty)
        await owner.dispose()
    }

    func testActualUnknownSizeStrengtheningAcceptsCurrentRatingWithoutSecondWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var old = sample()
        old.cameraID = MediaClipStore.localBucketID
        old.sizeBytes = 0
        store.upsertBatch([old], cameraID: old.cameraID)
        model.refreshMediaClips()
        let entered = LibrarySignal()
        let release = LibrarySignal()
        let task = Task {
            await model.performCapturedMediaRating(for: old) {
                entered.signal()
                await release.wait()
                return 0
            }
        }
        await entered.wait()
        var strengthened = old
        strengthened.sizeBytes = 4
        store.upsertBatch([strengthened], cameraID: old.cameraID)
        model.refreshMediaClips()
        release.signal()
        _ = await task.value
        let row = try XCTUnwrap(store.list(cameraID: old.cameraID).first)
        XCTAssertEqual(row.sizeBytes, 4)
        XCTAssertEqual(row.starRating, 0)
        XCTAssertFalse(row.isFavorite)
        XCTAssertEqual(model.mediaClips.first?.starRating, 0)
        XCTAssertEqual(model.mediaClips.first?.sizeBytes, 4)
        await model.mediaLibrary?.dispose()
    }

    func testActualFavoriteKeepsCoupledImmediateWriteAndRejectsDelayedConfirmationIntoNewContent()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var old = sample()
        old.cameraID = MediaClipStore.localBucketID
        old.isFavorite = false
        old.starRating = 0
        store.upsertBatch([old], cameraID: old.cameraID)
        model.refreshMediaClips()
        let entered = LibrarySignal()
        let release = LibrarySignal()
        let task = try XCTUnwrap(
            model.toggleClipFavorite(
                old,
                ratingOperation: { requested, sentClip in
                    XCTAssertEqual(requested, 1)
                    XCTAssertEqual(sentClip.handle, old.handle)
                    entered.signal()
                    await release.wait()
                    return 4
                }))
        await entered.wait()
        XCTAssertTrue(try XCTUnwrap(store.list(cameraID: old.cameraID).first).isFavorite)
        XCTAssertEqual(model.mediaClips.first?.starRating, 1)
        var successor = old
        successor.sizeBytes = 8
        store.upsertBatch([successor], cameraID: old.cameraID)
        model.refreshMediaClips()
        let successorBytes = try XCTUnwrap(store.catalogBytes(cameraID: old.cameraID))
        release.signal()
        await task.value
        XCTAssertEqual(try store.catalogBytes(cameraID: old.cameraID), successorBytes)
        XCTAssertEqual(model.mediaClips.first?.sizeBytes, 8)
        XCTAssertEqual(model.mediaClips.first?.starRating, 1)
        await model.mediaLibrary?.dispose()
    }

    func testActualRatingAcceptsMatchingCanonicalRowFirstPersistedDuringNativeOperation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var observed = sample()
        observed.cameraID = MediaClipStore.localBucketID
        model.refreshMediaClips()
        model.mediaClips = [observed]
        XCTAssertTrue(store.list(cameraID: observed.cameraID).isEmpty)
        let owner = try XCTUnwrap(model.mediaLibrary)
        let diagnosticAction = try XCTUnwrap(model.captureMediaLibraryAction([observed]))
        XCTAssertTrue(diagnosticAction.isCurrent, "Captured action before native suspension")
        XCTAssertTrue(diagnosticAction.canMutate(observed), "Absent canonical row is admitted")
        let entered = LibrarySignal()
        let release = LibrarySignal()
        let pending = Task {
            await model.performCapturedMediaRating(for: observed) {
                entered.signal()
                await release.wait()
                return 0
            }
        }
        await entered.wait()
        store.upsertBatch([observed], cameraID: observed.cameraID)
        model.refreshMediaClips()
        XCTAssertTrue(owner === model.mediaLibrary)
        XCTAssertTrue(diagnosticAction.isCurrent, "Matching canonical insertion retains admission")
        XCTAssertTrue(diagnosticAction.canMutate(observed), "Current inserted row matches captured content")
        release.signal()
        let confirmed = await pending.value
        XCTAssertEqual(confirmed, 0)
        let canonical = try XCTUnwrap(store.list(cameraID: observed.cameraID).first)
        XCTAssertEqual(canonical.sizeBytes, observed.sizeBytes)
        XCTAssertEqual(canonical.starRating, 0)
        XCTAssertFalse(canonical.isFavorite)
        XCTAssertEqual(model.mediaClips.first?.starRating, 0)
        XCTAssertEqual(model.mediaClips.first?.sizeBytes, observed.sizeBytes)
        XCTAssertTrue(owner.catalog.assets.isEmpty)
        await owner.dispose()
    }

    private func sample() -> MediaClip {
        var clip = MediaClip(
            cameraID: "SIMULATED", filename: "Göteborg.MOV", handle: 4,
            storageID: 65_537, sizeBytes: 4, captureDate: "20261004T120000")
        clip.isFavorite = true
        clip.starRating = 4
        return clip
    }
}

@MainActor private final class LibrarySignal {
    private var ready = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func signal() {
        ready = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}

@MainActor private final class LibraryGatedOpen: CameraMediaService {
    var sessionID: CameraSessionID { browse.binding.session }
    let entered = LibrarySignal(), release = LibrarySignal()
    let browse = LibraryEmptyBrowse()
    func openBrowse() async throws -> any CameraMediaBrowse {
        entered.signal()
        await release.wait()
        return browse
    }
}

@MainActor private final class LibraryEmptyBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    let thumbnails: (any CameraMediaThumbnailService)? = nil
    let transfers: (any CameraMediaTransferService)? = nil
    let deletion: (any CameraMediaDeleteService)? = nil
    let closed = LibrarySignal()
    private(set) var closes = 0
    func catalog() async throws -> any MediaCatalogCursor { LibraryEmptyCursor() }
    func close() async {
        closes += 1
        closed.signal()
    }
}

@MainActor private final class LibraryEmptyCursor: MediaCatalogCursor {
    func next() async throws -> MediaCatalogDelta? { nil }
    func close() {}
}
