import AVFoundation
import Foundation
import MonitorUI
import Observation
import OpenCineAppKit
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
        let fixture = try PlaybackFixture(); defer { fixture.remove() }
        let first = try fixture.clip("FIRST.MOV", expected: 4, bytes: 4)
        let second = try fixture.clip("SECOND.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary); library.begin()
        let a = try XCTUnwrap(library.records.first { $0.payload.id == first.id })
        let b = try XCTUnwrap(library.records.first { $0.payload.id == second.id })
        let request = MonitorMediaGalleryOpen(record: a, playlist: [a, b], admission: library.actionToken)
        let context = try XCTUnwrap(NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        let capture = PlaybackFactoryPublicationCapture()
        withObservationTracking {
            if observeAssists { _ = context.assists } else { _ = context.native }
        } onChange: {
            MainActor.assumeIsolated {
                capture.entered = true
                context.media.closePlayback()
                XCTAssertTrue(context.media.open(b, playlist: [a, b], admitted: request.admission))
                capture.native = context.native; capture.assists = context.assists
            }
        }
        XCTAssertFalse(context.media.open(a, playlist: [a, b], admitted: request.admission))
        XCTAssertTrue(capture.entered)
        XCTAssertNotNil(capture.native); XCTAssertNotNil(capture.assists)
        XCTAssertTrue(context.native === capture.native)
        XCTAssertTrue(context.assists === capture.assists)
        XCTAssertEqual(context.media.playback?.active?.asset.id, b.asset.id)
        context.media.closePlayback(); await library.dispose()
    }

    func testCompletePlayerBorrowsActualGalleryRequestAndRejectsBackRetirement() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.remove() }
        let clip = try fixture.clip("BORROW.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary); library.begin()
        let record = try XCTUnwrap(library.records.first { $0.payload.id == clip.id })
        let request = MonitorMediaGalleryOpen(record: record, playlist: [record], admission: library.actionToken)
        let context = try XCTUnwrap(NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        XCTAssertTrue(context.library === library)
        XCTAssertEqual(context.initial.record.asset.id, record.asset.id)
        XCTAssertEqual(context.initial.playlist.map(\.asset.id), [record.asset.id])
        XCTAssertNil(context.native)
        library.close()
        XCTAssertFalse(context.media.open(record, playlist: [record], admitted: request.admission))
        XCTAssertNil(context.native); XCTAssertNil(context.assists)
        XCTAssertNil(NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        await library.dispose()
    }

    func testCompletePlayerCacheRetirementCannotAcquireFirstNativePicture() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.remove() }
        let clip = try fixture.clip("CACHE.MOV", expected: 4, bytes: 4)
        fixture.model.refreshMediaClips()
        let library = try XCTUnwrap(fixture.model.mediaLibrary); library.begin()
        let record = try XCTUnwrap(library.records.first { $0.payload.id == clip.id })
        let request = MonitorMediaGalleryOpen(record: record, playlist: [record], admission: library.actionToken)
        let context = try XCTUnwrap(NikonOperatorPlaybackContext(model: fixture.model, initial: request))
        library.cache.directory.retireWrites()
        XCTAssertFalse(context.media.open(record, playlist: [record], admitted: request.admission))
        XCTAssertNil(context.media.playback); XCTAssertNil(context.native); XCTAssertNil(context.assists)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fixture.model.clipLocalURL(clip))), Data(repeating: 0x80, count: 4))
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
                native.candidates(for: old, model: fixture.model).first)
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
