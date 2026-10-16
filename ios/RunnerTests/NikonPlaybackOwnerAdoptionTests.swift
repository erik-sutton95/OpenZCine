import AVFoundation
import Foundation
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineHostedAccessibility
import OpenCineMedia
import OpenZCineCore
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
        native.onItemChanged = { item in
            guard let item else { return }
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
        native.onItemChanged = { installed in
            guard installed == nil else {
                attachments += 1
                if attachments == 1 { firstInstalled.signal() } else { secondInstalled.signal() }
                return
            }
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
    var assists: MonitorPlaybackAssistSession?
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
        native.onItemChanged = { $0?.add(output) }
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
            native.onItemChanged = nil
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
    private func assertCatalogAppearanceStartsCachedPlayer(source: MediaBrowserSource) async throws
    {
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

        let coordinator = MonitorDeliveryCoordinator()
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

// Draft insertion into existing NikonPlaybackOwnerAdoptionTests after coordinator releases Z.
// SIMULATED local movie; actual app MediaPlayerView composition and native AVPlayer.
extension NikonPlaybackOwnerAdoptionTests {
    func testActualNikonPlayerExposesSharedTransportControls() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let url = try fixture.store.localURL(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-CONTROLS.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: url.lastPathComponent,
            handle: nil, storageID: nil, sizeBytes: UInt64(try Data(contentsOf: url).count),
            captureDate: "20261011T120000")
        let movie = try Data(contentsOf: url)
        let clips = try (0..<3).map { index in
            var value = clip
            value.filename = "SIMULATED-CONTROLS-\(index).MOV"
            let target = try fixture.store.localURL(
                cameraID: value.cameraID, filename: value.filename)
            try movie.write(to: target)
            return value
        }
        fixture.store.upsertBatch(clips, cameraID: clip.cameraID)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let coordinator = MonitorDeliveryCoordinator()
        defer { coordinator.close() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPlayerView(clips: clips, startingAt: clips[1])
                .environment(fixture.model).environment(coordinator))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        let mounted = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view).contains {
                $0.isAccessibilityElement && $0.accessibilityLabel == "Favorite clip"
            }
        }
        XCTAssertTrue(mounted)
        let labels = HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement)
            .compactMap(\.accessibilityLabel)
        for required in [
            "Favorite clip", "Clip information", "Share clip", "Conform preview",
            "Mute", "Loop playback", "Previous clip", "Next clip",
        ] {
            XCTAssertTrue(
                labels.contains(required),
                "Actual Nikon composition omits shared control: " + required)
        }
        let retainedFavorite = try XCTUnwrap(
            HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement).first {
                $0.accessibilityLabel == "Favorite clip"
            })
        XCTAssertTrue(retainedFavorite.accessibilityActivate())
        let favored = try XCTUnwrap(
            fixture.store.list(cameraID: clip.cameraID).first {
                $0.filename == clips[1].filename
            })
        XCTAssertTrue(
            favored.isFavorited, "The admitted rendered action must reach durable favorite state")
        let bytes = try XCTUnwrap(fixture.store.catalogBytes(cameraID: clip.cameraID))
        library.close()
        // A retired native accessibility element may itself refuse activation; either way,
        // its formerly admitted action must never amend the closed source.
        _ = retainedFavorite.accessibilityActivate()
        XCTAssertEqual(
            try fixture.store.catalogBytes(cameraID: clip.cameraID), bytes,
            "A retained rendered action must respect its closed shared playback lifetime")
        await library.dispose()
    }

    func testActualNativeLoopSeeksToStartAndResumesThenDisabledLoopStopsAtEnd() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let url = try fixture.store.localURL(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-LOOP.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let data = try Data(contentsOf: url)
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: url.lastPathComponent,
            handle: nil, storageID: nil, sizeBytes: UInt64(data.count),
            captureDate: "20261011T120000")
        var successor = clip
        successor.filename = "SIMULATED-LOOP-SUCCESSOR.MOV"
        try data.write(
            to: fixture.store.localURL(cameraID: successor.cameraID, filename: successor.filename))
        fixture.store.upsertBatch([clip, successor], cameraID: clip.cameraID)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let native = NikonPlaybackNativePort()
        let session = try NikonPlaybackSession(
            clips: [clip, successor], startingAt: clip, model: fixture.model, native: native)
        defer { session.owner.close() }
        let ready = await cachedCatalogSettled {
            session.owner.ready && native.player.currentItem?.status == .readyToPlay
                && (session.owner.duration ?? 0) > 1
        }
        XCTAssertTrue(ready)
        let item = try XCTUnwrap(native.player.currentItem)
        let token = session.owner.token
        let duration = try XCTUnwrap(session.owner.duration)
        var ended: [MonitorPlaybackItemToken] = []
        // This callback is reached by the real AVPlayerItem end notification, not a fake event.
        native.afterPlaybackEnd = { ended.append($0) }
        session.owner.setPlaying(false)
        session.owner.setLooping(true)
        let positioned = await native.seek(seconds: duration - 0.3, tolerance: 0, token: token)
        XCTAssertTrue(positioned)
        session.owner.setPlaying(true)
        let looped = await cachedCatalogSettled {
            ended == [token] && native.player.currentTime().seconds > 0.1
                && native.player.currentTime().seconds < 1 && native.player.rate > 0
        }
        XCTAssertTrue(looped, "The real native end must seek to zero and resume advancing")
        XCTAssertEqual(session.owner.token, token)
        XCTAssertTrue(native.player.currentItem === item)
        XCTAssertTrue(session.owner.playRequested)
        XCTAssertFalse(session.owner.reachedEnd)

        session.owner.setPlaying(false)
        session.owner.setLooping(false)
        let repositioned = await native.seek(seconds: duration - 0.3, tolerance: 0, token: token)
        XCTAssertTrue(repositioned)
        session.owner.setPlaying(true)
        let stopped = await cachedCatalogSettled {
            ended == [token, token] && session.owner.reachedEnd && native.player.rate == 0
        }
        XCTAssertTrue(stopped, "Disabling loop must leave the actual native end paused")
        XCTAssertFalse(session.owner.playRequested)

        session.owner.goToAdjacent(1)
        let replaced = await cachedCatalogSettled {
            session.owner.token != token && session.owner.ready
                && native.player.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(replaced)
        session.owner.setPlaying(false)
        let replacement = try XCTUnwrap(native.player.currentItem)
        native.nativeDidEnd(item, admitted: token)
        XCTAssertEqual(ended, [token, token])
        XCTAssertTrue(native.player.currentItem === replacement)
        XCTAssertFalse(session.owner.reachedEnd)
        XCTAssertFalse(session.owner.playRequested)
        XCTAssertEqual(native.player.rate, 0)
        session.owner.close()
        await library.dispose()
    }

    func testActualNativeLoadedTimeRangesStaySeparateFromTransferAndRetireBeforeCallbacks()
        async throws
    {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let url = try fixture.store.localURL(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-NATIVE-BUFFER.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let bytes = try Data(contentsOf: url)
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: url.lastPathComponent,
            handle: nil, storageID: nil, sizeBytes: UInt64(bytes.count),
            captureDate: "20261011T120000")
        fixture.store.upsertBatch([clip], cameraID: clip.cameraID)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let native = NikonPlaybackNativePort()
        let session = try NikonPlaybackSession(
            clips: [clip], startingAt: clip, model: fixture.model, native: native)
        defer { session.owner.close() }
        let observed = await cachedCatalogSettled {
            session.owner.ready
                && (native.bufferedThroughSeconds(token: session.owner.token) ?? 0) > 1
        }
        XCTAssertTrue(observed)
        let token = session.owner.token
        let item = try XCTUnwrap(native.player.currentItem)
        let expected = try XCTUnwrap(
            item.loadedTimeRanges.map {
                CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue))
            }.filter { $0.isFinite && $0 >= 0 }.max())
        XCTAssertEqual(
            try XCTUnwrap(native.bufferedThroughSeconds(token: token)), expected, accuracy: 0.001)
        XCTAssertTrue(fixture.model.isClipDownloaded(clip))
        XCTAssertNotEqual(expected, 1, "A complete byte transfer is not the native temporal extent")
        let prior = native.onItemChanged
        var retiringReads: [Double?] = []
        native.onItemChanged = { item in
            if item == nil { retiringReads.append(native.bufferedThroughSeconds(token: token)) }
            prior?(item)
        }
        session.owner.close()
        XCTAssertEqual(retiringReads.count, 1)
        XCTAssertTrue(retiringReads.allSatisfy { $0 == nil })
        XCTAssertNil(native.bufferedThroughSeconds(token: token))
        await library.dispose()
    }

}

// SIMULATED local bytes, actual app gallery and its actual fullScreenCover opening callback.
extension NikonPlaybackOwnerAdoptionTests {
    func testActualNikonGalleryKeepsScrollOffsetWhileOpeningAndReturningFromGrid() async throws {
        try await assertActualGalleryScrollPreserved(layout: .grid)
    }
    func testActualNikonGalleryKeepsScrollOffsetWhileOpeningAndReturningFromList() async throws {
        try await assertActualGalleryScrollPreserved(layout: .list)
    }
    func testActualNikonGalleryDoesNotRestoreAnOutgoingLayoutPosition() async throws {
        try await assertActualGalleryScrollPreserved(layout: .grid, returningLayout: .list)
        try await assertActualGalleryScrollPreserved(layout: .list, returningLayout: .grid)
    }
    private func assertActualGalleryScrollPreserved(
        layout: MonitorMediaLayout, returningLayout: MonitorMediaLayout? = nil
    ) async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let previousLayout = fixture.model.mediaBrowserLayout
        defer { fixture.model.mediaBrowserLayout = previousLayout }
        fixture.model.mediaBrowserLayout = layout
        let url = try fixture.store.localURL(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-SCROLL.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let movie = try Data(contentsOf: url)
        let clips = try (0..<48).map { index in
            let name = String(format: "SIMULATED-SCROLL-%02d.MOV", index)
            let target = try fixture.store.localURL(
                cameraID: MediaClipStore.localBucketID, filename: name)
            try movie.write(to: target)
            return MediaClip(
                cameraID: MediaClipStore.localBucketID, filename: name,
                handle: nil, storageID: nil, sizeBytes: UInt64(movie.count),
                captureDate: "20261011T120000")
        }
        fixture.store.upsertBatch(clips, cameraID: MediaClipStore.localBucketID)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        let coordinator = MonitorDeliveryCoordinator()
        defer { coordinator.close() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaBrowserView()
                .environment(fixture.model).environment(coordinator))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        let ready = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return library.entries.values.filter { $0.isPlayableOffline }.count >= clips.count
                && Self.galleryScrollViews(host.view).contains {
                    $0.contentSize.height > $0.bounds.height + 500
                }
        }
        XCTAssertTrue(ready)
        let scroll = try XCTUnwrap(
            Self.galleryScrollViews(host.view).first {
                $0.contentSize.height > $0.bounds.height + 500
            })
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        host.view.layoutIfNeeded()
        let before = scroll.contentOffset.y
        XCTAssertGreaterThan(before, 300)
        // The actual visible clip action must enter Nikon's real opening callback.
        let found = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view).contains {
                HostedAccessibility.identifier($0)?.hasPrefix("monitor.media.clip.") == true
                    && $0.accessibilityFrame.intersects(scroll.convert(scroll.bounds, to: nil))
            }
        }
        XCTAssertTrue(found)
        let element = try XCTUnwrap(
            HostedAccessibility.elements(in: host.view).first {
                HostedAccessibility.identifier($0)?.hasPrefix("monitor.media.clip.") == true
                    && $0.accessibilityFrame.intersects(scroll.convert(scroll.bounds, to: nil))
            })
        XCTAssertTrue(
            element.accessibilityActivate(),
            "The real visible media clip must open through accessibility")
        XCTAssertEqual(scroll.contentOffset.y, before, accuracy: 1)
        let openingOffsets = PlaybackGalleryOffsetCapture()
        let observation = scroll.observe(\.contentOffset, options: [.new]) { captured, _ in
            MainActor.assumeIsolated {
                // A cover may legitimately retire its offscreen UIKit view. Only a still-mounted
                // gallery viewport can expose the reported visible jump during presentation.
                if captured.window != nil, captured.bounds.height > 1,
                    host.presentedViewController == nil
                        || host.presentedViewController?.isBeingPresented == true
                {
                    openingOffsets.values.append(captured.contentOffset.y)
                }
            }
        }
        // Return only once the cover has finished presenting, as an operator can: UIKit ignores
        // a dismissal sent while the presentation transition is still running.
        let presented = await cachedCatalogSettled {
            host.presentedViewController.map { !$0.isBeingPresented } ?? false
        }
        XCTAssertTrue(presented)
        observation.invalidate()
        for offset in openingOffsets.values { XCTAssertEqual(offset, before, accuracy: 1) }
        if let returningLayout { fixture.model.mediaBrowserLayout = returningLayout }
        host.dismiss(animated: false)
        let returned = await cachedCatalogSettled { host.presentedViewController == nil }
        XCTAssertTrue(returned)
        host.view.layoutIfNeeded()
        if returningLayout != nil {
            // A changed layout remounts the gallery. Sample it once the update has landed and the
            // outgoing scroll view, animated out over 0.2 s, has left the window.
            let remounted = await cachedCatalogSettled {
                host.view.layoutIfNeeded()
                return scroll.window == nil
                    && Self.galleryScrollViews(host.view).contains {
                        $0.window != nil && $0.contentSize.height > $0.bounds.height + 500
                    }
            }
            XCTAssertTrue(remounted, "A changed layout must replace the outgoing gallery")
        }
        let returnedScroll = try XCTUnwrap(
            Self.galleryScrollViews(host.view).first {
                $0.window != nil && $0.contentSize.height > $0.bounds.height + 500
            })
        if returningLayout == nil {
            XCTAssertEqual(
                returnedScroll.contentOffset.y, before, accuracy: 1,
                "Returning from playback must preserve the operator's gallery position even if UIKit remounted it"
            )
        } else {
            XCTAssertEqual(
                returnedScroll.contentOffset.y, -returnedScroll.adjustedContentInset.top,
                accuracy: 1,
                "A changed layout must not inherit the outgoing layout's captured position")
        }
        // Restoration is consumed once. A subsequent operator scroll must stay independent.
        returnedScroll.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        host.view.layoutIfNeeded()
        XCTAssertEqual(returnedScroll.contentOffset.y, 450, accuracy: 1)
        await library.dispose()
    }
    private static func galleryScrollViews(_ view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(galleryScrollViews)
    }
}

@MainActor private final class PlaybackGalleryOffsetCapture {
    var values: [CGFloat] = []
}

extension NikonPlaybackOwnerAdoptionTests {
    /// SIMULATED native session around actual cached movie, shared player and app operations.
    /// The test exposes/cancels a confirmation and never deletes a camera object or user file.
    func testActualConnectedCameraPlaybackExposesDeleteAndCancelKeepsAllBytes() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let bucket = "SIMULATED-DELETE-CAMERA"
        let url = try fixture.store.localURL(cameraID: bucket, filename: "SIMULATED-DELETE.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let bytes = try Data(contentsOf: url)
        let clip = MediaClip(
            cameraID: bucket, filename: url.lastPathComponent, handle: 42,
            storageID: 65_537, sizeBytes: UInt64(bytes.count), captureDate: "20261011T120000")
        fixture.store.upsertBatch([clip], cameraID: bucket)
        let transport = LargeTransferTransport(operations: [.deleteObject])
        let session = try await NativeCameraSession.establish(
            transport: transport, host: "usb:SIMULATED-playback-delete",
            cameraName: "SIMULATED", requestPairing: false)
        fixture.model.debugAdoptEstablishedMediaSession(session)
        defer {
            fixture.model.debugAdoptEstablishedMediaSession(nil)
            session.close()
        }
        fixture.model.mediaBrowserSource = .camera
        fixture.model.openCachedMediaLibrary()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        fixture.model.connection = .connected
        let catalog = try XCTUnwrap(fixture.store.catalogBytes(cameraID: bucket))
        let coordinator = MonitorDeliveryCoordinator()
        defer { coordinator.close() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPlayerView(clips: [clip], startingAt: clip)
                .environment(fixture.model).environment(coordinator))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let mounted = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view)
                .contains { $0.accessibilityLabel == "Delete clip from camera" }
        }
        XCTAssertTrue(
            mounted, "Actual connected Nikon playback must compose the shared deletion service")
        let button = try XCTUnwrap(
            HostedAccessibility.elements(in: host.view)
                .first { $0.accessibilityLabel == "Delete clip from camera" })
        XCTAssertTrue(button.accessibilityActivate())
        let presented = await cachedCatalogSettled { host.presentedViewController != nil }
        XCTAssertTrue(presented)
        let dialog = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertTrue(dialog.message?.contains(clip.filename) == true)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try fixture.store.catalogBytes(cameraID: bucket), catalog)
        let cancel = try XCTUnwrap(dialog.actions.first { $0.style == .cancel }?.title)
        let destructive = try XCTUnwrap(dialog.actions.first { $0.style == .destructive }?.title)
        let rendered = await cachedCatalogSettled {
            dialog.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: dialog.view)
                .contains { $0.accessibilityLabel == destructive }
        }
        XCTAssertTrue(rendered)
        if let cancelButton = HostedAccessibility.elements(in: dialog.view)
            .first(where: { $0.accessibilityLabel == cancel })
        {
            XCTAssertTrue(cancelButton.accessibilityActivate())
        } else {
            // iOS 26 anchors this sheet as a popover with no Cancel row; the accessibility
            // escape gesture is that presentation's real cancel path.
            XCTAssertNotNil(dialog.popoverPresentationController)
            XCTAssertTrue(
                [dialog.view as NSObject, dialog].contains { $0.accessibilityPerformEscape() })
        }
        let dismissed = await cachedCatalogSettled { host.presentedViewController == nil }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try fixture.store.catalogBytes(cameraID: bucket), catalog)
        let calls = await transport.calls
        XCTAssertFalse(
            calls.contains { $0.operation == .deleteObject }, "Cancel sends no camera delete")
        fixture.model.debugAdoptEstablishedMediaSession(nil)
        fixture.model.connection = .disconnected
        let hidden = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return !HostedAccessibility.elements(in: host.view)
                .contains { $0.accessibilityLabel == "Delete clip from camera" }
        }
        XCTAssertTrue(hidden, "Offline cached playback must not advertise camera-card deletion")
        await library.dispose()
    }
}

// SIMULATED connected facade with no camera session: the player's honest-delete rule (D18).
extension NikonPlaybackOwnerAdoptionTests {
    /// D18: like the gallery, the player offers Delete only where a deletion can remove the
    /// camera copy. A connection with no live session behind it removes nothing.
    func testConnectedPlaybackWithoutADeletionAuthorityOffersNoDelete() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let bucket = "SIMULATED-NO-AUTHORITY"
        let url = try fixture.store.localURL(cameraID: bucket, filename: "SIMULATED-KEEP.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let clip = MediaClip(
            cameraID: bucket, filename: url.lastPathComponent, handle: 42, storageID: 65_537,
            sizeBytes: UInt64(try Data(contentsOf: url).count), captureDate: "20261012T120000")
        fixture.store.upsertBatch([clip], cameraID: bucket)
        fixture.model.mediaBrowserSource = .camera
        fixture.model.openCachedMediaLibrary()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        fixture.model.connection = .connected
        defer { fixture.model.connection = .disconnected }
        XCTAssertFalse(
            fixture.model.canDeleteMedia([clip]), "No session: the gallery withholds Delete")
        let coordinator = fixture.model.delivery
        defer { coordinator.close() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPlayerView(clips: [clip], startingAt: clip)
                .environment(fixture.model).environment(coordinator))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let mounted = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view)
                .contains { HostedAccessibility.identifier($0) == "monitor.playback.back" }
        }
        XCTAssertTrue(mounted, "The shared player must mount")
        XCTAssertFalse(
            HostedAccessibility.elements(in: host.view)
                .contains { $0.accessibilityLabel == "Delete clip from camera" },
            "Without a deletion authority the player must not offer a Delete that removes nothing")
        await library.dispose()
    }
}

// SIMULATED local photo; actual photo viewer composition (A2-06).
extension NikonPlaybackOwnerAdoptionTests {
    /// A2-06: photo Share offers the same delivery choices as clips, not a direct share sheet.
    func testPhotoShareOffersTheDeliveryChoices() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("SIMULATED-PHOTO.JPG", expected: 64, bytes: 64)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        let coordinator = MonitorDeliveryCoordinator()
        defer { coordinator.close() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPhotoViewer(clip: clip).environment(fixture.model).environment(
                coordinator))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let share: () -> NSObject? = {
            HostedAccessibility.elements(in: host.view).first {
                $0.accessibilityLabel == "Share photo"
            }
        }
        let mounted = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return share() != nil
        }
        XCTAssertTrue(mounted, "The photo viewer must offer Share")
        XCTAssertTrue(try XCTUnwrap(share()).accessibilityActivate())
        let offered = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view).contains {
                HostedAccessibility.identifier($0)?.hasPrefix("monitor.share.destination.") == true
            }
        }
        XCTAssertTrue(offered, "Photo Share must open the shared delivery choices")
        XCTAssertNil(
            host.presentedViewController, "Photo Share must not bypass delivery with a direct sheet"
        )
        await library.dispose()
    }

    /// A2-44: with no camera the rating read answers nil, so the viewer falls back to Favorite
    /// instead of showing neither control.
    func testAPhotoWithoutAStarRatingOffersFavorite() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("SIMULATED-PHOTO.JPG", expected: 64, bytes: 64)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPhotoViewer(clip: clip).environment(fixture.model).environment(
                fixture.model.delivery))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let favorite = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view).contains {
                $0.accessibilityLabel == "Add to favorites"
            }
        }
        XCTAssertTrue(favorite, "A photo without stars must still offer Favorite")
        await library.dispose()
    }
}

/// Test fixture: the shared playback owner over the actual gallery lifetime and a caller
/// playlist (the app composes it through NikonOperatorPlaybackContext).
@MainActor final class NikonPlaybackSession {
    let owner: MonitorMediaPlaybackModel<MediaClip, String>
    let native: NikonPlaybackNativePort

    init(
        clips: [MediaClip], startingAt clip: MediaClip, model: NativeAppModel,
        native: NikonPlaybackNativePort = NikonPlaybackNativePort()
    ) throws {
        guard let library = model.mediaLibrary else { throw MonitorPlaybackError.unavailable }
        let codec = NikonMediaLibraryCodec(
            store: model.mediaClipStore, bucket: clip.cameraID, service: nil,
            downloaded: { model.isClipDownloaded($0) })
        let records = try clips.map(codec.record)
        guard let first = records.first(where: { $0.payload.id == clip.id }) else {
            throw MonitorPlaybackError.unavailable
        }
        self.native = native
        owner = MonitorMediaPlaybackModel<MediaClip, String>(
            library: library, native: native, readyTimeout: nil, retryNativeFailures: false,
            startTiming: .afterNativeItemInstallation,
            candidates: { record in native.candidates(for: record.payload, model: model) })
        native.isScrubbing = { [weak owner] in owner?.scrubbing ?? true }
        owner.load(first, playlist: records)
    }
}

// One playback engine (A2-46, A2-39 Z side): the Nikon port is a frame source of the shared
// feed, and the page is the shared host with its picture, backdrop, scopes and inspector.
extension NikonPlaybackOwnerAdoptionTests {
    func testNikonFrameSourcePreparesTheSharedFeedBeforeItsItemBecomesCurrent() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let clip = try fixture.clip("FEED.MOV", expected: 4, bytes: 4)
        let feed = MonitorPlaybackFeedSession(configuration: .init(), hdrDisplay: { false })
        let native = NikonPlaybackNativePort(feed: feed)
        let source: any MonitorPlaybackFrameSource = native
        XCTAssertTrue(source.feed === feed)
        let changes = PlaybackItemChanges()
        native.onItemChanged = { item in
            changes.values.append(item.map { item in item.outputs.contains { $0 === feed.output } })
            changes.currentAtReport.append(native.player.currentItem != nil)
        }
        let identity = UUID()
        native.retireItem(for: .init(owner: identity, revision: 0))
        let token = MonitorPlaybackItemToken(owner: identity, revision: 1)
        native.retireItem(for: token)
        changes.values.removeAll()
        changes.currentAtReport.removeAll()
        guard
            case .cached(let item) = try XCTUnwrap(
                native.candidates(for: clip, model: fixture.model).first)
        else { return XCTFail("Actual completed clip candidate missing") }
        _ = try await native.prepare(item, token: token, readyTimeout: nil)
        let current = try XCTUnwrap(native.player.currentItem)
        XCTAssertTrue(
            current.outputs.contains { $0 === feed.output }, "the shared feed reads the item")
        XCTAssertEqual(changes.values, [true])
        native.retireItem(for: .init(owner: identity, revision: 2))
        XCTAssertEqual(changes.values, [true, nil])
        XCTAssertEqual(
            changes.currentAtReport, [true, true],
            "the retirement is reported while the item is still current, before its release")
        XCTAssertFalse(current.outputs.contains { $0 === feed.output })
        native.close(token: .init(owner: identity, revision: 3))
    }

    func testNikonPlaybackEffectsCarryTheClipCalibrationAndTheArmedLook() throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.assistConfiguration.selectedLUT = .builtIn(.log3G10Rec709)
        model.assist.set(.lut, visible: false, context: .playback)
        let mapping = model.playbackExposureSignalMapping
        var input = model.assist.playbackEffects
        input.transfer = .rec709
        let plain = model.nikonPlaybackEffects(input)
        XCTAssertEqual(plain.transfer, mapping.curve.monitorTransfer)
        XCTAssertEqual(plain.clipByte, mapping.clipByte)
        XCTAssertEqual(plain.lutDimension, 0)
        model.assist.set(.lut, visible: true, context: .playback)
        let graded = model.nikonPlaybackEffects(model.assist.playbackEffects)
        XCTAssertGreaterThanOrEqual(graded.lutDimension, 2)
        XCTAssertLessThanOrEqual(graded.lutDimension, CubeLUT.rendererSizeRange.upperBound)
        XCTAssertEqual(
            graded.lutRGBA.count,
            graded.lutDimension * graded.lutDimension * graded.lutDimension * 4
                * MemoryLayout<Float>.size)
        model.assist.set(.lut, visible: false, context: .playback)
        XCTAssertGreaterThanOrEqual(
            model.nikonPlaybackEffects(model.assist.playbackEffects, forceLook: true).lutDimension,
            2,
            "an inspector preview arms the selected look while the picture has none")
    }

    func testNikonPlaybackFeedDeclaresTheRecordingClip() throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let feed = NikonPlaybackFeedSession(model: model)
        defer { feed.shutdown() }
        let mapping = model.playbackExposureSignalMapping
        let bus = LiveFrameSampleBus()
        var effects = MonitorFrameEffects()
        effects.transfer = mapping.curve.monitorTransfer
        feed.setEffects(effects, transfer: effects.transfer, sampleBus: bus)
        XCTAssertEqual(bus.exposureCeiling.clipByte(transfer: effects.transfer), mapping.clipByte)
    }

    func testNikonPlaybackPageMountsTheSharedPictureAndInspectorPreview() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let url = try fixture.store.localURL(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-SHARED.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await NikonGrowingMovieFixture.write(at: url)
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: url.lastPathComponent,
            handle: nil, storageID: nil, sizeBytes: UInt64(try Data(contentsOf: url).count),
            captureDate: "20261011T120000")
        fixture.store.upsertBatch([clip], cameraID: clip.cameraID)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let coordinator = MonitorDeliveryCoordinator()
        defer { coordinator.close() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPlayerView(clips: [clip], startingAt: clip)
                .environment(fixture.model).environment(coordinator))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            fixture.model.assist.configureTool = nil
        }
        host.view.frame = window.bounds
        func picture() -> UIView? {
            Self.descendants(of: host.view).first {
                $0.accessibilityIdentifier == "monitor.native.picture"
            }
        }
        let mounted = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return picture() != nil
        }
        XCTAssertTrue(mounted)
        XCTAssertTrue(
            picture() is MonitorPlaybackFeedHost,
            "the page mounts the shared feed picture, not a private player layer")
        fixture.model.assist.configureTool = .falseColor
        let previewed = await cachedCatalogSettled {
            host.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: host.view).contains {
                HostedAccessibility.identifier($0) == "monitor.inspector.preview"
            }
        }
        XCTAssertTrue(previewed, "the playback inspector shows the shared preview")
        library.close()
        await library.dispose()
    }

    /// A2-71 on Z through the shared host: a finished delivery whose share sheet is still up
    /// covers playback exactly like a running delivery (`coversPlayback`).
    func testPendingShareKeepsNikonPlaybackPausedUntilTheSheetCompletes() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.remove() }
        let url = try fixture.store.localURL(
            cameraID: MediaClipStore.localBucketID, filename: "SIMULATED-COVER.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Self.writeSixSecondClip(to: url)
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: url.lastPathComponent,
            handle: nil, storageID: nil, sizeBytes: UInt64(try Data(contentsOf: url).count),
            captureDate: "20261011T120000")
        fixture.store.upsertBatch([clip], cameraID: clip.cameraID)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary)
        library.begin()
        let delivery = fixture.model.delivery
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaPlayerView(clips: [clip], startingAt: clip)
                .environment(fixture.model).environment(delivery)
                .environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        func player() -> AVPlayer? {
            (Self.descendants(of: host.view).first {
                $0.accessibilityIdentifier == "monitor.native.picture"
            } as? MonitorPlaybackFeedHost)?.playerLayer.player
        }
        let playing = await settledFor(seconds: 10) {
            host.view.layoutIfNeeded()
            return (player()?.rate ?? 0) > 0
        }
        XCTAssertTrue(playing, "The cached clip must play on the shared picture")
        let native = try XCTUnwrap(player())
        let gate = NikonShareCoverGate()
        delivery.begin { _, _ in await gate.wait() }
        let paused = await settledFor(seconds: 5) { gate.waiting && native.rate == 0 }
        XCTAssertTrue(paused, "A running delivery covers playback")
        gate.release(.share(urls: [url], metadataText: nil, stagingCleanupURL: nil))
        let shared = await settledFor(seconds: 5) {
            delivery.lifetime.state.share != nil && !delivery.isActive
        }
        XCTAssertTrue(shared, "The finished run leaves its share pending")
        let resumedBehindSheet = await settledFor(seconds: 1.5) { native.rate > 0 }
        XCTAssertFalse(resumedBehindSheet, "Playback stays paused behind the pending share sheet")
        delivery.lifetime.clearSharePresentation()
        let resumed = await settledFor(seconds: 5) { native.rate > 0 }
        XCTAssertTrue(resumed, "Completing the share sheet uncovers playback")
        library.close()
        await library.dispose()
    }

    private func settledFor(seconds: TimeInterval, _ predicate: @escaping @MainActor () -> Bool)
        async -> Bool
    {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { predicate() } },
            object: nil)
        return await XCTWaiter.fulfillment(of: [expectation], timeout: seconds) == .completed
    }

    /// SIMULATED six second flat H.264 clip, long enough that a resumed player still plays.
    private static func writeSixSecondClip(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<180 {
            let until = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(1))
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

@MainActor private final class PlaybackItemChanges {
    var values: [Bool?] = []
    var currentAtReport: [Bool] = []
}

/// SIMULATED delivery run held open by the test, so the share outcome lands while playing.
@MainActor private final class NikonShareCoverGate {
    private var waiter: CheckedContinuation<MonitorDeliveryCoordinator.Outcome, Never>?
    var waiting: Bool { waiter != nil }
    func wait() async -> MonitorDeliveryCoordinator.Outcome {
        await withCheckedContinuation { waiter = $0 }
    }
    func release(_ outcome: MonitorDeliveryCoordinator.Outcome) {
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}
