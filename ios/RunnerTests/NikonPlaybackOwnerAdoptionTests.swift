import AVFoundation
import Foundation
import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

@testable import Runner

@MainActor final class NikonPlaybackOwnerAdoptionTests: XCTestCase {
    func testNativePublicationReentryCannotReplaceSuccessorAssistOwner() async throws {
        try await assertFactoryPublicationReentry(observeAssists: false)
    }
    func testAssistPublicationReentryCannotReplaceSuccessorNativeOwner() async throws {
        try await assertFactoryPublicationReentry(observeAssists: true)
    }
    private func assertFactoryPublicationReentry(observeAssists: Bool) async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let first = try fixture.clip("FIRST.MOV", expected: 4, bytes: 4)
        let second = try fixture.clip("SECOND.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let a = try XCTUnwrap(library.records.first { $0.payload.id == first.id })
        let b = try XCTUnwrap(library.records.first { $0.payload.id == second.id })
        let request = MonitorMediaGalleryOpen(
            record: a, playlist: [a, b], admission: library.actionToken)
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        let capture = PlaybackFactoryPublicationCapture()
        withObservationTracking {
            if observeAssists { _ = context.assists } else { _ = context.native }
        } onChange: {
            MainActor.assumeIsolated {
                capture.entered = true
                context.media.closePlayback()
                XCTAssertTrue(context.media.open(b, playlist: [a, b], admitted: request.admission))
                capture.native = context.native
                capture.assists = context.assists
            }
        }
        XCTAssertFalse(context.media.open(a, playlist: [a, b], admitted: request.admission))
        XCTAssertTrue(capture.entered)
        XCTAssertNotNil(capture.native)
        XCTAssertNotNil(capture.assists)
        XCTAssertTrue(context.native === capture.native)
        XCTAssertTrue(context.assists === capture.assists)
        XCTAssertEqual(context.media.playback?.active?.asset.id, b.asset.id)
        context.media.closePlayback()
        await library.dispose()
    }

    func testCompletePlayerBorrowsActualGalleryRequestAndRejectsBackRetirement() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("BORROW.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let record = try XCTUnwrap(library.records.first { $0.payload.id == clip.id })
        let request = MonitorMediaGalleryOpen(
            record: record, playlist: [record], admission: library.actionToken)
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        XCTAssertTrue(context.library === library)
        XCTAssertEqual(context.initial.record.asset.id, record.asset.id)
        XCTAssertEqual(context.initial.playlist.map(\.asset.id), [record.asset.id])
        XCTAssertNil(context.native)
        library.close()
        XCTAssertFalse(context.media.open(record, playlist: [record], admitted: request.admission))
        XCTAssertNil(context.native)
        XCTAssertNil(context.assists)
        XCTAssertNil(NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        await library.dispose()
    }

    func testCompletePlayerCacheRetirementCannotAcquireFirstNativePicture() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("CACHE.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let record = try XCTUnwrap(library.records.first { $0.payload.id == clip.id })
        let request = MonitorMediaGalleryOpen(
            record: record, playlist: [record], admission: library.actionToken)
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        library.cache.directory.retireWrites()
        XCTAssertFalse(context.media.open(record, playlist: [record], admitted: request.admission))
        XCTAssertNil(context.media.playback)
        XCTAssertNil(context.native)
        XCTAssertNil(context.assists)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(fixture.model.clipLocalURL(clip))),
            Data(repeating: 0x80, count: 4))
        await library.dispose()
    }

    func testActualGrowingFileProbeCannotInstallRetiredClipOverSuccessor() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let old = try fixture.clip("OLD.MOV", expected: 8, bytes: 4)
        let successor = try fixture.clip("NEXT.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        fixture.model.mediaLibrary?.begin()
        let entered = PlaybackSignal()
        let release = PlaybackSignal()
        let installed = PlaybackSignal()
        let streamRelease = PlaybackSignal()
        let streamTask = Task { await streamRelease.wait() }
        let streamTicket = NativeAppModel.MediaClipStreamTicket(task: streamTask)
        defer {
            streamRelease.signal()
            streamTask.cancel()
        }
        let native = NikonPlaybackNativePort(
            playable: { asset in
                XCTAssertEqual(asset.url.lastPathComponent, "OLD.MOV")
                entered.signal()
                await release.wait()
                return true
            }, poll: { XCTFail("The admitted partial probe is playable; no second poll is needed") }
        )
        var installedNames: [String] = []
        native.afterItemInstallation = { item in
            installedNames.append((item.asset as? AVURLAsset)?.url.lastPathComponent ?? "")
            installed.signal()
        }
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let oldToken = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: oldToken)
        guard
            case .cached(let oldItem) = try XCTUnwrap(
                native.candidates(for: old, model: fixture.model, startStream: { streamTicket })
                    .first)
        else { return XCTFail("Actual resolved growing-file candidate missing") }
        let outgoing = Task { () -> Bool in
            do {
                _ = try await native.prepare(oldItem, token: oldToken, readyTimeout: nil)
                return true
            } catch { return false }
        }
        await entered.wait()
        XCTAssertFalse(fixture.model.isClipDownloaded(old))
        XCTAssertNil(native.player.currentItem)
        let successorToken = MonitorPlaybackItemToken(owner: identity, revision: 2)
        native.retireItem(for: successorToken)
        streamRelease.signal()
        guard
            case .cached(let nextItem) = try XCTUnwrap(
                native.candidates(for: successor, model: fixture.model).first)
        else { return XCTFail("Actual resolved successor candidate missing") }
        _ = try await native.prepare(nextItem, token: successorToken, readyTimeout: nil)
        await installed.wait()
        release.signal()
        let outgoingInstalled = await outgoing.value
        XCTAssertFalse(outgoingInstalled)
        XCTAssertEqual(installedNames, ["NEXT.MOV"])
        XCTAssertEqual(
            (native.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent, "NEXT.MOV")
        native.close(token: .init(owner: identity, revision: 3))
        XCTAssertNil(native.player.currentItem)
        await fixture.model.mediaLibrary?.dispose()
    }

    func testActualItemRetirementDetachesHostBeforeReplacementAndBorrowClose() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let first = try fixture.clip("FIRST.MOV", expected: 4, bytes: 4)
        let second = try fixture.clip("SECOND.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        fixture.model.mediaLibrary?.begin()
        let native = NikonPlaybackNativePort()
        let firstInstalled = PlaybackSignal()
        let secondInstalled = PlaybackSignal()
        let retired = PlaybackSignal()
        var attachments = 0
        var retiringNames: [String] = []
        native.afterItemInstallation = { _ in
            attachments += 1
            if attachments == 1 { firstInstalled.signal() } else { secondInstalled.signal() }
        }
        native.beforeItemRetirement = {
            guard let item = native.player.currentItem else { return }
            retiringNames.append((item.asset as? AVURLAsset)?.url.lastPathComponent ?? "")
            if retiringNames.count == 2 { retired.signal() }
        }
        let session = try NikonPlaybackSession(
            clips: [first, second], startingAt: first, model: fixture.model, native: native)
        await firstInstalled.wait()
        session.owner.goToAdjacent(1)
        await secondInstalled.wait()
        XCTAssertEqual(retiringNames, ["FIRST.MOV"])
        XCTAssertFalse(native.player.automaticallyWaitsToMinimizeStalling)
        fixture.model.mediaLibrary?.close()
        await retired.wait()
        XCTAssertEqual(retiringNames, ["FIRST.MOV", "SECOND.MOV"])
        XCTAssertTrue(session.owner.closed)
        XCTAssertNil(native.player.currentItem)
        await fixture.model.mediaLibrary?.dispose()
    }

    func testActualNativeEndAdmissionKeepsDonor250msTailAndRejectsRetiredItem() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let first = try fixture.clip("END.MOV", expected: 4, bytes: 4)
        let next = try fixture.clip("SUCCESSOR.MOV", expected: 4, bytes: 4)
        let native = NikonPlaybackNativePort()
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let oldToken = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: oldToken)
        guard
            case .cached(let firstItem) = try XCTUnwrap(
                native.candidates(for: first, model: fixture.model).first)
        else { return XCTFail("Actual completed clip candidate missing") }
        _ = try await native.prepare(firstItem, token: oldToken, readyTimeout: nil)
        let oldItem = try XCTUnwrap(native.player.currentItem)
        var tail = NikonPlaybackTailPresentation()
        var endedTokens: [MonitorPlaybackItemToken] = []
        native.afterPlaybackEnd = { token in
            endedTokens.append(token)
            tail.ended()
        }
        native.nativeDidEnd(oldItem, admitted: oldToken)
        XCTAssertTrue(tail.reachedEnd)
        tail.seeking(to: 9.9, duration: 10)
        XCTAssertTrue(tail.reachedEnd, "Donor keeps the end latch 100 ms from the tail")
        tail.seeking(to: 9.8, duration: 10)
        XCTAssertTrue(tail.reachedEnd, "Donor keeps the end latch 200 ms from the tail")
        tail.seeking(to: 9.75, duration: 10)
        XCTAssertTrue(tail.reachedEnd, "The donor boundary is strict")
        tail.seeking(to: 9.749, duration: 10)
        XCTAssertFalse(tail.reachedEnd)
        tail.seeking(to: 9.9, duration: 10)
        XCTAssertFalse(
            tail.reachedEnd, "Seeking back into the tail cannot recreate an end observation")
        let nextToken = MonitorPlaybackItemToken(owner: identity, revision: 2)
        native.retireItem(for: nextToken)
        guard
            case .cached(let nextItem) = try XCTUnwrap(
                native.candidates(for: next, model: fixture.model).first)
        else { return XCTFail("Actual successor candidate missing") }
        _ = try await native.prepare(nextItem, token: nextToken, readyTimeout: nil)
        native.nativeDidEnd(oldItem, admitted: oldToken)
        XCTAssertFalse(tail.reachedEnd)
        XCTAssertEqual(endedTokens, [oldToken])
        native.nativeDidEnd(try XCTUnwrap(native.player.currentItem), admitted: nextToken)
        XCTAssertTrue(tail.reachedEnd)
        XCTAssertEqual(endedTokens, [oldToken, nextToken])
        tail.reset()
        XCTAssertFalse(
            tail.reachedEnd, "Restart/navigation explicitly clears the presentation latch")
        native.close(token: .init(owner: identity, revision: 3))
    }

    func testActualCapturedNativeStreamCleanupCannotCancelSuccessorTask() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let first = try fixture.clip("A.MOV", expected: 8, bytes: 4)
        let second = try fixture.clip("B.MOV", expected: 8, bytes: 4)
        // SIMULATED connected facade, no real CameraSession or wire transport is composed.
        fixture.model.connection = .connected
        let outgoing = try XCTUnwrap(fixture.model.startClipStream(first))
        let successor = try XCTUnwrap(fixture.model.startClipStream(second))
        XCTAssertTrue(outgoing.task.isCancelled)
        XCTAssertFalse(successor.task.isCancelled)
        fixture.model.cancelClipStream(outgoing)
        XCTAssertFalse(successor.task.isCancelled)
        fixture.model.cancelClipStream(successor)
        XCTAssertTrue(successor.task.isCancelled)
        await outgoing.task.value
        await successor.task.value
        fixture.model.connection = .disconnected
    }
    func testActualSharedPageMeasuresShareButtonSeparatelyFromAssistBar() async throws {
        let buttonLaidOut = PlaybackSignal()
        let barLaidOut = PlaybackSignal()
        var button = CGRect.zero
        var bar = CGRect.zero
        let page = MonitorPlaybackScreen(
            value: Self.pageValue(clean: false), actions: Self.pageActions(),
            onBarFrame: { frame in
                if frame.width > 0 {
                    bar = frame
                    barLaidOut.signal()
                }
            },
            slots: .init(
                headerAccessory: { AnyView(Color.clear.frame(height: 30)) },
                onShareButtonFrame: { frame in
                    if frame.width > 0 {
                        button = frame
                        buttonLaidOut.signal()
                    }
                }),
            picture: { Color.black }, feedAssists: { _ in EmptyView() },
            canvasAssists: { _, _ in EmptyView() }, tools: { _ in EmptyView() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.rootViewController = UIHostingController(rootView: page)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        await buttonLaidOut.wait()
        await barLaidOut.wait()
        XCTAssertGreaterThan(button.width, 0)
        XCTAssertGreaterThan(button.height, 0)
        XCTAssertLessThan(
            button.width, bar.width,
            "UIKit popup anchor must be the button, not the shared assist bar")
        XCTAssertLessThan(button.height, 100)
        XCTAssertNotEqual(button, bar)
    }

    func testActualSharedPageCleanStartDoesNotMountShareOrRatingAccessory() async throws {
        let canvasLaidOut = PlaybackSignal()
        var shareFrames: [CGRect] = []
        var accessoryAppearances = 0
        let page = MonitorPlaybackScreen(
            value: Self.pageValue(clean: true), actions: Self.pageActions(),
            slots: .init(
                headerAccessory: {
                    AnyView(Color.clear.frame(height: 30).onAppear { accessoryAppearances += 1 })
                },
                canvasDetails: { _ in
                    AnyView(Color.clear.onAppear { canvasLaidOut.signal() })
                }, onShareButtonFrame: { shareFrames.append($0) }),
            picture: { Color.black }, feedAssists: { _ in EmptyView() },
            canvasAssists: { _, _ in EmptyView() }, tools: { _ in EmptyView() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.rootViewController = UIHostingController(rootView: page)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        await canvasLaidOut.wait()
        XCTAssertTrue(shareFrames.isEmpty)
        XCTAssertEqual(accessoryAppearances, 0)
    }

    private static func pageValue(clean: Bool) -> MonitorPlaybackPresentation {
        .init(
            item: .init(owner: UUID(), revision: 1), title: "SIMULATED PAGE.MOV",
            subtitle: "", source: nil, metadata: [], aspect: 16.0 / 9.0,
            ready: true, position: 1, duration: 10, positionLabel: "0:01", durationLabel: "0:10",
            playing: false, reachedEnd: false, scrubbing: false, muted: false,
            looping: false, previous: false, next: false, favorite: false,
            conform: .init(), conformTarget: nil, haptics: false,
            initialChromeVisible: !clean, loopAvailable: false, shareEnabled: false)
    }
    private static func pageActions() -> MonitorPlaybackActions {
        .init(
            back: {}, play: { _, _ in }, restart: { _ in }, seekBy: { _, _ in },
            mute: { _, _ in }, loop: { _, _ in }, conform: { _, _ in }, adjacent: { _, _ in },
            favorite: { _ in }, share: { _ in XCTFail("Disabled share cannot invoke native IO") },
            beginScrub: { _ in nil }, updateScrub: { _, _ in }, updateFrameScrub: { _, _, _ in },
            commitScrub: { _ in }, cancelScrub: { _, _ in })
    }

}

@MainActor private final class PlaybackSignal {
    private var signaled = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func signal() {
        signaled = true
        let captured = pending
        pending.removeAll()
        for continuation in captured { continuation.resume() }
    }
}

@MainActor private final class PlaybackFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: MediaClipStore
    let model: NativeAppModel
    init() throws {
        store = MediaClipStore(root: root)
        model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
    }
    func clip(_ name: String, expected: UInt64, bytes: Int) throws -> MediaClip {
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: name, handle: 4,
            storageID: 65_537, sizeBytes: expected, captureDate: "20261004T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let url = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x80, count: bytes).write(to: url)
        return clip
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class PlaybackFactoryPublicationCapture {
    var native: NikonPlaybackNativePort?
    var assists: NikonPlaybackAssistAdapter?
    var entered = false
}
extension NikonPlaybackOwnerAdoptionTests {
    func testActualGrowingCacheRecoversPixelsWithoutAdvancingBeyondTheHeldPicture() async throws {
        try await assertActualProgressiveRecovery(pauseDuringWait: false)
    }

    func testActualGrowingCachePauseRemainsPausedAfterTheCapturedBytesArrive() async throws {
        try await assertActualProgressiveRecovery(pauseDuringWait: true)
    }

    func testRetiredGrowingCacheCannotResumeOrPublishIntoTheSuccessorItem() async throws {
        try await assertActualProgressiveRecovery(pauseDuringWait: false, retireDuringWait: true)
    }

    func testActualGrowingCacheFailurePublishesOnlyItsCapturedNativeError() async throws {
        try await assertActualProgressiveRecovery(pauseDuringWait: false, failDuringWait: true)
    }

    func testUnresolvedClipSizesRefuseBeforeProbingAndPreserveExistingCacheBytes() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        for size in [UInt64.zero, UInt64(UInt32.max)] {
            let clip = try fixture.clip(
                "SIZE-\(size).MOV", expected: size, bytes: size == 0 ? 0 : 4)
            var probes = 0
            let native = NikonPlaybackNativePort(playable: { _ in
                probes += 1
                return true
            })
            let identity = UUID()
            native.retireItem(for: .init(owner: identity, revision: 0))
            let token = MonitorPlaybackItemToken(owner: identity, revision: 1)
            native.retireItem(for: token)
            defer { native.close(token: token) }
            guard
                case .cached(let source) = try XCTUnwrap(
                    native.candidates(for: clip, model: fixture.model).first)
            else { return XCTFail("The actual cache candidate is required") }
            let before = try Data(contentsOf: source.url)
            do {
                _ = try await native.prepare(source, token: token, readyTimeout: nil)
                XCTFail("An unresolved native total cannot become a resource-loader length")
            } catch {
                XCTAssertEqual(
                    error as? MonitorPlaybackError,
                    .nativeFailure("The clip's full size is unavailable."))
            }
            XCTAssertEqual(probes, 0)
            XCTAssertNil(native.player.currentItem)
            XCTAssertEqual(try Data(contentsOf: source.url), before)
        }
        await fixture.model.mediaLibrary?.dispose()
    }

    func testIncompleteCacheWithoutTransferTicketRefusesBeforeNativeProbe() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("NO-TICKET.MOV", expected: 8, bytes: 4)
        var probes = 0
        let native = NikonPlaybackNativePort(playable: { _ in
            probes += 1
            return true
        })
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let token = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: token)
        defer { native.close(token: token) }
        guard
            case .cached(let source) = try XCTUnwrap(
                native.candidates(for: clip, model: fixture.model).first)
        else { return XCTFail("Actual incomplete cache candidate missing") }
        let before = try Data(contentsOf: source.url)
        do {
            _ = try await native.prepare(source, token: token, readyTimeout: nil)
            XCTFail("An incomplete cache needs its captured transfer ticket")
        } catch {
            XCTAssertEqual(
                error as? MonitorPlaybackError,
                .nativeFailure("The clip transfer is unavailable."))
        }
        XCTAssertEqual(probes, 0)
        XCTAssertNil(native.player.currentItem)
        XCTAssertEqual(try Data(contentsOf: source.url), before)
        await fixture.model.mediaLibrary?.dispose()
    }

    func testCompletedLocalCacheWithUnknownSizeRetainsTheDirectFilePath() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "LOCAL-UNKNOWN.MOV", handle: nil,
            storageID: nil, sizeBytes: 0, captureDate: "20261011T120000")
        fixture.store.upsertBatch([clip], cameraID: clip.cameraID)
        let url = try fixture.store.localURL(cameraID: clip.cameraID, filename: clip.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        var starts = 0
        let native = NikonPlaybackNativePort(playable: { _ in
            XCTFail("A complete local file needs no progressive probe")
            return false
        })
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let token = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: token)
        defer { native.close(token: token) }
        guard
            case .cached(let source) = try XCTUnwrap(
                native.candidates(
                    for: clip, model: fixture.model,
                    startStream: {
                        starts += 1
                        return nil
                    }
                )
                .first)
        else { return XCTFail("The actual completed local cache is required") }
        _ = try await native.prepare(source, token: token, readyTimeout: nil)
        XCTAssertTrue(fixture.model.isClipDownloaded(clip))
        XCTAssertEqual((native.player.currentItem?.asset as? AVURLAsset)?.url, url)
        XCTAssertEqual(starts, 0)
        await fixture.model.mediaLibrary?.dispose()
    }

    func testEndedIncompleteTransferFailsTheUnplayableProbeAndPreservesItsPrefix() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("ENDED.MOV", expected: UInt64(UInt32.max) + 1, bytes: 4)
        let finishedTask = Task {}
        let ticket = NativeAppModel.MediaClipStreamTicket(task: finishedTask)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        let native = NikonPlaybackNativePort(
            playable: { _ in false },
            poll: {
                guard ContinuousClock.now < until else {
                    throw MonitorPlaybackError.nativeFailure(
                        "The fixture did not observe task completion.")
                }
                await Task.yield()
            })
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let token = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: token)
        defer { native.close(token: token) }
        guard
            case .cached(let source) = try XCTUnwrap(
                native.candidates(for: clip, model: fixture.model, startStream: { ticket }).first)
        else { return XCTFail("The captured incomplete source is required") }
        let before = try Data(contentsOf: source.url)
        do {
            _ = try await native.prepare(source, token: token, readyTimeout: nil)
            XCTFail("An ended incomplete native transfer cannot keep probing")
        } catch {
            XCTAssertEqual(
                error as? MonitorPlaybackError,
                .nativeFailure("The clip transfer did not complete."))
        }
        XCTAssertNil(native.player.currentItem)
        XCTAssertEqual(try Data(contentsOf: source.url), before)
        await finishedTask.value
        await fixture.model.mediaLibrary?.dispose()
    }

    private func assertActualProgressiveRecovery(
        pauseDuringWait: Bool, retireDuringWait: Bool = false, failDuringWait: Bool = false
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("complete.mov")
        try await NikonGrowingMovieFixture.write(at: movie)
        let bytes = try Data(contentsOf: movie)
        let prefix = try NikonGrowingMovieFixture.prefixEnd(bytes)
        let store = MediaClipStore(root: directory.appendingPathComponent("cache"))
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: "GROWING.MOV", handle: 4,
            storageID: 65_537, sizeBytes: UInt64(bytes.count), captureDate: "20261011T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let url = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.prefix(prefix).write(to: url)
        model.mediaDownloadProgress[clip.id] = Double(prefix) / Double(bytes.count)
        let writerRelease = PlaybackSignal()
        let streamTask = Task {
            await writerRelease.wait()
            guard !Task.isCancelled else { return }
            do {
                let writer = try FileHandle(forWritingTo: url)
                defer { try? writer.close() }
                if !failDuringWait {
                    try writer.seekToEnd()
                    try writer.write(contentsOf: bytes.suffix(from: prefix))
                }
                model.mediaDownloadProgress[clip.id] =
                    failDuringWait ? Double(prefix) / Double(bytes.count) : 1
            } catch { XCTFail("The owned native writer failed: \(error)") }
        }
        let streamTicket = NativeAppModel.MediaClipStreamTicket(task: streamTask)
        defer {
            writerRelease.signal()
            streamTask.cancel()
        }
        let native = NikonPlaybackNativePort()
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let token = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: token)
        defer { native.close(token: .init(owner: identity, revision: 3)) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        native.afterItemInstallation = { $0.add(output) }
        var transport: MonitorPlaybackTransportState?
        var expectedToken = token
        var observedTokens: [MonitorPlaybackItemToken] = []
        var failures: [String] = []
        native.onEvent = { admitted, event in
            XCTAssertEqual(admitted, expectedToken)
            observedTokens.append(admitted)
            if case .transport(let value) = event { transport = value }
            if case .failed(let message) = event { failures.append(message) }
        }
        guard
            case .cached(let source) = try XCTUnwrap(
                native.candidates(for: clip, model: model, startStream: { streamTicket }).first)
        else { return XCTFail("The actual growing cache must remain the native source") }
        _ = try await native.prepare(source, token: token, readyTimeout: nil)
        let item = try XCTUnwrap(native.player.currentItem)
        defer { item.remove(output) }
        let readyEnd = ContinuousClock.now.advanced(by: .seconds(8))
        while item.status == .unknown, ContinuousClock.now < readyEnd {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
        guard item.status == .readyToPlay else { return }
        XCTAssertFalse(model.isClipDownloaded(clip))
        XCTAssertFalse(native.player.automaticallyWaitsToMinimizeStalling)
        native.play(rate: 1, token: token)
        var sample = NikonGrowingMovieFixture.PixelSample()
        var largestClockLead = 0.0
        let heldEnd = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < heldEnd {
            sample.read(native.player, output)
            if sample.changedTime >= 0 {
                largestClockLead = max(
                    largestClockLead, native.player.currentTime().seconds - sample.changedTime)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let heldChanged = sample.changedTime
        XCTAssertGreaterThan(sample.changedFrames, 0)
        XCTAssertGreaterThan(heldChanged, 0.5, "The prefix must play before completion")
        XCTAssertLessThanOrEqual(native.player.currentTime().seconds, heldChanged + 0.5)
        XCTAssertLessThanOrEqual(largestClockLead, 0.5)
        XCTAssertEqual(transport, .waiting)
        if pauseDuringWait { native.pause(token: token) }
        var successorItem: AVPlayerItem?
        if retireDuringWait {
            item.remove(output)
            native.afterItemInstallation = nil
            let next = MediaClip(
                cameraID: clip.cameraID, filename: "SUCCESSOR.MOV", handle: 5,
                storageID: clip.storageID, sizeBytes: UInt64(bytes.count),
                captureDate: "20261011T120001")
            store.upsertBatch([next], cameraID: next.cameraID)
            try bytes.write(to: store.localURL(cameraID: next.cameraID, filename: next.filename))
            expectedToken = .init(owner: identity, revision: 2)
            native.retireItem(for: expectedToken)
            // The successor must join the exact entered outgoing write before native IO.
            writerRelease.signal()
            guard
                case .cached(let successor) = try XCTUnwrap(
                    native.candidates(for: next, model: model).first)
            else { return XCTFail("The successor's complete native source is required") }
            _ = try await native.prepare(successor, token: expectedToken, readyTimeout: nil)
            successorItem = try XCTUnwrap(native.player.currentItem)
            native.pause(token: expectedToken)
        }
        let publicationBoundary = observedTokens.count
        writerRelease.signal()
        await streamTask.value
        // Exercise the real observed host byte-publication path, not a new native test port.
        if retireDuringWait { model.mediaDownloadProgress[clip.id] = 0.99 }
        model.mediaDownloadProgress[clip.id] =
            failDuringWait ? Double(prefix) / Double(bytes.count) : 1
        let resumedEnd = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < resumedEnd,
            pauseDuringWait || retireDuringWait || failDuringWait
                || sample.changedTime <= heldChanged + 0.5
        {
            sample.read(native.player, output)
            try await Task.sleep(for: .milliseconds(10))
        }
        if failDuringWait {
            XCTAssertFalse(model.isClipDownloaded(clip))
            XCTAssertTrue(native.player.currentItem === item)
            XCTAssertEqual(
                failures,
                [MonitorAppleProgressiveAssetError.incompleteTransfer.localizedDescription])
            XCTAssertEqual(try Data(contentsOf: url), bytes.prefix(prefix))
            XCTAssertEqual(native.player.rate, 0)
            XCTAssertTrue(observedTokens.allSatisfy { $0 == token })
        } else if retireDuringWait {
            XCTAssertTrue(model.isClipDownloaded(clip))
            XCTAssertTrue(native.player.currentItem === successorItem)
            XCTAssertEqual(native.player.rate, 0)
            XCTAssertTrue(
                observedTokens.dropFirst(publicationBoundary).allSatisfy { $0 == expectedToken })
        } else if pauseDuringWait {
            XCTAssertTrue(model.isClipDownloaded(clip))
            XCTAssertLessThanOrEqual(sample.changedTime, heldChanged + 0.5)
            XCTAssertEqual(native.player.rate, 0)
            XCTAssertEqual(transport, .paused)
        } else {
            XCTAssertTrue(model.isClipDownloaded(clip))
            XCTAssertGreaterThan(sample.changedTime, heldChanged + 0.5)
            XCTAssertGreaterThan(native.player.rate, 0)
            XCTAssertEqual(transport, .playing)
        }
        await model.mediaLibrary?.dispose()
    }
}

/// Owned native movie data for the actual partial-cache adapter, with no camera or wire fixture.
@MainActor private enum NikonGrowingMovieFixture {
    struct PixelSample {
        var changedTime = -1.0
        var changedFrames = 0
        private var fingerprint: UInt64?
        mutating func read(_ player: AVPlayer, _ output: AVPlayerItemVideoOutput) {
            let time = player.currentTime()
            var decoded = CMTime.invalid
            guard output.hasNewPixelBuffer(forItemTime: time),
                let buffer = output.copyPixelBuffer(
                    forItemTime: time, itemTimeForDisplay: &decoded),
                decoded.isValid, decoded.seconds.isFinite
            else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard
                let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            else { return }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard width > 0, height > 0 else { return }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var hash: UInt64 = 14_695_981_039_346_656_037
            for y in [0, height / 3, height / 2, height - 1] {
                for x in [0, width / 3, width / 2, width - 1] {
                    for channel in 0..<3 {
                        hash =
                            (hash ^ UInt64(base[y * stride + x * 4 + channel])) &* 1_099_511_628_211
                    }
                }
            }
            if fingerprint != hash {
                fingerprint = hash
                changedTime = decoded.seconds
                changedFrames += 1
            }
        }
    }
    static func write(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            let until = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData, writer.status == .writing,
                ContinuousClock.now < until
            {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.isReadyForMoreMediaData else { throw CocoaError(.fileWriteUnknown) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var optional: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optional)
                    == kCVReturnSuccess
            else { throw CocoaError(.fileWriteUnknown) }
            let buffer = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            guard
                let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            else { throw CocoaError(.coderInvalidValue) }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<96 {
                for x in 0..<128 {
                    let pixel = base + y * stride + x * 4
                    pixel[0] = UInt8((x + frame * 3) % 255)
                    pixel[1] = UInt8((y + frame * 5) % 255)
                    pixel[2] = UInt8((frame * 7) % 255)
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard
                adaptor.append(
                    buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
            else { throw CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw CocoaError(.fileWriteUnknown) }
    }
    static func prefixEnd(_ data: Data) throws -> Int {
        var cursor = 0
        while cursor + 8 <= data.count {
            var size = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            var header = 8
            if size == 1, cursor + 16 <= data.count {
                size = data[(cursor + 8)..<(cursor + 16)].reduce(0) { ($0 << 8) | Int($1) }
                header = 16
            }
            guard size >= header, cursor + size <= data.count else { break }
            if type == "mdat" { return cursor + header + max(1, (size - header) * 35 / 100) }
            cursor += size
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}

extension NikonPlaybackOwnerAdoptionTests {
    func testOfflineCameraCatalogAppearanceStartsTheBorrowedCachedPlayer() async throws {
        try await assertCatalogAppearanceStartsCachedPlayer(source: .camera)
    }

    func testLocalCatalogAppearanceStartsTheBorrowedCachedPlayer() async throws {
        try await assertCatalogAppearanceStartsCachedPlayer(source: .iPhone)
    }

    /// SIMULATED real movie bytes enter through the actual app catalog appearance callback.
    /// The fixture deliberately leaves the newly constructed library unopened.
    private func assertCatalogAppearanceStartsCachedPlayer(source: MediaBrowserSource) async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        fixture.model.mediaBrowserSource = source
        let bucket = source == .camera ? "SIMULATED-OFFLINE-CAMERA" : MediaClipStore.localBucketID
        let url = try fixture.store.localURL(cameraID: bucket, filename: "SIMULATED-CACHED.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let bytes = try Data(contentsOf: url)
        let clip = MediaClip(
            cameraID: bucket, filename: url.lastPathComponent, handle: 4,
            storageID: 65_537, sizeBytes: UInt64(bytes.count), captureDate: "20261011T120000")
        fixture.store.upsertBatch([clip], cameraID: bucket)
        if source == .camera {
            fixture.model.openCachedMediaLibrary()
        } else {
            fixture.model.refreshMediaClips()
            fixture.model.isStandaloneMediaLibraryPresented = true
        }
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        let record = try XCTUnwrap(library.records.first { $0.payload.id == clip.id })
        XCTAssertFalse(fixture.model.isConnected)
        XCTAssertTrue(fixture.model.isClipDownloaded(clip))
        XCTAssertFalse(library.browsing, "The actual catalog must start this fresh offline library")

        let coordinator = MediaDeliveryCoordinator()
        defer { coordinator.close() }
        let host = UIHostingController(
            rootView: MediaBrowserView().environment(fixture.model).environment(coordinator))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let began = await cachedCatalogSettled { library.browsing }
        XCTAssertTrue(began, "MediaBrowser appearance must begin its existing offline library")
        XCTAssertTrue(fixture.model.mediaLibrary === library)
        XCTAssertNil(library.binding, "Offline browsing must not create a camera session")

        let scanned = await cachedCatalogSettled {
            library.entries[record.asset.id]?.isPlayableOffline == true
        }
        XCTAssertTrue(scanned)
        let gallery = MonitorMediaGalleryModel(library: library)
        let request = try XCTUnwrap(
            gallery.open(
                record.asset.id, admitted: gallery.snapshot(), operations: .init(),
                sourceAvailable: false))
        XCTAssertEqual(request.record.payload, clip)
        XCTAssertEqual(request.playlist.map(\.asset.id), [record.asset.id])
        let context = try XCTUnwrap(
            NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        XCTAssertTrue(context.library === library)
        context.media.setPlayerVisible(true)
        context.media.setSceneActive(true)
        XCTAssertTrue(
            context.media.open(
                request.record, playlist: request.playlist, admitted: request.admission))
        let ready = await cachedCatalogSettled { context.media.playback?.ready == true }
        XCTAssertTrue(ready)
        let owner = try XCTUnwrap(context.media.playback)
        let native = try XCTUnwrap(context.native)
        XCTAssertEqual(owner.active?.asset.id, request.record.asset.id)
        XCTAssertTrue(owner.nativeItemInstalled)
        XCTAssertEqual(native.token, owner.token)
        XCTAssertTrue(library.isCurrent(request.admission))
        let asset = try XCTUnwrap(native.player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url, url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        context.media.closePlayback()
        await library.dispose()
    }

    private func cachedCatalogSettled(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return predicate()
    }
}
