import AVFoundation
import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineHostedTestSupport
import OpenCineMedia
import XCTest

@testable import Runner

/// SIMULATED files and manual entered-operation gates exercise the actual native adapter.
/// Four-byte cache files prove attachment ordering, not decoded picture or hardware behavior.
@MainActor final class NikonPlaybackCleanupBarrierTests: XCTestCase {
    private let exports = MonitorDeliveryExportStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-barrier-exports-\(UUID().uuidString)", isDirectory: true))
    /// Waits for the actual state. Readiness comes from AVFoundation loading off the main
    /// actor, so a fixed number of `Task.yield()` rounds measured machine load, not the barrier.
    private func settle(
        _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let reached = await HostedCondition.wait(until: condition)
        XCTAssertTrue(
            reached, "Captured cleanup did not reach its manual boundary", file: file, line: line)
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
        let barrier = NikonBarrierOrder()
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(
                model: fixture.model,
                initial: fixture.opening,
                cameraTransferReleased: {
                    barrier.entries += 1
                    await coordinator.cameraTransferReleased()
                    barrier.released = true
                }))
        XCTAssertTrue(
            context.media.open(
                fixture.first, playlist: fixture.opening.playlist,
                admitted: fixture.opening.admission))
        await settle { barrier.entries == 1 }
        // The order itself is the oracle: any item the player gets while the delivery still
        // caches is recorded when it is installed, however slow or fast the machine is.
        let native = try XCTUnwrap(context.native)
        let installation = native.player.observe(\.currentItem, options: [.initial, .new]) {
            player, _ in
            let installed = player.currentItem != nil
            MainActor.assumeIsolated { barrier.noteInstallation(installed) }
        }
        defer { installation.invalidate() }
        XCTAssertNil(native.player.currentItem, "No item while the camera transfers")
        XCTAssertFalse(barrier.released, "The barrier holds while the delivery caches")
        report?(caching(false))
        await settle { context.media.playback?.ready == true }
        XCTAssertTrue(barrier.released)
        XCTAssertFalse(barrier.installedWhileHeld, "No item while the camera transfers")
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
        native.onItemChanged = {
            guard let item = $0 else { return }
            installed.append((item.asset as? AVURLAsset)?.url.lastPathComponent ?? "")
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

    /// SIMULATED retirement must keep Back available after the shared owner is gone.
    func testAlreadyRetiredPlayerStillCapturesOneCloseCleanup() async throws {
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
        fixture.library.close()
        context.media.closePlayback()
        XCTAssertNil(context.media.playback)
        XCTAssertNil(native.player.currentItem)
        let finish = try XCTUnwrap(
            context.captureCloseCleanup(),
            "A retired shared owner must still offer a working Close")
        XCTAssertNil(context.captureCloseCleanup(), "Close cleanup is captured once")
        let completed = await finish()
        XCTAssertTrue(completed)
        XCTAssertTrue(context.native === native)
        await fixture.library.dispose()
    }

    func testRefusedFirstOpenStillCapturesOneCloseWithoutCreatingNativeWork() async throws {
        let fixture = try NikonBarrierFixture()
        defer { fixture.remove() }
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: fixture.opening))
        fixture.library.close()
        XCTAssertFalse(
            context.media.open(
                fixture.first, playlist: fixture.opening.playlist,
                admitted: fixture.opening.admission))
        XCTAssertNil(context.native)
        XCTAssertNil(context.media.playback)
        let finish = try XCTUnwrap(
            context.captureCloseCleanup(),
            "Refused first open must return without manufacturing a new player")
        XCTAssertNil(context.captureCloseCleanup())
        let completed = await finish()
        XCTAssertTrue(completed)
        XCTAssertNil(context.native)
        XCTAssertEqual(context.initial.admission, fixture.opening.admission)
        await fixture.library.dispose()
    }

    /// The actual retained native adapter owns this manually held, SIMULATED transfer.
    func testRetiredCloseStillJoinsTheEnteredNativeTransfer() async throws {
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
        let token = try XCTUnwrap(context.media.playback?.token)
        let gate = NikonBarrierGate()
        let transfer = Task { await gate.wait() }
        let ticket = NativeAppModel.MediaClipStreamTicket(task: transfer)
        let incomplete = MediaClip(
            cameraID: fixture.second.payload.cameraID,
            filename: fixture.second.payload.filename, handle: nil, storageID: nil,
            sizeBytes: 32, captureDate: "20261004T120000")
        XCTAssertFalse(fixture.model.isClipDownloaded(incomplete))
        var enteredNative = false
        guard
            case .cached(let item) = try XCTUnwrap(
                native.candidates(
                    for: incomplete, model: fixture.model,
                    startStream: {
                        enteredNative = true
                        return ticket
                    }
                ).first)
        else { return XCTFail("The actual native source must expose the owned cache prefix") }
        let prepare = Task { () -> Bool in
            do {
                _ = try await native.prepare(item, token: token, readyTimeout: nil)
                return true
            } catch { return false }
        }
        addTeardownBlock { @MainActor in
            gate.release()
            prepare.cancel()
            transfer.cancel()
            _ = await prepare.value
            await fixture.library.dispose()
        }
        await settle { enteredNative && gate.pending == 1 }
        fixture.library.close()
        context.media.closePlayback()
        let finish = try XCTUnwrap(
            context.captureCloseCleanup(),
            "Shared retirement must not discard the native cleanup join")
        var returned = false
        var closeStarted = false
        let close = Task {
            closeStarted = true
            let result = await finish()
            returned = true
            return result
        }
        await settle { closeStarted }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(returned, "Close waits for the original entered transfer")
        gate.release()
        let completed = await close.value
        XCTAssertTrue(completed)
        XCTAssertTrue(returned)
        XCTAssertNil(context.captureCloseCleanup())
    }
}

/// Records whether the player received an item before the camera-transfer barrier released.
@MainActor private final class NikonBarrierOrder {
    var entries = 0
    var released = false
    private(set) var installedWhileHeld = false
    func noteInstallation(_ installed: Bool) {
        if installed && !released { installedWhileHeld = true }
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
