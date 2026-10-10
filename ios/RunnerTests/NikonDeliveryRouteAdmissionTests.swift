import Foundation
import XCTest

@testable import Runner

@MainActor private final class NikonRouteGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func wait() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}

/// SIMULATED native SSID/leave/join callbacks exercise the actual root route, never a camera.
@MainActor final class NikonDeliveryRouteAdmissionTests: XCTestCase {
    func testCurrentCapturedRouteLeavesAndRestoresItsOriginalSSIDOnce() async throws {
        let model = NativeAppModel()
        var leaves: [String] = []
        var joins: [String] = []
        let token = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-A" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 1 }
        XCTAssertTrue(model.ownsInternetHop(token))
        let entered = try XCTUnwrap(
            model.endInternetHopCaptured(token, rejoin: { _, ssid in joins.append(ssid) }))
        await entered.value
        XCTAssertEqual(leaves, ["SIMULATED-A"])
        XCTAssertEqual(joins, ["SIMULATED-A"])
        XCTAssertFalse(model.internetHopActive)
        XCTAssertNil(model.endInternetHopCaptured(token, rejoin: { _, ssid in joins.append(ssid) }))
        XCTAssertEqual(joins, ["SIMULATED-A"])
    }

    func testLateOldSSIDCannotLeaveOrReleaseTheSuccessorRoute() async throws {
        let model = NativeAppModel()
        let oldSSID = NikonRouteGate<String?>()
        var leaves: [String] = []
        var joins: [String] = []
        let old = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { await oldSSID.wait() }, leaveNetwork: { leaves.append($0) }))
        await settle { oldSSID.count == 1 }
        XCTAssertNil(model.endInternetHopCaptured(old))
        let successor = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-B" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 1 }
        oldSSID.release("SIMULATED-A")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(leaves, ["SIMULATED-B"])
        XCTAssertTrue(model.ownsInternetHop(successor) && model.internetHopActive)
        XCTAssertNil(model.endInternetHopCaptured(old))
        let entered = try XCTUnwrap(
            model.endInternetHopCaptured(successor, rejoin: { _, ssid in joins.append(ssid) }))
        await entered.value
        XCTAssertEqual(joins, ["SIMULATED-B"])
    }

    func testSourceRevokedDuringSSIDReadRefusesUnsentLeave() async throws {
        let model = NativeAppModel()
        let ssid = NikonRouteGate<String?>()
        var current = true
        var leaves = 0
        let token = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { current },
                currentSSID: { await ssid.wait() }, leaveNetwork: { _ in leaves += 1 }))
        await settle { ssid.count == 1 }
        current = false
        ssid.release("SIMULATED-A")
        await settle { !model.internetHopActive }
        XCTAssertFalse(model.ownsInternetHop(token))
        XCTAssertEqual(leaves, 0)
    }

    func testPopupTransferKeepsOnlyTheOriginalNativeReturnFacts() async throws {
        let model = NativeAppModel()
        var leaves: [String] = []
        var joins: [String] = []
        let popup = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-A" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 1 }
        let delivery = try XCTUnwrap(model.transferInternetHop(popup))
        XCTAssertFalse(model.ownsInternetHop(popup))
        XCTAssertTrue(model.ownsInternetHop(delivery))
        XCTAssertNil(model.endInternetHopCaptured(popup))
        let entered = try XCTUnwrap(
            model.endInternetHopCaptured(delivery, rejoin: { _, ssid in joins.append(ssid) }))
        await entered.value
        XCTAssertEqual(leaves, ["SIMULATED-A"])
        XCTAssertEqual(joins, ["SIMULATED-A"])
    }

    func testBeginEndABABeforeQueuedRejoinCannotReviveOldNativeDispatch() async throws {
        let model = NativeAppModel()
        var leaves: [String] = []
        var joins: [String] = []
        let old = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-A" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 1 }
        let oldJoin = try XCTUnwrap(
            model.endInternetHopCaptured(old, rejoin: { _, ssid in joins.append(ssid) }))
        let successor = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-B" }, leaveNetwork: { leaves.append($0) }))
        XCTAssertNil(model.endInternetHopCaptured(successor))
        await oldJoin.value
        XCTAssertTrue(joins.isEmpty)
        XCTAssertEqual(leaves, ["SIMULATED-A"])
    }

    func testEnteredRejoinCleanupStillJoinsOnlyItsOriginalTask() async throws {
        let model = NativeAppModel()
        let join = NikonRouteGate<Void>()
        var leaves: [String] = []
        var joins: [String] = []
        let old = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-A" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 1 }
        let entered = try XCTUnwrap(
            model.endInternetHopCaptured(
                old,
                rejoin: { _, ssid in
                    await join.wait()
                    joins.append(ssid)
                }))
        await settle { join.count == 1 }
        let successor = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                currentSSID: { "SIMULATED-B" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 2 }
        join.release(())
        await entered.value
        XCTAssertEqual(joins, ["SIMULATED-A"])
        XCTAssertTrue(model.ownsInternetHop(successor))
        let successorJoin = try XCTUnwrap(
            model.endInternetHopCaptured(successor, rejoin: { _, ssid in joins.append(ssid) }))
        await successorJoin.value
        XCTAssertEqual(joins, ["SIMULATED-A", "SIMULATED-B"])
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("SIMULATED native route did not reach its manual callback")
    }
}
