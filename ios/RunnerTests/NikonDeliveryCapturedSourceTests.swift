import Foundation
import OpenZCineCore
import XCTest

@testable import Runner

@MainActor private final class NikonDeliverySourceFacts { var revision = 0 }

/// The first of two events, so a refused Share fails the test instead of hanging it.
@MainActor private final class NikonDeliveryFirstEvent {
    private var value: String?
    private var waiter: CheckedContinuation<String, Never>?
    func fire(_ event: String) {
        guard value == nil else { return }
        value = event
        waiter?.resume(returning: event)
        waiter = nil
    }
    func wait() async -> String {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// SIMULATED cache bytes exercise the actual delivery capture, canonical store and file checks.
@MainActor final class NikonDeliveryCapturedSourceTests: XCTestCase {
    private func fixture(_ body: (NativeAppModel, MediaClip, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-delivery-source-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clip = MediaClip(
            cameraID: "SIMULATED", filename: "original.MOV", handle: 4,
            storageID: 65_537, sizeBytes: 4, captureDate: "20261007T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let url = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: url)
        try body(NativeAppModel(mediaClipStore: store), clip, url)
    }
    /// Owner hardware report 2026-10-28: open a clip so the player starts caching it, leave the
    /// player before the cache finishes, then Share that clip. Share failed with "couldn't cache"
    /// every time; the delivery's original service must finish the clip from the camera, resuming
    /// the player's partial bytes.
    func testShareFinishesTheCacheThePlayerLeftUnfinished() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-delivery-resume-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clip = MediaClip(
            cameraID: "SIMULATED", filename: "PLAYER.MOV", handle: 7,
            storageID: 65_537, sizeBytes: 4, captureDate: "20261028T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        // SIMULATED camera: two bytes per read, each read held until the test releases it. The
        // second chunk is read twice: once by the cancelled player stream, once by Share.
        let camera = LargeTransferTransport(
            operations: [.getPartialObject],
            chunks: [Data([1, 2]), Data([3, 4]), Data([3, 4])], holdRead: true)
        let session = try await NativeCameraSession.establish(
            transport: camera, host: "usb:SIMULATED-share", cameraName: "SIMULATED",
            requestPairing: false)
        defer { session.close() }
        await camera.clear()
        let model = NativeAppModel(mediaClipStore: store)
        model.debugAdoptEstablishedMediaSession(session)
        model.connection = .connected
        defer {
            model.connection = .disconnected
            model.debugAdoptEstablishedMediaSession(nil)
        }
        model.prepareMediaLibrary(rows: [clip], bucket: clip.cameraID, service: nil)
        let url = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)

        let player = try XCTUnwrap(model.startClipStream(clip))
        await camera.waitUntilReads(1)
        await camera.release()
        await camera.waitUntilReads(2)
        model.cancelClipStream(player)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2]))

        let capture = try XCTUnwrap(NikonMediaDeliveryCapture(model: model, clips: [clip]))
        XCTAssertFalse(capture.originals.available(clip))
        let first = NikonDeliveryFirstEvent()
        let share = Task {
            await capture.originals.acquire(clip)
            first.fire("share ended")
        }
        await camera.release()
        await player.task.value
        Task {
            await camera.waitUntilReads(3)
            first.fire("camera read")
        }
        let event = await first.wait()
        guard event == "camera read" else {
            return XCTFail("Share ended without reading the rest of the clip from the camera")
        }
        await camera.release()
        await share.value

        XCTAssertTrue(capture.originals.available(clip))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
        let offsets = await camera.calls.filter { $0.operation == .getPartialObject }
            .map { $0.parameters[1] }
        XCTAssertEqual(offsets, [0, 2, 2], "Share resumes at the player's partial bytes")
    }

    func testCapturedCanonicalReplacementCannotBorrowTheSuccessorRecord() throws {
        try fixture { model, clip, url in
            let capture = try XCTUnwrap(NikonMediaDeliveryCapture(model: model, clips: [clip]))
            XCTAssertTrue(capture.isCurrent)
            XCTAssertTrue(capture.isCached(clip))
            model.mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
                $0.sizeBytes = 12
                $0.captureDate = "20261008T120000"
            }
            XCTAssertFalse(capture.isCurrent)
            capture.update(clip) { $0.frameioStatus = .uploaded }
            XCTAssertEqual(model.mediaClipStore.list(cameraID: clip.cameraID).first?.sizeBytes, 12)
            XCTAssertNotEqual(
                model.mediaClipStore.list(cameraID: clip.cameraID).first?.frameioStatus, .uploaded)
            XCTAssertEqual(capture.localURL(clip), url)
        }
    }
    func testExpiredNativeClaimCannotUseCanonicalFilesWithoutItsOwnedRoute() throws {
        try fixture { model, clip, _ in
            let facts = NikonDeliverySourceFacts()
            let action = NikonMediaLibraryAction(
                owner: nil, store: model.mediaClipStore,
                codec: NikonMediaLibraryCodec(
                    store: model.mediaClipStore, bucket: clip.cameraID,
                    service: nil, downloaded: { _ in true }),
                bytes: nil, clips: [clip], canonicalCurrent: { true },
                admitted: { facts.revision == 0 })
            let capture = try XCTUnwrap(
                NikonMediaDeliveryCapture(model: model, clips: [clip], action: action))
            XCTAssertTrue(capture.isCurrent)
            facts.revision = 1
            XCTAssertTrue(action.contentIsCurrent)
            XCTAssertFalse(action.sourceIsCurrent)
            XCTAssertFalse(capture.isCurrent)
            facts.revision = 2
            XCTAssertFalse(capture.isCurrent)
        }
    }
    func testActualCachedFactRejectsTruncationEmptyFileAndSymlink() throws {
        try fixture { model, clip, url in
            let capture = try XCTUnwrap(NikonMediaDeliveryCapture(model: model, clips: [clip]))
            XCTAssertTrue(capture.isCached(clip))
            try Data([1, 2, 3]).write(to: url)
            XCTAssertFalse(capture.isCached(clip))
            try Data().write(to: url)
            XCTAssertFalse(capture.isCached(clip))
            let borrowed = url.deletingLastPathComponent().appendingPathComponent("borrowed.MOV")
            try Data([1, 2, 3, 4]).write(to: borrowed)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: borrowed)
            XCTAssertFalse(capture.isCached(clip))
            XCTAssertEqual(try Data(contentsOf: borrowed), Data([1, 2, 3, 4]))
        }
    }
    func testDuplicateSelectedIDRetainsOriginalContentAndSelectionOrder() throws {
        try fixture { model, clip, url in
            let capture = try XCTUnwrap(
                NikonMediaDeliveryCapture(model: model, clips: [clip, clip]))
            XCTAssertEqual(capture.clips.map(\.id), [clip.id, clip.id])
            XCTAssertEqual(capture.localURL(clip), url)
            XCTAssertTrue(capture.isCached(clip))
            XCTAssertTrue(capture.isCurrent)
        }
    }
}
