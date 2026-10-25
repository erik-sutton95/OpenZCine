import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import OpenZCineCore
import Testing

@testable import Runner

/// SIMULATED large Nikon card: 1,500 RAW+JPEG pairs (3,000 stills) and 200 clips on one slot.
/// Owner report 2026-10-25 (build 304, Nikon ZR over Wi-Fi): the Media page stalled for long
/// periods with a card this size. Each test drives the real app adapter over the shared library
/// owner and bounds the whole-catalog work an operation may do, so a cost that grows with the
/// card per page, per clip or per render fails here. Wall-clock budgets are generous ceilings
/// (several times the measured fixed value); the operation counts are the exact contract.
@Suite("Large card media performance (SIMULATED)", .serialized)
@MainActor struct MediaLargeCardPerformanceTests {
    static let pairs = 1_500
    static let movies = 200
    static var total: Int { pairs * 2 + movies }
    static let bucket = "SIMULATED"
    static let storage: UInt32 = 65_537

    /// One realistic card, newest handle last, as a ZR lists it.
    static func cardObjects() -> [NikonMediaObjectRecord] {
        var objects: [NikonMediaObjectRecord] = []
        var handle: UInt32 = 0x1000
        func add(_ name: String, size: UInt64, index: Int, width: UInt32?, height: UInt32?) {
            handle += 1
            let second = index % 60
            let minute = (index / 60) % 60
            let hour = 8 + index / 3_600
            objects.append(
                .init(
                    location: .init(storageID: storage, handle: handle), filename: name,
                    captureDate: String(
                        format: "20261024T%02d%02d%02d", hour, minute, second),
                    sizeBytes: size, pixelWidth: width, pixelHeight: height))
        }
        for index in 1...pairs {
            let stem = String(format: "DSC_%04d", index)
            add(stem + ".NEF", size: 28_400_000, index: index, width: 6_048, height: 4_032)
            add(stem + ".JPG", size: 9_800_000, index: index, width: 6_048, height: 4_032)
        }
        for index in 1...movies {
            let number = pairs + index
            let name = String(format: "DSC_%04d", number) + (index % 2 == 0 ? ".MOV" : ".MP4")
            add(name, size: 1_200_000_000, index: number, width: 3_840, height: 2_160)
        }
        return objects
    }

    static func clips() -> [MediaClip] {
        cardObjects().map { NikonMediaCatalogAdapter.clip($0, bucket: bucket) }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "opz-large-card-" + UUID().uuidString)
    }

    private func measure<T>(_ work: () async throws -> T) async rethrows -> (T, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await work()
        return (value, clock.now - start)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    /// Lists the whole card through the real service, codec, byte store and library owner.
    private func listCard(cached: [MediaClip]) async throws -> (
        counts: MediaPerformanceProbe.Scope, elapsed: Duration, records: Int
    ) {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        if !cached.isEmpty { store.upsertBatch(cached, cameraID: Self.bucket) }
        let objects = Self.cardObjects()
        let io = LargeCardIO(objects: objects)
        let service = NikonMediaService(session: io.session, io: io)
        let model = NativeAppModel(mediaClipStore: store)
        let rows = store.list(cameraID: Self.bucket)
        service.configure(
            .init(
                cached: NikonMediaCatalogAdapter.records(rows),
                pairing: NikonMediaCatalogAdapter.pairingRecords(rows), category: .all))
        let scope = MediaPerformanceProbe.Scope()
        let (count, elapsed) = try await MediaPerformanceProbe.$scope.withValue(scope) {
            try await measure {
                model.prepareMediaLibrary(rows: rows, bucket: Self.bucket, service: service)
                let owner = try #require(model.mediaLibrary)
                owner.begin()
                let deadline = ContinuousClock.now + .seconds(600)
                while ContinuousClock.now < deadline {
                    if owner.browsing, !owner.fetching, owner.records.count == Self.total,
                        owner.catalogPageCount > 0
                    {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                return owner.records.count
            }
        }
        // The published rows are the persisted canonical index, row for row. Published rows keep
        // the exact captured camera locations (a single card copy stays the primary pair), so
        // locations compare through `allLocations`.
        func normalized(_ clip: MediaClip) -> MediaClip {
            var value = clip
            value.storageLocations = clip.allLocations
            return value
        }
        let published = Dictionary(
            (model.mediaLibrary?.records ?? []).map {
                ($0.payload.filename, normalized($0.payload))
            },
            uniquingKeysWith: { first, _ in first })
        let persisted = Dictionary(
            store.list(cameraID: Self.bucket).map { ($0.filename, normalized($0)) },
            uniquingKeysWith: { first, _ in first })
        #expect(published == persisted)
        #expect(Set(published.keys) == Set(objects.map(\.filename)))
        await model.mediaLibrary?.dispose()
        #expect(count == Self.total)
        return (scope, elapsed, count)
    }

    /// First visit to a full card: every object is new.
    @Test func firstListingOfAFullCardCostsPerObjectNotPerPage() async throws {
        let result = try await listCard(cached: [])
        let mapped = result.counts[.recordMapping]
        let decoded = result.counts[.indexDecode]
        let listed = result.counts[.directoryListing]
        print(
            "PERF first-listing objects=\(Self.total) ms=\(milliseconds(result.elapsed)) recordMappings=\(mapped) indexDecodes=\(decoded) directoryListings=\(listed) captureMs=\(result.counts[.captureMicros] / 1_000) prepareMs=\(result.counts[.prepareMicros] / 1_000) persistMs=\(result.counts[.persistMicros] / 1_000)"
        )
        #expect(
            mapped <= Self.total + 100, "record() ran \(mapped) times for \(Self.total) objects")
        #expect(decoded <= 8, "the index was decoded \(decoded) times in one listing")
        #expect(listed <= 8, "the bucket was listed \(listed) times in one listing")
        #expect(result.elapsed < .seconds(20), "listing took \(result.elapsed)")
    }

    /// Reconnect to the same card: every object is already indexed.
    @Test func relistingAnIndexedCardCostsPerObjectNotPerPage() async throws {
        // As persisted by an earlier visit: every row carries its card locations.
        let indexed = Self.clips().map {
            MediaClipStore.mergeCameraDiscovery(existing: $0, incoming: $0)
        }
        let result = try await listCard(cached: indexed)
        let mapped = result.counts[.recordMapping]
        let decoded = result.counts[.indexDecode]
        let listed = result.counts[.directoryListing]
        print(
            "PERF relisting objects=\(Self.total) ms=\(milliseconds(result.elapsed)) recordMappings=\(mapped) indexDecodes=\(decoded) directoryListings=\(listed) captureMs=\(result.counts[.captureMicros] / 1_000) prepareMs=\(result.counts[.prepareMicros] / 1_000) persistMs=\(result.counts[.persistMicros] / 1_000)"
        )
        #expect(
            mapped <= Self.total + 100, "record() ran \(mapped) times for \(Self.total) objects")
        #expect(decoded <= 8, "the index was decoded \(decoded) times in one listing")
        #expect(listed <= 8, "the bucket was listed \(listed) times in one listing")
        #expect(result.elapsed < .seconds(20), "relisting took \(result.elapsed)")
    }

    /// Select 500 stills and share them while the gallery stays open: the captured action reads
    /// the canonical index once per bucket, not once per clip, and so does its currency check.
    @Test func capturingAnActionForManyClipsReadsTheIndexOncePerCheck() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clips = Self.clips()
        store.upsertBatch(clips, cameraID: Self.bucket)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        model.prepareMediaLibrary(
            rows: store.list(cameraID: Self.bucket), bucket: Self.bucket, service: nil)
        let selected = Array(clips.prefix(500))
        let scope = MediaPerformanceProbe.Scope()
        let ((current, mutable), elapsed) = await MediaPerformanceProbe.$scope.withValue(scope) {
            await measure {
                let action = model.captureMediaLibraryAction(selected)
                let current = action?.isCurrent ?? false
                let mutable = selected.prefix(20).allSatisfy { action?.canMutate($0) == true }
                return (current, mutable)
            }
        }
        let decoded = scope[.indexDecode]
        let listed = scope[.directoryListing]
        print(
            "PERF action-capture clips=\(selected.count) ms=\(milliseconds(elapsed)) indexDecodes=\(decoded) directoryListings=\(listed)"
        )
        #expect(current)
        #expect(mutable)
        #expect(decoded <= 4, "the index was decoded \(decoded) times for one action")
        #expect(listed <= 25, "the bucket was listed \(listed) times for one action")
        #expect(elapsed < .seconds(3), "capturing took \(elapsed)")
        await model.mediaLibrary?.dispose()
    }

    /// Playback asks its captured action whether it is current on every screen update (build 304
    /// CPU report: 16 of 23 main-thread samples). An unchanged index answers without any read; a
    /// changed index is read again and still decides correctly.
    @Test func repeatedCurrencyChecksOfAnUnchangedIndexReadNothing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clips = Self.clips()
        store.upsertBatch(clips, cameraID: Self.bucket)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        model.prepareMediaLibrary(
            rows: store.list(cameraID: Self.bucket), bucket: Self.bucket, service: nil)
        let playing = try #require(clips.last)
        let action = try #require(model.captureMediaLibraryAction([playing]))
        #expect(action.isCurrent)
        let scope = MediaPerformanceProbe.Scope()
        let (allCurrent, elapsed) = await MediaPerformanceProbe.$scope.withValue(scope) {
            await measure {
                (0..<200).allSatisfy { _ in action.isCurrent && action.contentIsCurrent }
            }
        }
        print(
            "PERF currency-checks checks=200 ms=\(milliseconds(elapsed)) indexDecodes=\(scope[.indexDecode]) directoryListings=\(scope[.directoryListing])"
        )
        #expect(allCurrent)
        #expect(scope[.indexDecode] == 0)
        #expect(scope[.directoryListing] == 0)
        #expect(elapsed < .seconds(1), "200 checks took \(elapsed)")
        // A replacement of the captured content is still seen.
        store.update(cameraID: Self.bucket, filename: playing.filename) {
            $0.sizeBytes += 1
        }
        #expect(!action.isCurrent)
        await model.mediaLibrary?.dispose()
    }

    /// What one render of every cell costs in app file facts (the shared catalog used to build
    /// every cell per render; it should build only visible ones). Measured, not asserted here.
    @Test func measureCellFactsForTheWholeCard() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clips = Self.clips()
        store.upsertBatch(clips, cameraID: Self.bucket)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        model.prepareMediaLibrary(
            rows: store.list(cameraID: Self.bucket), bucket: Self.bucket, service: nil)
        let projection = model.mediaGalleryProjection
        let clock = ContinuousClock()
        let start = clock.now
        var items = 0
        for clip in clips {
            _ = model.mediaCellItem(
                clip, list: false, selecting: false, duration: nil, projection: projection)
            _ = model.isClipDownloaded(clip)
            _ = model.clipThumbnailURL(clip)
            items += 1
        }
        let all = clock.now - start
        let visibleStart = clock.now
        for clip in clips.prefix(40) {
            _ = model.mediaCellItem(
                clip, list: false, selecting: false, duration: nil, projection: projection)
            _ = model.isClipDownloaded(clip)
            _ = model.clipThumbnailURL(clip)
        }
        let visible = clock.now - visibleStart
        print(
            "PERF cell-facts all=\(items) allMs=\(milliseconds(all)) visible=40 visibleMs=\(milliseconds(visible))"
        )
        #expect(items == Self.total)
        await model.mediaLibrary?.dispose()
    }

    /// The index memo never hides a change: another store's write, a new disk file, a growing
    /// unindexed file and the encoded-bytes shortcut all match a fresh read.
    @Test func indexMemoAlwaysMatchesAFreshRead() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clips = Array(Self.clips().prefix(6))
        store.upsertBatch(clips, cameraID: Self.bucket)
        #expect(store.list(cameraID: Self.bucket).count == 6)
        let other = MediaClipStore(root: root)
        let bytes = try MediaClipStore.encodeCatalogBytes(Array(clips.prefix(2)))
        try other.writeCatalogBytes(bytes, cameraID: Self.bucket, ifCurrent: { true })
        #expect(
            store.list(cameraID: Self.bucket).map(\.filename)
                == clips.prefix(2).map(\.filename).sorted())
        let loose = store.directory(for: Self.bucket).appendingPathComponent("LOOSE_0001.MOV")
        try Data(count: 4).write(to: loose)
        #expect(
            store.list(cameraID: Self.bucket).first { $0.filename == "LOOSE_0001.MOV" }?.sizeBytes
                == 4)
        let handle = try FileHandle(forWritingTo: loose)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 6))
        try handle.close()
        #expect(
            store.list(cameraID: Self.bucket).first { $0.filename == "LOOSE_0001.MOV" }?.sizeBytes
                == 10)
        let all = Self.clips()
        let encoded = try MediaClipStore.encodeCatalogBytes(all)
        let fresh = try JSONDecoder().decode([MediaClip].self, from: encoded)
        #expect(try MediaClipStore.decodeCatalogBytes(encoded) == fresh)
    }

    /// Every gallery body reads the projection; reading it again without a change reuses it.
    @Test func unchangedGalleryReusesItsProjectionPass() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch(Self.clips(), cameraID: Self.bucket)
        let model = NativeAppModel(mediaClipStore: store)
        // The connected camera gallery: every card row is shown, not only cached ones.
        model.connection = .connected
        model.mediaCategoryTab = .all
        model.prepareMediaLibrary(
            rows: store.list(cameraID: Self.bucket), bucket: Self.bucket, service: nil)
        let scope = MediaPerformanceProbe.Scope()
        let (gridCount, elapsed) = MediaPerformanceProbe.$scope.withValue(scope) {
            let clock = ContinuousClock()
            let start = clock.now
            var count = 0
            for _ in 0..<10 {
                let pass = model.mediaGalleryProjection
                _ = model.mediaGalleryPresentation(pass)
                count = pass.result.gridIDs.count
            }
            return (count, clock.now - start)
        }
        let passes = scope[.projectionPass]
        print(
            "PERF projection reads=10 clips=\(Self.total) ms=\(milliseconds(elapsed)) projectionPasses=\(passes)"
        )
        #expect(gridCount > 0)
        #expect(passes <= 1, "ten unchanged reads built \(passes) projection passes")
        // A change still produces a fresh pass.
        model.mediaSortOrder = model.mediaSortOrder == .name ? .newest : .name
        let changed = MediaPerformanceProbe.$scope.withValue(scope) {
            model.mediaGalleryProjection.result.gridIDs
        }
        #expect(scope[.projectionPass] == passes + 1)
        #expect(changed.count == gridCount)
        await model.mediaLibrary?.dispose()
    }
}

/// SIMULATED card source: object facts only, no camera IO.
@MainActor private final class LargeCardIO: NikonMediaIO {
    let session = CameraSessionID()
    let native = NSObject()
    let cameraNamespace = MediaLargeCardPerformanceTests.bucket
    let objects: [MediaObjectHandle: NikonMediaObjectRecord]
    let handleList: [MediaObjectHandle]
    init(objects: [NikonMediaObjectRecord]) {
        self.objects = Dictionary(uniqueKeysWithValues: objects.map { ($0.location, $0) })
        handleList = objects.map(\.location)
    }
    var sourceIdentity: NikonMediaSourceIdentity? {
        .init(native: ObjectIdentifier(native), session: session, epoch: ControlEpoch(1))
    }
    func storage(source _: NikonMediaSourceIdentity) async throws -> [NikonMediaStorageRecord] {
        []
    }
    func handles(source _: NikonMediaSourceIdentity) async throws -> NikonMediaHandleSnapshot {
        .init(
            handles: handleList, authoritativeStorages: [MediaLargeCardPerformanceTests.storage],
            storageListAuthoritative: true)
    }
    func handles(formats _: [UInt32], source _: NikonMediaSourceIdentity) async throws
        -> [MediaObjectHandle]
    { handleList }
    func object(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> NikonMediaObjectRecord?
    { objects[location] }
    func header(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> Data?
    { nil }
}
