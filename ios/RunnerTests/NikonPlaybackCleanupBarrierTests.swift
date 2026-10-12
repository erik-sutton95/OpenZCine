import AVFoundation
import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineMedia
import XCTest

@testable import Runner

/// SIMULATED files and manual entered-operation gates exercise the actual native adapter.
/// Four-byte cache files prove attachment ordering, not decoded picture or hardware behavior.
@MainActor final class NikonPlaybackCleanupBarrierTests: XCTestCase {
    private let exports = MonitorDeliveryExportStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-barrier-exports-\(UUID().uuidString)", isDirectory: true))
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Captured cleanup did not reach its manual boundary")
    }
    private func caching(_ caching: Bool) -> MonitorDeliveryBatchProgress {
        .init(
            destination: .remoteUpload, totalClips: 1, clipIndex: 1,
            clipFraction: caching ? 0.2 : 0.5, isCaching: caching)
    }

    /// A2-54: the first native item waits only while a delivery caches from the camera, and the
    /// delivery goes on beside playback.
    func testFirstNativeItemWaitsOnlyForTheCachingStageWithoutCancellingTheRun() async throws {
        let fixture = try NikonBarrierFixture()
        defer { fixture.remove() }
        let gate = NikonBarrierGate()
        let coordinator = MonitorDeliveryCoordinator(exports: exports)
        defer { coordinator.close() }
        var report: (@MainActor (MonitorDeliveryBatchProgress) -> Void)?
        coordinator.begin { _, progress in
            report = progress
            await gate.wait()
            return .savedToPhotos(count: 1)
        }
        await settle { gate.pending == 1 }
        report?(caching(true))
        var barrierEntries = 0
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(
                model: fixture.model,
                initial: fixture.opening,
                cameraTransferReleased: {
                    barrierEntries += 1
                    await coordinator.cameraTransferReleased()
                }))
        XCTAssertTrue(
            context.media.open(
                fixture.first, playlist: fixture.opening.playlist,
                admitted: fixture.opening.admission))
        await settle { barrierEntries == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(context.native?.player.currentItem, "No item while the camera transfers")
        report?(caching(false))
        await settle { context.media.playback?.ready == true }
        let asset = try XCTUnwrap(context.native?.player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.lastPathComponent, "FIRST.MOV")
        XCTAssertTrue(coordinator.isActive, "Playback never cancels the delivery")
        gate.release()
        await settle { !coordinator.isActive }
        XCTAssertEqual(coordinator.lifetime.state.toast, "Saved 1 clip to Photos")
        context.media.closePlayback()
        await fixture.library.dispose()
    }

    func testItemReplacementDuringCleanupCannotInstallTheOutgoingNativeItem() async throws {
        let fixture = try NikonBarrierFixture()
        defer { fixture.remove() }
        let gate = NikonBarrierGate()
        let native = NikonPlaybackNativePort(captureBeforePrepare: { { await gate.wait() } })
        var installed: [String] = []
        native.afterItemInstallation = {
            installed.append(($0.asset as? AVURLAsset)?.url.lastPathComponent ?? "")
        }
        let identity = UUID()
        let first = MonitorPlaybackItemToken(owner: UUID(), revision: 0)
        native.retireItem(for: .init(owner: identity, revision: 0))
        let a = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: a)
        guard
            case .cached(let oldItem) = try XCTUnwrap(
                native.candidates(for: fixture.first.payload, model: fixture.model).first)
        else {
            return XCTFail("Actual canonical cache candidate missing")
        }
        let old = Task { () -> Bool in
            do {
                _ = try await native.prepare(oldItem, token: a, readyTimeout: nil)
                return true
            } catch { return false }
        }
        await settle { gate.pending == 1 }
        native.retireItem(for: first)
        XCTAssertEqual(native.token, a, "A foreign owner cannot replace the captured item")
        let b = MonitorPlaybackItemToken(owner: identity, revision: 2)
        native.retireItem(for: b)
        guard
            case .cached(let newItem) = try XCTUnwrap(
                native.candidates(for: fixture.second.payload, model: fixture.model).first)
        else {
            return XCTFail("Actual successor cache candidate missing")
        }
        let current = Task { () -> Bool in
            do {
                _ = try await native.prepare(newItem, token: b, readyTimeout: nil)
                return true
            } catch { return false }
        }
        await settle { gate.pending == 2 }
        XCTAssertNil(native.player.currentItem)
        gate.release()
        let oldInstalled = await old.value
        let currentInstalled = await current.value
        XCTAssertFalse(oldInstalled)
        XCTAssertTrue(currentInstalled)
        XCTAssertEqual(installed, ["SECOND.MOV"])
        XCTAssertEqual(native.token, b)
        native.close(token: .init(owner: identity, revision: 3))
        await fixture.library.dispose()
    }

    /// A2-54: Back retires the item and joins only its own native work; a delivery goes on.
    func testBackRetiresSharedItemAndLeavesTheDeliveryRunning() async throws {
        let fixture = try NikonBarrierFixture()
        defer { fixture.remove() }
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: fixture.opening))
        XCTAssertTrue(
            context.media.open(
                fixture.first, playlist: fixture.opening.playlist,
                admitted: fixture.opening.admission))
        await settle { context.media.playback?.ready == true }
        let native = try XCTUnwrap(context.native)
        let gate = NikonBarrierGate()
        let coordinator = MonitorDeliveryCoordinator(exports: exports)
        defer { coordinator.close() }
        coordinator.begin { _, _ in
            await gate.wait()
            return .savedToPhotos(count: 1)
        }
        await settle { gate.pending == 1 }
        let finish = try XCTUnwrap(context.captureCloseCleanup())
        XCTAssertNil(context.media.playback)
        XCTAssertNil(native.player.currentItem)
        XCTAssertNil(context.captureCloseCleanup(), "Repeated Back cannot capture new cleanup")
        let completed = await finish()
        XCTAssertTrue(completed)
        XCTAssertTrue(coordinator.isActive, "Back never cancels the delivery")
        gate.release()
        await settle { !coordinator.isActive }
        XCTAssertEqual(coordinator.lifetime.state.toast, "Saved 1 clip to Photos")
        await fixture.library.dispose()
    }

    func testOldBackCompletionCannotDismissAReopenedPlayer() async throws {
        let fixture = try NikonBarrierFixture()
        defer { fixture.remove() }
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: fixture.opening))
        XCTAssertTrue(
            context.media.open(
                fixture.first, playlist: fixture.opening.playlist,
                admitted: fixture.opening.admission))
        await settle { context.media.playback?.ready == true }
        let oldNative = try XCTUnwrap(context.native)
        let finish = try XCTUnwrap(context.captureCloseCleanup())
        XCTAssertTrue(
            context.media.open(
                fixture.second, playlist: fixture.opening.playlist,
                admitted: fixture.opening.admission))
        let mayDismiss = await finish()
        XCTAssertFalse(mayDismiss)
        await settle { context.media.playback?.ready == true }
        XCTAssertFalse(context.native === oldNative)
        XCTAssertEqual(context.media.playback?.active?.asset.id, fixture.second.asset.id)
        context.media.closePlayback()
        await fixture.library.dispose()
    }
}

@MainActor private final class NikonBarrierGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var pending: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() {
        let captured = waiters
        waiters.removeAll()
        for continuation in captured { continuation.resume() }
    }
}

@MainActor private final class NikonBarrierFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model: NativeAppModel
    let library: MonitorMediaLibraryModel<MediaClip>
    let first: MonitorMediaRecord<MediaClip>, second: MonitorMediaRecord<MediaClip>
    let opening: MonitorMediaGalleryOpen<MediaClip>
    init() throws {
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        for name in ["FIRST.MOV", "SECOND.MOV"] {
            let clip = MediaClip(
                cameraID: MediaClipStore.localBucketID, filename: name, handle: 4,
                storageID: 65_537, sizeBytes: 4, captureDate: "20261004T120000")
            store.upsertBatch([clip], cameraID: clip.cameraID)
            let url = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x80, count: 4).write(to: url)
        }
        model.refreshMediaClips()
        let library = try XCTUnwrap(model.mediaLibrary)
        library.begin()
        let first = try XCTUnwrap(library.records.first { $0.payload.filename == "FIRST.MOV" })
        let second = try XCTUnwrap(library.records.first { $0.payload.filename == "SECOND.MOV" })
        self.model = model
        self.library = library
        self.first = first
        self.second = second
        opening = .init(record: first, playlist: [first, second], admission: library.actionToken)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
