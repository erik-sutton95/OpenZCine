import Foundation
import OpenCineAppKit
import XCTest

@testable import Runner

@MainActor private final class NikonCapturedRunGate {
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { waiters.removeFirst().resume() }
}

/// SIMULATED entered operations use the actual app coordinator and its shared captured run.
@MainActor final class NikonDeliveryCapturedRunTests: XCTestCase {
    private var request: MediaDeliveryBeginRequest {
        .init(clips: [], destination: .nativeShare, configuration: .init())
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Captured delivery did not reach its manual gate")
    }
    func testActualSuccessorFirstIOWaitsForOutgoingEnteredCleanup() async throws {
        let gate = NikonCapturedRunGate()
        var entries = 0
        var cleanupFinished = false
        let coordinator = MediaDeliveryCoordinator(execute: { _, _, _ in
            entries += 1
            if entries == 1 {
                await gate.wait()
                cleanupFinished = true
                return .failed(message: "SIMULATED retired predecessor")
            }
            XCTAssertTrue(cleanupFinished)
            await gate.wait()
            return .savedToPhotos(count: 1)
        })
        let model = NativeAppModel()
        defer { coordinator.close() }
        let old = try XCTUnwrap(coordinator.beginCaptured(request, model: model))
        await settle { entries == 1 && gate.waiters.count == 1 }
        let current = try XCTUnwrap(coordinator.beginCaptured(request, model: model))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(entries, 1)
        XCTAssertTrue(coordinator.isActive)
        gate.release()
        await old.awaitEnteredCleanup()
        await settle { entries == 2 && gate.waiters.count == 1 }
        XCTAssertTrue(cleanupFinished)
        XCTAssertTrue(coordinator.isActive)
        gate.release()
        await current.awaitEnteredCleanup()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(coordinator.completionToast, "Saved 1 clip to Photos")
    }
    func testOldHostHandleCancellationCannotRetireTheSuccessorRun() async throws {
        let gate = NikonCapturedRunGate()
        var entries = 0
        let coordinator = MediaDeliveryCoordinator(execute: { _, _, _ in
            entries += 1
            await gate.wait()
            return .share(
                urls: [URL(fileURLWithPath: "/SIMULATED/current.mov")],
                metadataText: nil, stagingCleanupURL: nil)
        })
        let model = NativeAppModel()
        defer { coordinator.close() }
        let old = try XCTUnwrap(coordinator.beginCaptured(request, model: model))
        await settle { entries == 1 && gate.waiters.count == 1 }
        _ = coordinator.beginCaptured(request, model: model)
        gate.release()
        await settle { entries == 2 && gate.waiters.count == 1 }
        old.cancel()
        await old.cancelAndJoin()
        XCTAssertTrue(coordinator.isActive)
        XCTAssertNil(coordinator.sharePayload)
        gate.release()
        await coordinator.capturedRun?.awaitEnteredCleanup()
        XCTAssertEqual(
            coordinator.sharePayload?.urls, [URL(fileURLWithPath: "/SIMULATED/current.mov")])
    }
    func testCancelledCapturedRunJoinWaitsForTheActualEnteredOperation() async throws {
        let gate = NikonCapturedRunGate()
        let coordinator = MediaDeliveryCoordinator(execute: { _, _, _ in
            await gate.wait()
            return .savedToPhotos(count: 1)
        })
        let model = NativeAppModel()
        defer { coordinator.close() }
        let handle = try XCTUnwrap(coordinator.beginCaptured(request, model: model))
        await settle { gate.waiters.count == 1 }
        var joined = false
        let joining = Task {
            await handle.cancelAndJoin()
            joined = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(joined)
        XCTAssertFalse(coordinator.isActive)
        gate.release()
        await joining.value
        XCTAssertTrue(joined)
        XCTAssertNil(coordinator.sharePayload)
        XCTAssertNil(coordinator.completionToast)
    }
}
