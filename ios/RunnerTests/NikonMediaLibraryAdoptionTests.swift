import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import OpenZCineCore
import Testing
import XCTest

@testable import Runner

@Suite("Playback favorite persistence")
@MainActor struct NikonPlaybackFavoritePersistenceTests {
    @Test func retainedPlaybackCannotFavoriteReplacementContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        let original = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "REPLACED.MOV", handle: nil,
            storageID: nil, sizeBytes: 4, captureDate: "20261011T120000")
        store.upsertBatch([original], cameraID: original.cameraID)
        model.refreshMediaClips()
        let library = try #require(model.mediaLibrary)
        let playbackRecord = try #require(library.records.first)
        var replacement = original
        replacement.sizeBytes = 8
        replacement.captureDate = "20261011T120001"
        store.upsertBatch([replacement], cameraID: replacement.cameraID)
        let beforeBytes = try store.catalogBytes(cameraID: replacement.cameraID)
        let before = try #require(beforeBytes)
        model.toggleClipFavorite(playbackRecord.payload)
        #expect(try store.catalogBytes(cameraID: replacement.cameraID) == before)
        await library.dispose()
    }

    @Test func cameraRatingOnlyFavoriteClearsAndStalePlaybackRecordTogglesCurrentRow() async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "RATED.MOV", handle: nil,
            storageID: nil, sizeBytes: 4, captureDate: "20261011T120000")
        clip.starRating = 4
        clip.isFavorite = false
        store.upsertBatch([clip], cameraID: clip.cameraID)
        model.refreshMediaClips()
        let library = try #require(model.mediaLibrary)
        let record = try #require(library.records.first)
        #expect(record.favorite)
        // Playback keeps its captured record while the canonical catalog amends operator flags.
        model.toggleClipFavorite(record.payload)
        let cleared = try #require(store.list(cameraID: clip.cameraID).first)
        #expect(!cleared.isFavorited)
        #expect(cleared.starRating == 0)
        #expect(library.record(record.asset.id)?.favorite == false)
        model.toggleClipFavorite(record.payload)
        let selected = try #require(store.list(cameraID: clip.cameraID).first)
        #expect(selected.isFavorite)
        #expect(selected.starRating == 1)
        #expect(library.record(record.asset.id)?.favorite == true)
        let reopened = MediaClipStore(root: root)
        #expect(reopened.list(cameraID: clip.cameraID).first?.starRating == 1)
        await library.dispose()
    }
}

@MainActor final class NikonMediaLibraryAdoptionTests: XCTestCase {
    /// Actual source capture, frozen related targets and performer; all locations are SIMULATED.
    func testPlaybackDeletionLateMasterRequiresFreshConfirmationAndPerformsNoDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var proxy = sample()
        proxy.cameraID = MediaClipStore.localBucketID
        proxy.filename = "SIMULATED.MOV"
        store.upsertBatch([proxy], cameraID: proxy.cameraID)
        model.refreshMediaClips()
        model.mediaBrowserSource = .camera
        model.connection = .connected
        let before = try XCTUnwrap(store.catalogBytes(cameraID: proxy.cameraID))
        var deletes = 0
        var cleanups = 0
        let request = try XCTUnwrap(
            model.capturePlaybackMediaDeletion(
                proxy,
                cleanup: {
                    cleanups += 1
                    return true
                },
                deleteLocation: { _ in
                    deletes += 1
                    return true
                }))
        XCTAssertFalse(request.confirmation.message?.contains("master") ?? true)
        var master = proxy
        master.filename = "SIMULATED.NEV"
        master.handle = 99
        // The actually displayed mutable catalog discovers a master after the request was captured.
        model.mediaClips.append(master)
        await request.perform()
        XCTAssertEqual(cleanups, 0)
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(try store.catalogBytes(cameraID: proxy.cameraID), before)
        request.authority.retire()
        await model.mediaLibrary?.dispose()
    }

    func testPlaybackDeletionSourceRetirementDuringCleanupPerformsNoNativeDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        var clip = sample()
        clip.cameraID = MediaClipStore.localBucketID
        store.upsertBatch([clip], cameraID: clip.cameraID)
        model.refreshMediaClips()
        model.mediaBrowserSource = .camera
        model.connection = .connected
        let library = try XCTUnwrap(model.mediaLibrary)
        let before = try XCTUnwrap(store.catalogBytes(cameraID: clip.cameraID))
        let entered = LibrarySignal()
        let release = LibrarySignal()
        var deletes = 0
        let request = try XCTUnwrap(
            model.capturePlaybackMediaDeletion(
                clip,
                cleanup: {
                    entered.signal()
                    await release.wait()
                    return true
                },
                deleteLocation: { _ in
                    deletes += 1
                    return true
                }))
        let task = Task { await request.perform() }
        await entered.wait()
        XCTAssertEqual(deletes, 0)
        library.close()
        release.signal()
        await task.value
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(try store.catalogBytes(cameraID: clip.cameraID), before)
        request.authority.retire()
        await library.dispose()
    }

    func testPlaybackEligibilityPreservesNativeKindAndCanonicalRawMasterIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let codec = NikonMediaLibraryCodec(
            store: store, bucket: "SIMULATED", service: nil, downloaded: { _ in true })
        for (name, eligible) in [
            ("PROXY.MOV", true), ("MASTER.R3D", false), ("STILL.NEF", true), ("UNKNOWN.BIN", false),
        ] {
            var clip = sample()
            clip.filename = name
            let record = try codec.record(clip)
            XCTAssertEqual(record.facts.playbackEligible, eligible)
            XCTAssertEqual(record.payload, clip)
            XCTAssertEqual(record.asset.filename, name)
            XCTAssertEqual(
                record.address.representations[record.asset.representations[0].id],
                "SIMULATED/" + name)
        }
    }

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
        XCTAssertTrue(
            diagnosticAction.canMutate(observed), "Current inserted row matches captured content")
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

/// SIMULATED: real file descriptors and NativeCameraSession, no camera or giant allocation.
@MainActor @Suite struct NikonLargeObjectTransferTests {
    @Test func sparseResumeReturnsTheExactOpenedDescriptorExtentAboveFourGiB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let (file, _) = try store.openForStreaming(cameraID: "SIMULATED", filename: "LARGE.MOV")
        let extent = UInt64(UInt32.max) + 17
        try file.truncate(atOffset: extent)
        try file.close()
        let (resumed, offset) = try store.openForStreaming(
            cameraID: "SIMULATED", filename: "LARGE.MOV")
        defer { try? resumed.close() }
        #expect(UInt64(offset) == extent)
        #expect(try resumed.offset() == extent)
    }

    @Test func actualStreamResumesAboveBoundaryAndContinuesShortChunks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let (file, _) = try store.openForStreaming(cameraID: "SIMULATED", filename: "LARGE.MOV")
        let start = UInt64(UInt32.max) + 9
        try file.truncate(atOffset: start)
        try file.close()
        let transport = LargeTransferTransport(
            operations: [.getPartialObjectEx], chunks: [Data([1, 2]), Data([3, 4, 5]), Data([6])])
        let session = try await establish(transport)
        defer { session.close() }
        await transport.clear()
        var progress: [UInt64] = []
        let end = try await NikonMediaObjectTransfer.stream(
            session: session, handle: 7, totalBytes: start + 6, store: store,
            cameraID: "SIMULATED", filename: "LARGE.MOV", onProgress: { progress.append($0) })
        #expect(end == start + 6 && progress == [start, start + 2, start + 5, start + 6])
        let calls = await transport.calls
        #expect(
            calls.map(\.operation) == [
                .getPartialObjectEx, .getPartialObjectEx, .getPartialObjectEx,
            ])
        #expect(
            calls.map(\.parameters) == [[7, 8, 1, 6, 0], [7, 10, 1, 4, 0], [7, 13, 1, 1, 0]])
        let url = try store.localURL(cameraID: "SIMULATED", filename: "LARGE.MOV")
        let check = try FileHandle(forReadingFrom: url)
        defer { try? check.close() }
        try check.seek(toOffset: start)
        #expect(try check.read(upToCount: 6) == Data([1, 2, 3, 4, 5, 6]))
    }

    @Test func actualRequestsKeepTransportSpecificChunkScheduling() async throws {
        for kind in [CameraTransportKind.usb, .ptpIP] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = LargeTransferTransport(operations: [.getPartialObject], kind: kind)
            let session = try await establish(transport)
            defer { session.close() }
            await transport.clear()
            await #expect(throws: PTPObjectTransferError.self) {
                try await NikonMediaObjectTransfer.stream(
                    session: session, handle: 7, totalBytes: 8 << 20,
                    store: MediaClipStore(root: root), cameraID: "SIMULATED", filename: "CHUNK.MOV",
                    onProgress: { _ in })
            }
            let call = try #require(await transport.calls.first)
            #expect(call.operation == .getPartialObject)
            #expect(call.parameters == [7, 0, kind == .usb ? 4 << 20 : 1 << 20])
        }
    }

    @Test func unsupportedAndUnknownTransfersPreserveExistingBytesAndSendNoRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let (file, _) = try store.openForStreaming(cameraID: "SIMULATED", filename: "KEEP.MOV")
        try file.write(contentsOf: Data([4, 5, 6]))
        try file.close()
        let transport = LargeTransferTransport(operations: [.getPartialObject])
        let session = try await establish(transport)
        defer { session.close() }
        await transport.clear()
        for total in [UInt64(0), UInt64(UInt32.max), UInt64(UInt32.max) + 10] {
            await #expect(throws: PTPObjectTransferError.self) {
                try await NikonMediaObjectTransfer.stream(
                    session: session, handle: 7, totalBytes: total, store: store,
                    cameraID: "SIMULATED", filename: "KEEP.MOV",
                    onProgress: { _ in Issue.record("Unexpected progress") })
            }
            #expect(
                try Data(contentsOf: store.localURL(cameraID: "SIMULATED", filename: "KEEP.MOV"))
                    == Data([4, 5, 6]))
        }
        #expect(await transport.calls.isEmpty)
        let model = NativeAppModel(mediaClipStore: store)
        for total in [UInt64(0), UInt64(UInt32.max)] {
            let clip = MediaClip(
                cameraID: "SIMULATED", filename: "KEEP.MOV", handle: 7,
                storageID: 65_537, sizeBytes: total, captureDate: "")
            #expect(!model.isClipDownloaded(clip))
        }
    }

    @Test func indexedLocalUnknownSizePreservesActualCachedFileAndOperatorMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "LOCAL.MOV",
            handle: nil, storageID: nil, sizeBytes: 0, captureDate: "")
        clip.isFavorite = true
        clip.starRating = 4
        clip.exportStatus = .exported
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let (file, _) = try store.openForStreaming(cameraID: clip.cameraID, filename: clip.filename)
        try file.write(contentsOf: Data([4, 5, 6]))
        try file.close()
        let model = NativeAppModel(mediaClipStore: store)
        #expect(model.isClipDownloaded(clip))
        #expect(model.hasCachedMediaClips)
        let indexed = try #require(store.list(cameraID: clip.cameraID).first)
        #expect(indexed.sizeBytes == 0 && indexed.isFavorite && indexed.starRating == 4)
        #expect(indexed.exportStatus == .exported && indexed.handle == nil)
        #expect(
            try Data(contentsOf: store.localURL(cameraID: clip.cameraID, filename: clip.filename))
                == Data([4, 5, 6]))
    }

    @Test func unknownCameraCacheRetainsMetadataWithoutClaimingCompletedDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var clip = MediaClip(
            cameraID: "SIMULATED", filename: "KEEP.MOV", handle: 7,
            storageID: 65_537, sizeBytes: 0, captureDate: "")
        clip.isFavorite = true
        clip.starRating = 4
        clip.exportStatus = .exported
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let (file, _) = try store.openForStreaming(cameraID: clip.cameraID, filename: clip.filename)
        try file.write(contentsOf: Data([4, 5, 6]))
        try file.close()
        let model = NativeAppModel(mediaClipStore: store)
        #expect(!model.isClipDownloaded(clip))
        #expect(model.retainsLocalMediaClip(clip))
        let removed = store.applyCameraRemoval(
            cameraID: clip.cameraID,
            removedHandles: [.init(storageID: 65_537, handle: 7)],
            hasLocalFile: model.retainsLocalMediaClip)
        #expect(removed.isEmpty)
        let retained = try #require(store.list(cameraID: clip.cameraID).first)
        #expect(retained.handle == nil && retained.storageID == nil)
        #expect(
            retained.isFavorite && retained.starRating == 4 && retained.exportStatus == .exported)
        #expect(retained.sizeBytes == 0 && model.isClipDownloaded(retained))
        #expect(
            try Data(contentsOf: store.localURL(cameraID: clip.cameraID, filename: clip.filename))
                == Data([4, 5, 6]))
    }

    @Test func invalidChunksAreRejectedBeforeAnyBytesOrDurableProgress() async throws {
        for payload in [Data(), Data([1, 2, 3, 4, 5])] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = MediaClipStore(root: root)
            let transport = LargeTransferTransport(
                operations: [.getPartialObject], chunks: [payload])
            let session = try await establish(transport)
            defer { session.close() }
            var progress: [UInt64] = []
            await #expect(throws: PTPObjectTransferError.self) {
                try await NikonMediaObjectTransfer.stream(
                    session: session, handle: 7, totalBytes: 4, store: store,
                    cameraID: "SIMULATED", filename: "INVALID.MOV",
                    onProgress: { progress.append($0) })
            }
            #expect(progress == [0])
            #expect(
                try Data(contentsOf: store.localURL(cameraID: "SIMULATED", filename: "INVALID.MOV"))
                    .isEmpty)
        }
    }

    @Test func cancellationAfterReadDoesNotWriteOrPublishStaleBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let transport = LargeTransferTransport(
            operations: [.getPartialObject], chunks: [Data([1, 2, 3, 4])], holdRead: true)
        let session = try await establish(transport)
        defer { session.close() }
        var progress: [UInt64] = []
        let task = Task {
            try await NikonMediaObjectTransfer.stream(
                session: session, handle: 7, totalBytes: 4, store: store,
                cameraID: "SIMULATED", filename: "CANCEL.MOV", onProgress: { progress.append($0) })
        }
        await transport.waitUntilRead()
        task.cancel()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(progress == [0])
        #expect(
            try Data(contentsOf: store.localURL(cameraID: "SIMULATED", filename: "CANCEL.MOV"))
                .isEmpty)
    }

    @Test func catalogResolvesSentinelOrPreservesAnUnknownVisibleRow() async throws {
        for supported in [true, false] {
            let total = UInt64(UInt32.max) + 700
            let transport = LargeTransferTransport(
                operations: supported ? [.getObjectSize] : [.getPartialObject], totalBytes: total)
            let session = try await establish(transport)
            defer { session.close() }
            let driver = LargeTransferControlDriver()
            let common = NikonCameraSession(driver: driver, serialNumber: "SIMULATED")
            let io = NikonMediaCatalogAdapter(
                native: session, common: common, namespace: "SIMULATED", isCurrent: { true })
            let source = try #require(io.sourceIdentity)
            let row = try #require(
                try await io.object(.init(storageID: 65_537, handle: 7), source: source))
            #expect(row.filename == "SIMULATED-LARGE.MOV")
            #expect(row.sizeBytes == (supported ? total : UInt64(UInt32.max)))
            #expect(row.knownSize == (supported ? total : nil))
            #expect(
                NikonMediaCatalogAdapter.clip(row, bucket: "SIMULATED").sizeBytes == row.sizeBytes)
            let sizeReads = await transport.calls.filter { $0.operation == .getObjectSize }
            #expect(sizeReads.count == (supported ? 1 : 0))
        }
    }

    private func establish(_ transport: LargeTransferTransport) async throws -> NativeCameraSession
    {
        try await NativeCameraSession.establish(
            transport: transport,
            host: "usb:SIMULATED-large", cameraName: "SIMULATED", requestPairing: false)
    }
}

@MainActor private final class LargeTransferControlDriver: NikonControlDriver {
    var nikonControlFacts = NikonControlFacts()
    func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?
    ) -> Int { 0 }
    func queueRecord(start: Bool, operation: OperationID) {}
}

actor LargeTransferTransport: CameraTransport {
    struct Call: Sendable {
        let operation: PTPOperationCode
        let parameters: [UInt32]
        let dataOut: Data?
    }
    nonisolated let kind: CameraTransportKind
    let operations: [PTPOperationCode]
    let totalBytes: UInt64
    var chunks: [Data]
    var holdRead: Bool
    private(set) var calls: [Call] = []
    private var propertyValues: [PTPPropertyCode: Data] = [:]
    private var refuseWrite = false
    private var readEntered = false
    private var readsEntered = 0
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var entered: CheckedContinuation<Void, Never>?
    private var releaseRead: CheckedContinuation<Void, Never>?
    /// How a scripted object read fails: the link dies, or the camera refuses it.
    enum ReadFailure: Sendable { case linkLost, refused }
    private var readFailures: [Int: ReadFailure] = [:]
    init(
        operations: [PTPOperationCode], chunks: [Data] = [],
        totalBytes: UInt64 = UInt64(UInt32.max) + 700, holdRead: Bool = false,
        kind: CameraTransportKind = .usb
    ) {
        self.kind = kind
        self.operations = operations
        self.chunks = chunks
        self.totalBytes = totalBytes
        self.holdRead = holdRead
    }
    func clear() { calls = [] }
    func refuseNextWrite() { refuseWrite = true }
    /// The `number`th object read (counting from 1) fails this way.
    func failRead(_ number: Int, _ failure: ReadFailure) { readFailures[number] = failure }
    func executeTransaction(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        calls.append(.init(operation: operationCode, parameters: parameters, dataOut: dataOut))
        var data = Data()
        switch operationCode {
        case .setDevicePropValue:
            if let rawProperty = parameters.first,
                let property = PTPPropertyCode(rawValue: rawProperty)
            {
                if refuseWrite {
                    propertyValues[property] = Data([0])
                    refuseWrite = false
                } else {
                    propertyValues[property] = dataOut
                }
            }
        case .getDevicePropValue:
            if let rawProperty = parameters.first,
                let property = PTPPropertyCode(rawValue: rawProperty)
            {
                data = propertyValues[property] ?? Data()
            }
        case .getDeviceInfo: data = deviceInfo()
        case .getObjectSize: data = Data(ByteCoding.uint64LE(totalBytes))
        case .getObjectInfo: data = objectInfo()
        case .getPartialObject, .getPartialObjectEx:
            readsEntered += 1
            let ready = readWaiters.filter { $0.count <= readsEntered }
            readWaiters.removeAll { $0.count <= readsEntered }
            for waiter in ready { waiter.continuation.resume() }
            switch readFailures.removeValue(forKey: readsEntered) {
            case .linkLost: throw NativeCameraSessionError.connectionClosed
            case .refused:
                let refusal =
                    ByteCoding.uint16LE(PTPResponseCode.deviceBusy.rawValue)
                    + ByteCoding.uint32LE(transactionID ?? 1)
                return PTPIPTransactionResult(
                    operationResponse: try PTPOperationResponse(payloadBytes: refusal),
                    data: Data())
            case nil: break
            }
            if holdRead {
                readEntered = true
                entered?.resume()
                entered = nil
                await withCheckedContinuation { releaseRead = $0 }
            }
            data = chunks.isEmpty ? Data() : chunks.removeFirst()
        default: break
        }
        let bytes =
            ByteCoding.uint16LE(PTPResponseCode.ok.rawValue)
            + ByteCoding.uint32LE(transactionID ?? 1)
        return PTPIPTransactionResult(
            operationResponse: try PTPOperationResponse(payloadBytes: bytes), data: data)
    }
    func waitUntilRead() async {
        if readEntered { return }
        await withCheckedContinuation { entered = $0 }
    }
    /// Returns once `count` object reads have reached the camera.
    func waitUntilReads(_ count: Int) async {
        if readsEntered >= count { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }
    func release() {
        releaseRead?.resume()
        releaseRead = nil
    }
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    nonisolated func close() {}
    private func string(_ value: String) -> [UInt8] {
        [UInt8(value.utf16.count + 1)] + value.utf16.flatMap { ByteCoding.uint16LE($0) } + [0, 0]
    }
    private func deviceInfo() -> Data {
        var bytes: [UInt8] = [100, 0, 10, 0, 0, 0, 100, 0, 0, 0, 0]
        bytes += ByteCoding.uint32LE(UInt32(operations.count))
        for operation in operations { bytes += ByteCoding.uint16LE(operation.rawValue) }
        for _ in 0..<4 { bytes += ByteCoding.uint32LE(0) }
        for value in ["SIMULATED", "SIMULATED", "1.0", "SIMULATED-large"] { bytes += string(value) }
        return Data(bytes)
    }
    private func objectInfo() -> Data {
        var bytes = [UInt8](repeating: 0, count: 52)
        bytes.replaceSubrange(0..<4, with: ByteCoding.uint32LE(65_537))
        bytes.replaceSubrange(4..<6, with: ByteCoding.uint16LE(0x300D))
        bytes.replaceSubrange(8..<12, with: ByteCoding.uint32LE(UInt32.max))
        bytes += string("SIMULATED-LARGE.MOV") + string("20261011T120000")
        return Data(bytes)
    }
}

/// SIMULATED source identity only; no camera IO is performed.
@MainActor private final class RebindIO: NikonMediaIO {
    let session = CameraSessionID()
    let native = NSObject()
    let cameraNamespace = "SIMULATED-CAMERA"
    var sourceIdentity: NikonMediaSourceIdentity? {
        .init(native: ObjectIdentifier(native), session: session, epoch: ControlEpoch(1))
    }
    func storage(source _: NikonMediaSourceIdentity) async throws -> [NikonMediaStorageRecord] {
        []
    }
    func handles(source _: NikonMediaSourceIdentity) async throws -> NikonMediaHandleSnapshot {
        .init(handles: [], authoritativeStorages: [], storageListAuthoritative: true)
    }
    func handles(formats _: [UInt32], source _: NikonMediaSourceIdentity) async throws
        -> [MediaObjectHandle]
    { [] }
    func object(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> NikonMediaObjectRecord?
    { nil }
    func header(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> Data?
    { nil }
}

extension NikonMediaLibraryAdoptionTests {
    /// A2-02: a link change rebinds the open gallery's owner; only a new bucket replaces it.
    func testServiceChangeRebindsTheGalleryOwnerInsteadOfReplacingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(mediaClipStore: MediaClipStore(root: root))
        model.prepareMediaLibrary(rows: [], bucket: "SIMULATED-CAMERA", service: nil)
        let owner = try XCTUnwrap(model.mediaLibrary)
        XCTAssertFalse(owner.canRefresh)
        let io = RebindIO()
        model.prepareMediaLibrary(
            rows: [], bucket: "SIMULATED-CAMERA",
            service: NikonMediaService(session: io.session, io: io))
        XCTAssertTrue(
            model.mediaLibrary === owner, "A link change must rebind, not replace, the owner")
        XCTAssertTrue(owner.canRefresh)
        model.prepareMediaLibrary(rows: [], bucket: "SIMULATED-CAMERA", service: nil)
        XCTAssertTrue(model.mediaLibrary === owner)
        XCTAssertFalse(owner.canRefresh)
        model.prepareMediaLibrary(rows: [], bucket: MediaClipStore.localBucketID, service: nil)
        XCTAssertFalse(model.mediaLibrary === owner, "A different bucket is a different owner")
        await model.mediaLibrary?.dispose()
        await owner.dispose()
    }
}

extension NikonMediaLibraryAdoptionTests {
    /// A2-43: offline, Delete is offered only where deletion removes something.
    func testOfflineDeleteIsOfferedOnlyForPhoneOnlyCopies() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NativeAppModel(mediaClipStore: MediaClipStore(root: root))
        let onCamera = MediaClip(
            cameraID: "SIMULATED-CAMERA", filename: "SIMULATED-CAMERA.MOV", handle: 7,
            storageID: 65_537, sizeBytes: 10, captureDate: "20261012T120000")
        let phoneOnly = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-PHONE.MOV", handle: nil,
            storageID: nil, sizeBytes: 10, captureDate: "20261012T120000")
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(
            model.canDeleteMedia([onCamera]), "Offline, a camera object cannot be removed")
        XCTAssertTrue(model.canDeleteMedia([phoneOnly]))
        XCTAssertTrue(model.canDeleteMedia([onCamera, phoneOnly]))
    }
}

#if DEBUG
    extension NikonMediaLibraryAdoptionTests {
        /// SIMULATED card ownership ends with the demo, even if a cached camera row remains.
        func testReviewCameraDeleteRetiresWithDemoSession() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = NativeAppModel(mediaClipStore: MediaClipStore(root: root))
            let onCamera = MediaClip(
                cameraID: "SIMULATED-CAMERA", filename: "SIMULATED-CAMERA.MOV", handle: 7,
                storageID: 65_537, sizeBytes: 10, captureDate: "20261012T120000")
            model.isDemoSession = true
            model.reviewCameraDelete = { _ in true }
            XCTAssertTrue(model.canDeleteMedia([onCamera]))
            model.clearCameraSessionState(resetConnection: true)
            XCTAssertFalse(model.isDemoSession)
            XCTAssertNil(model.reviewCameraDelete)
            XCTAssertFalse(
                model.canDeleteMedia([onCamera]), "Retired review cannot authorize camera deletion")
        }
    }
#endif

/// REQ-MEDIA-THUMB-ORIENTATION: camera thumbnails now arrive tagged with their still's
/// orientation. Ones cached earlier drew portrait stills sideways in the Media grid and stayed
/// cached, so they are retired once and fetched again upright.
@Suite("Camera thumbnails cached without their still's orientation")
struct NikonUnorientedThumbnailRetirementTests {
    private static let camera = "6002199"

    private static func row(_ filename: String, orientation: Int? = nil) -> MediaClip {
        var clip = MediaClip(
            cameraID: camera, filename: filename, handle: 0x1001, storageID: 0x0001_0001,
            sizeBytes: 5_000_000, captureDate: "20261025T111844")
        clip.exifOrientation = orientation
        return clip
    }

    @Test func aStillsOldThumbnailIsFetchedAgainOnceAndOthersAreKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let portrait = Self.row("_NZR2887.JPG")
        let raw = Self.row("_NZR1697.NEF")
        let learned = Self.row("_NZR2811.JPG", orientation: 8)
        let clip = Self.row("C0001.MOV")
        store.upsertBatch([portrait, raw, learned, clip], cameraID: Self.camera)
        let local = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "IMG_0001.JPG", handle: nil,
            storageID: nil, sizeBytes: 4, captureDate: "20261025T111844")
        store.upsertBatch([local], cameraID: local.cameraID)
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xD9])
        for row in [portrait, raw, learned, clip, local] {
            try store.saveThumbnail(cameraID: row.cameraID, filename: row.filename, data: thumbnail)
        }

        store.retireUnorientedStillThumbnails()

        #expect(!store.hasThumbnail(cameraID: Self.camera, filename: portrait.filename))
        #expect(!store.hasThumbnail(cameraID: Self.camera, filename: raw.filename))
        // A row that learned its orientation still turns its old thumbnail upright.
        #expect(store.hasThumbnail(cameraID: Self.camera, filename: learned.filename))
        // A clip's thumbnail has no orientation to gain; a local photo has no camera to ask.
        #expect(store.hasThumbnail(cameraID: Self.camera, filename: clip.filename))
        #expect(store.hasThumbnail(cameraID: local.cameraID, filename: local.filename))

        // Thumbnails fetched afterwards carry the orientation and are never retired again.
        try store.saveThumbnail(cameraID: Self.camera, filename: portrait.filename, data: thumbnail)
        store.retireUnorientedStillThumbnails()
        #expect(store.hasThumbnail(cameraID: Self.camera, filename: portrait.filename))
    }

    @Test func aLibraryWhoseIndexCannotBeReadIsRetiredOnceItCanBe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let portrait = Self.row("_NZR2887.JPG")
        MediaClipStore(root: root).upsertBatch([portrait], cameraID: Self.camera)
        try MediaClipStore(root: root).saveThumbnail(
            cameraID: Self.camera, filename: portrait.filename,
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let index = root.appendingPathComponent(Self.camera).appendingPathComponent("index.json")
        let readable = try Data(contentsOf: index)
        try Data("{ not an index".utf8).write(to: index)

        // Which cached thumbnails belong to stills is unknown, so nothing is decided yet.
        MediaClipStore(root: root).retireUnorientedStillThumbnails()
        #expect(
            MediaClipStore(root: root).hasThumbnail(
                cameraID: Self.camera, filename: portrait.filename))

        try readable.write(to: index)
        MediaClipStore(root: root).retireUnorientedStillThumbnails()
        #expect(
            !MediaClipStore(root: root).hasThumbnail(
                cameraID: Self.camera, filename: portrait.filename))
    }
}
