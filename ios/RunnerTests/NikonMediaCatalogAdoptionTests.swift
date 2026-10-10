import Foundation
import OpenCineCore
import OpenCineMedia
import OpenZCineCore
import XCTest

@testable import Runner

@MainActor final class NikonMediaCatalogAdoptionTests: XCTestCase {
    func testActualPersistenceKeepsFailedCardBackupFlagsAndExactCachedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var clip = sample()
        let first = MediaObjectHandle(storageID: 65_537, handle: 4)
        let second = MediaObjectHandle(storageID: 131_073, handle: 4)
        clip.storageLocations = [first, second]
        store.upsertBatch([clip], cameraID: "SIMULATED")
        let local = try store.localURL(cameraID: "SIMULATED", filename: clip.filename)
        try Data("keep".utf8).write(to: local)
        let io = CatalogIO()
        io.snapshot = .init(
            handles: [], authoritativeStorages: [65_537], failedStorages: [131_073],
            storageListAuthoritative: true)
        let service = NikonMediaService(session: io.session, io: io)
        service.configure(
            .init(
                cached: NikonMediaCatalogAdapter.records([clip]), category: .all,
                identityProbeBudget: 0))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let deltaValue = try await cursor.next()
        let delta = try XCTUnwrap(deltaValue)
        let values = try NikonMediaCatalogAdapter.apply(
            delta, service: service, binding: browse.binding,
            bucket: "SIMULATED", store: store, current: [clip], isDownloaded: { _ in true },
            admit: { true })
        XCTAssertFalse(delta.complete)
        XCTAssertEqual(values.first?.allLocations, [second])
        let stored = try XCTUnwrap(store.list(cameraID: "SIMULATED").first)
        XCTAssertEqual(stored.allLocations, [second])
        assertFlags(stored)
        XCTAssertEqual(try Data(contentsOf: local), Data("keep".utf8))
        XCTAssertNil(service.coveredCategory)
        cursor.close()
        await browse.close()
    }

    func testKnownSizeReplacementPreservesDownloadedSurvivorAndLegacyIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let old = sample()
        store.upsertBatch([old], cameraID: "SIMULATED")
        let local = try store.localURL(cameraID: "SIMULATED", filename: old.filename)
        try Data("keep".utf8).write(to: local)
        let io = CatalogIO()
        let location = try XCTUnwrap(old.allLocations.first)
        io.snapshot = .init(
            handles: [location], authoritativeStorages: [65_537], storageListAuthoritative: true)
        var new = try XCTUnwrap(NikonMediaCatalogAdapter.records([old]).first)
        new = .init(
            location: new.location, filename: new.filename, captureDate: new.captureDate,
            sizeBytes: 8)
        io.objects[location] = new
        let service = NikonMediaService(session: io.session, io: io)
        service.configure(.init(cached: NikonMediaCatalogAdapter.records([old]), category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let tombstoneValue = try await cursor.next()
        let tombstone = try XCTUnwrap(tombstoneValue)
        let kept = try NikonMediaCatalogAdapter.apply(
            tombstone, service: service, binding: browse.binding,
            bucket: "SIMULATED", store: store, current: [old], isDownloaded: { _ in true },
            admit: { true })
        XCTAssertEqual(kept.first?.id, old.id)
        XCTAssertNil(kept.first?.handle)
        assertFlags(try XCTUnwrap(kept.first))
        let replacementValue = try await cursor.next()
        let replacement = try XCTUnwrap(replacementValue)
        let merged = try NikonMediaCatalogAdapter.apply(
            replacement, service: service, binding: browse.binding,
            bucket: "SIMULATED", store: store, current: kept, isDownloaded: { _ in true },
            admit: { true }
        )
        XCTAssertNotEqual(replacement.upserts.first?.id, tombstone.removed.first)
        XCTAssertEqual(merged.first?.id, old.id)
        XCTAssertEqual(merged.first?.sizeBytes, 8)
        assertFlags(try XCTUnwrap(store.list(cameraID: "SIMULATED").first))
        XCTAssertEqual(try Data(contentsOf: local), Data("keep".utf8))
        XCTAssertEqual(try store.localURL(cameraID: "SIMULATED", filename: old.filename), local)
        cursor.close()
        await browse.close()
    }

    func testOldContentTombstoneCannotEraseNewIndexLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let old = sample()
        store.upsertBatch([old], cameraID: "SIMULATED")
        let io = CatalogIO()
        io.snapshot = .init(
            handles: [], authoritativeStorages: [65_537], storageListAuthoritative: true)
        let service = NikonMediaService(session: io.session, io: io)
        service.configure(.init(cached: NikonMediaCatalogAdapter.records([old]), category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let oldDeltaValue = try await cursor.next()
        let oldDelta = try XCTUnwrap(oldDeltaValue)
        store.update(cameraID: "SIMULATED", filename: old.filename) {
            $0.captureDate = "20261005T120000"
        }
        let current = store.list(cameraID: "SIMULATED")
        let before = try disk(root)
        let accepted = try NikonMediaCatalogAdapter.apply(
            oldDelta, service: service, binding: browse.binding,
            bucket: "SIMULATED", store: store, current: current, isDownloaded: { _ in false },
            admit: { true })
        XCTAssertEqual(accepted.first?.captureDate, "20261005T120000")
        XCTAssertEqual(try disk(root), before)
        cursor.close()
        await browse.close()
    }

    func testRetiredEpochCannotWriteTheActualLegacyStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let old = sample()
        store.upsertBatch([old], cameraID: "SIMULATED")
        let io = CatalogIO()
        let location = try XCTUnwrap(old.allLocations.first)
        io.snapshot = .init(
            handles: [location], authoritativeStorages: [65_537], storageListAuthoritative: true)
        io.objects[location] = NikonMediaCatalogAdapter.records([old]).first
        let service = NikonMediaService(session: io.session, io: io)
        service.configure(.init(cached: [], category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let deltaValue = try await cursor.next()
        let delta = try XCTUnwrap(deltaValue)
        let before = try disk(root)
        io.epoch = io.epoch.next()
        do {
            _ = try NikonMediaCatalogAdapter.apply(
                delta, service: service, binding: browse.binding,
                bucket: "SIMULATED", store: store, current: [old], isDownloaded: { _ in true },
                admit: { true })
            XCTFail("Retired result wrote the legacy store")
        } catch { XCTAssertEqual(error as? MediaServiceError, .retired) }
        XCTAssertEqual(try disk(root), before)
        XCTAssertEqual(store.list(cameraID: "SIMULATED"), [old])
        cursor.close()
        await browse.close()
    }

    func testDownloadedLocationlessMasterSeedsNewCameraProxyWithoutChangingLocalBytesOrFlags()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var master = sample()
        master.filename = "A.R3D"
        master.handle = nil
        master.storageID = nil
        master.pixelWidth = 6048
        master.pixelHeight = 3402
        store.upsertBatch([master], cameraID: "SIMULATED")
        let local = try store.localURL(cameraID: "SIMULATED", filename: master.filename)
        try Data("keep".utf8).write(to: local)
        let cached = store.list(cameraID: "SIMULATED")
        XCTAssertTrue(NikonMediaCatalogAdapter.records(cached).isEmpty)
        let io = CatalogIO()
        let location = MediaObjectHandle(storageID: 65_537, handle: 9)
        io.objects[location] = .init(
            location: location, filename: "A.MOV", captureDate: "20261004T120000", sizeBytes: 8)
        io.snapshot = .init(
            handles: [location], authoritativeStorages: [65_537], storageListAuthoritative: true)
        let service = NikonMediaService(session: io.session, io: io)
        service.configure(
            .init(
                cached: NikonMediaCatalogAdapter.records(cached),
                pairing: NikonMediaCatalogAdapter.pairingRecords(cached), category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let value = try await cursor.next()
        let delta = try XCTUnwrap(value)
        let values = try NikonMediaCatalogAdapter.apply(
            delta, service: service, binding: browse.binding,
            bucket: "SIMULATED", store: store, current: cached, isDownloaded: { _ in true },
            admit: { true })
        let proxy = try XCTUnwrap(values.first { $0.filename == "A.MOV" })
        XCTAssertEqual(proxy.sourcePixelWidth, 6048)
        XCTAssertEqual(proxy.sourcePixelHeight, 3402)
        XCTAssertEqual(proxy.linkedR3DFilename, "A.R3D")
        XCTAssertEqual(proxy.allLocations, [location])
        XCTAssertEqual(store.list(cameraID: "SIMULATED").first { $0.filename == "A.MOV" }, proxy)
        let kept = try XCTUnwrap(store.list(cameraID: "SIMULATED").first { $0.filename == "A.R3D" })
        XCTAssertEqual(kept, master)
        XCTAssertTrue(kept.allLocations.isEmpty)
        assertFlags(kept)
        XCTAssertEqual(try Data(contentsOf: local), Data("keep".utf8))
        cursor.close()
        await browse.close()
    }

    func testNewCameraMasterHeaderBackfillsDownloadedLocationlessProxyInStoreAndCurrentGrid()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var proxy = sample()
        proxy.filename = "A.MOV"
        proxy.handle = nil
        proxy.storageID = nil
        store.upsertBatch([proxy], cameraID: "SIMULATED")
        let local = try store.localURL(cameraID: "SIMULATED", filename: proxy.filename)
        try Data("keep".utf8).write(to: local)
        let cached = store.list(cameraID: "SIMULATED")
        XCTAssertTrue(NikonMediaCatalogAdapter.records(cached).isEmpty)
        let io = CatalogIO()
        let location = MediaObjectHandle(storageID: 65_537, handle: 8)
        io.objects[location] = .init(
            location: location, filename: "A.R3D", captureDate: "20261004T120000", sizeBytes: 8)
        io.snapshot = .init(
            handles: [location], authoritativeStorages: [65_537], storageListAuthoritative: true)
        var header = [UInt8](repeating: 0, count: 60)
        header.replaceSubrange(4..<8, with: [0x52, 0x45, 0x44, 0x31])
        header.replaceSubrange(52..<56, with: [0, 0, 0x17, 0xA0])
        header.replaceSubrange(56..<60, with: [0, 0, 0x0D, 0x4A])
        io.headers[location] = Data(header)
        let service = NikonMediaService(session: io.session, io: io)
        service.configure(
            .init(
                cached: NikonMediaCatalogAdapter.records(cached),
                pairing: NikonMediaCatalogAdapter.pairingRecords(cached), category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let value = try await cursor.next()
        let delta = try XCTUnwrap(value)
        XCTAssertEqual(delta.upserts.map(\.filename), ["A.R3D"])
        let values = try NikonMediaCatalogAdapter.apply(
            delta, service: service, binding: browse.binding,
            bucket: "SIMULATED", store: store, current: cached, isDownloaded: { _ in true },
            admit: { true })
        let updated = try XCTUnwrap(values.first { $0.filename == "A.MOV" })
        XCTAssertEqual(updated.sourcePixelWidth, 6048)
        XCTAssertEqual(updated.sourcePixelHeight, 3402)
        XCTAssertEqual(updated.linkedR3DFilename, "A.R3D")
        XCTAssertNil(updated.handle)
        XCTAssertNil(updated.storageID)
        XCTAssertTrue(updated.allLocations.isEmpty)
        XCTAssertEqual(updated.id, proxy.id)
        XCTAssertEqual(updated.sizeBytes, proxy.sizeBytes)
        assertFlags(updated)
        XCTAssertEqual(store.list(cameraID: "SIMULATED").first { $0.filename == "A.MOV" }, updated)
        XCTAssertEqual(try Data(contentsOf: local), Data("keep".utf8))
        // Captured metadata actions cannot write after the exact browse is retired.
        io.epoch = io.epoch.next()
        let before = try disk(root)
        do {
            _ = try NikonMediaCatalogAdapter.apply(
                delta, service: service, binding: browse.binding,
                bucket: "SIMULATED", store: store, current: values, isDownloaded: { _ in true },
                admit: { true })
            XCTFail("Retired pairing action wrote the actual store")
        } catch { XCTAssertEqual(error as? MediaServiceError, .retired) }
        XCTAssertEqual(try disk(root), before)
        cursor.close()
        await browse.close()
    }

    private func sample() -> MediaClip {
        var clip = MediaClip(
            cameraID: "SIMULATED", filename: "Göteborg.MOV", handle: 4,
            storageID: 65_537, sizeBytes: 4, captureDate: "20261004T120000")
        clip.isFavorite = true
        clip.starRating = 4
        clip.frameioStatus = .uploaded
        clip.frameioFileID = "SIMULATED-frameio-id"
        clip.exportStatus = .exported
        return clip
    }
    private func assertFlags(_ clip: MediaClip) {
        XCTAssertTrue(clip.isFavorite)
        XCTAssertEqual(clip.starRating, 4)
        XCTAssertEqual(clip.frameioStatus, .uploaded)
        XCTAssertEqual(clip.frameioFileID, "SIMULATED-frameio-id")
        XCTAssertEqual(clip.exportStatus, .exported)
    }
    private func disk(_ root: URL) throws -> [String: Data] {
        let iterator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in iterator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.path] = try Data(contentsOf: url)
            }
        }
        return result
    }
}

@MainActor private final class CatalogIO: NikonMediaIO {
    let session = CameraSessionID()
    let native = NSObject()
    var epoch = ControlEpoch(1)
    let cameraNamespace = "SIMULATED"
    var sourceIdentity: NikonMediaSourceIdentity? {
        .init(native: ObjectIdentifier(native), session: session, epoch: epoch)
    }
    var snapshot = NikonMediaHandleSnapshot(
        handles: [], authoritativeStorages: [], storageListAuthoritative: true)
    var objects: [MediaObjectHandle: NikonMediaObjectRecord] = [:]
    var headers: [MediaObjectHandle: Data] = [:]
    func storage(source _: NikonMediaSourceIdentity) async throws -> [NikonMediaStorageRecord] {
        []
    }
    func handles(source _: NikonMediaSourceIdentity) async throws -> NikonMediaHandleSnapshot {
        snapshot
    }
    func handles(formats _: [UInt32], source _: NikonMediaSourceIdentity) async throws
        -> [MediaObjectHandle]
    { [] }
    func object(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> NikonMediaObjectRecord?
    { objects[location] }
    func header(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> Data?
    { headers[location] }
}
