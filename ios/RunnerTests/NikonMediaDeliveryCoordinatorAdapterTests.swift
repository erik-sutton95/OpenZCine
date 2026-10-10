import Foundation
import XCTest

@testable import Runner

/// SIMULATED operation completion gates; shipping coordinator and filesystem lease cleanup.
@MainActor private final class NikonDeliveryAdapterGate {
    var waiters: [CheckedContinuation<MediaDeliveryRunOutcome, Never>] = []
    func wait() async -> MediaDeliveryRunOutcome {
        await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ outcome: MediaDeliveryRunOutcome) {
        waiters.removeFirst().resume(returning: outcome)
    }
}

@MainActor final class NikonMediaDeliveryCoordinatorAdapterTests: XCTestCase {
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Coordinator did not reach the manual operation gate")
    }

    private var request: MediaDeliveryBeginRequest {
        .init(clips: [], destination: .nativeShare, configuration: .init())
    }

    func testCapturedSheetBindingAndOldCompletionCannotClearSuccessorLease() async {
        let gate = NikonDeliveryAdapterGate()
        let coordinator = MediaDeliveryCoordinator(execute: { request, _, progress in
            progress(
                .init(
                    destination: request.destination, totalClips: 1, clipIndex: 1, clipFraction: 0))
            return await gate.wait()
        })
        let model = NativeAppModel()
        defer {
            coordinator.close()
        }
        coordinator.begin(request, model: model)
        await settle { gate.waiters.count == 1 }
        gate.release(
            .share(
                urls: [URL(fileURLWithPath: "/SIMULATED/A.mp4")],
                metadataText: "SIMULATED metadata", stagingCleanupURL: nil))
        await settle { coordinator.sharePayload != nil }
        XCTAssertEqual(coordinator.sharePayload?.metadataText, "SIMULATED metadata")
        let old = coordinator.sharePresentation
        let oldID = coordinator.sharePayload?.id
        XCTAssertEqual(old.wrappedValue?.id, oldID)
        coordinator.begin(request, model: model)
        await settle { gate.waiters.count == 1 }
        gate.release(
            .share(
                urls: [URL(fileURLWithPath: "/SIMULATED/B.mp4")],
                metadataText: nil, stagingCleanupURL: nil))
        await settle { coordinator.sharePayload?.id != oldID }
        let current = coordinator.sharePayload
        old.wrappedValue = nil
        XCTAssertEqual(coordinator.sharePayload?.id, current?.id)
        XCTAssertEqual(coordinator.sharePayload?.urls, current?.urls)
        if let oldID { XCTAssertFalse(coordinator.completeSharePresentation(id: oldID)) }
        XCTAssertEqual(coordinator.sharePayload?.id, current?.id)
        let accepted = coordinator.sharePresentation
        accepted.wrappedValue = nil
        XCTAssertNil(coordinator.sharePayload)
        if let id = current?.id { XCTAssertTrue(coordinator.completeSharePresentation(id: id)) }
    }

    func testUIKitCompletionBeforeBindingNilAcknowledgesDismissalOnlyOnce() async {
        let coordinator = MediaDeliveryCoordinator(execute: { _, _, _ in
            .share(
                urls: [URL(fileURLWithPath: "/SIMULATED/A.mp4")],
                metadataText: nil, stagingCleanupURL: nil)
        })
        let model = NativeAppModel()
        defer {
            coordinator.close()
        }
        coordinator.begin(request, model: model)
        await settle { coordinator.sharePayload != nil }
        let id = coordinator.sharePayload!.id
        let binding = coordinator.sharePresentation
        XCTAssertTrue(coordinator.completeSharePresentation(id: id))
        binding.wrappedValue = nil
        XCTAssertFalse(coordinator.completeSharePresentation(id: id))
        XCTAssertNil(coordinator.sharePayload)
    }

    func testBindingNilBeforeUIKitCompletionAcknowledgesDismissalOnlyOnce() async {
        let coordinator = MediaDeliveryCoordinator(execute: { _, _, _ in
            .share(
                urls: [URL(fileURLWithPath: "/SIMULATED/A.mp4")],
                metadataText: nil, stagingCleanupURL: nil)
        })
        let model = NativeAppModel()
        defer {
            coordinator.close()
        }
        coordinator.begin(request, model: model)
        await settle { coordinator.sharePayload != nil }
        let id = coordinator.sharePayload!.id
        coordinator.sharePresentation.wrappedValue = nil
        XCTAssertNil(coordinator.sharePayload)
        XCTAssertTrue(coordinator.completeSharePresentation(id: id))
        XCTAssertFalse(coordinator.completeSharePresentation(id: id))
    }

    func testCancelledLateShareCleansOnlyReturnedStagingLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-delivery-lease-\(UUID())", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let original = root.appendingPathComponent("original.mp4")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: original)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NikonDeliveryAdapterGate()
        let coordinator = MediaDeliveryCoordinator(execute: { request, _, progress in
            progress(
                .init(
                    destination: request.destination, totalClips: 1, clipIndex: 1, clipFraction: 0))
            return await gate.wait()
        })
        let model = NativeAppModel()
        defer {
            coordinator.close()
        }
        coordinator.begin(request, model: model)
        await settle { gate.waiters.count == 1 }
        coordinator.cancel()
        gate.release(.share(urls: [original], metadataText: nil, stagingCleanupURL: staging))
        await settle { !FileManager.default.fileExists(atPath: staging.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNil(coordinator.sharePayload)
        XCTAssertNil(coordinator.overlayState)
        XCTAssertFalse(coordinator.isActive)
    }

    func testCompletionCallbackReplacementRejectsOutgoingSharePresentation() async {
        let gate = NikonDeliveryAdapterGate()
        let coordinator = MediaDeliveryCoordinator(execute: { request, _, progress in
            progress(
                .init(
                    destination: request.destination, totalClips: 1, clipIndex: 1, clipFraction: 0))
            return await gate.wait()
        })
        let model = NativeAppModel()
        defer {
            coordinator.close()
        }
        coordinator.begin(
            request, model: model,
            onComplete: { _ in
                coordinator.begin(self.request, model: model)
            })
        await settle { gate.waiters.count == 1 }
        gate.release(
            .share(
                urls: [URL(fileURLWithPath: "/SIMULATED/retired.mp4")],
                metadataText: nil, stagingCleanupURL: nil))
        await settle { gate.waiters.count == 1 }
        XCTAssertTrue(coordinator.isActive)
        XCTAssertNil(coordinator.sharePayload)
        coordinator.cancel()
        gate.release(.failed(message: "Cancelled."))
    }

    func testActualFilenameClampAndNestedLocalContextPreserveOverlayAdmission() async {
        let gate = NikonDeliveryAdapterGate()
        let first = MediaClip(
            cameraID: "SIMULATED", filename: "A.MOV", handle: 1,
            storageID: 11, sizeBytes: 2, captureDate: "20260727T120000")
        let last = MediaClip(
            cameraID: "SIMULATED", filename: "B.MOV", handle: 2,
            storageID: 11, sizeBytes: 2, captureDate: "20260727T120001")
        let request = MediaDeliveryBeginRequest(
            clips: [first, last], destination: .nativeShare,
            configuration: .init())
        var coordinator: MediaDeliveryCoordinator!
        coordinator = MediaDeliveryCoordinator(execute: { request, _, progress in
            progress(
                .init(
                    destination: request.destination, totalClips: 2, clipIndex: 0, clipFraction: 0))
            XCTAssertEqual(coordinator.currentClipFilename, "A.MOV")
            progress(
                .init(
                    destination: request.destination, totalClips: 2, clipIndex: 99,
                    clipFraction: 0.5))
            XCTAssertEqual(coordinator.currentClipFilename, "B.MOV")
            return await gate.wait()
        })
        defer {
            coordinator.close()
            coordinator = nil
        }
        let model = NativeAppModel()
        coordinator.enterLocalOverlayContext()
        coordinator.enterLocalOverlayContext()
        coordinator.begin(request, model: model)
        await settle { gate.waiters.count == 1 }
        XCTAssertEqual(coordinator.currentClipFilename, "B.MOV")
        XCTAssertEqual(coordinator.overlayState?.clipIndex, 99)
        XCTAssertEqual(coordinator.overlayState?.clipFraction, 0.5)
        XCTAssertTrue(coordinator.showsLocalOverlay)
        XCTAssertFalse(coordinator.showsGlobalChrome)
        coordinator.exitLocalOverlayContext()
        XCTAssertTrue(coordinator.showsLocalOverlay)
        coordinator.exitLocalOverlayContext()
        XCTAssertFalse(coordinator.showsLocalOverlay)
        XCTAssertTrue(coordinator.showsGlobalChrome)
        coordinator.cancel()
        gate.release(.failed(message: "SIMULATED retired outcome"))
        await settle { gate.waiters.isEmpty }
        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.sharePayload)
        XCTAssertFalse(coordinator.showsGlobalChrome)
    }
}
