import Foundation
import OpenCineFrameIO
import XCTest

@testable import Runner

/// SIMULATED pre-teardown handover uses the actual Root task and native route ownership.
@MainActor final class NikonDeliveryRouteHandoverTests: XCTestCase {
    func testHandoverRetiresPopupBeforeNativeLeaveAndRestoresOriginalRoute() async throws {
        let model = NativeAppModel()
        var pending: FrameioInternetHop.Token?
        var popup: FrameioInternetHop.Token?
        var calls: [String] = []
        let started = model.beginInternetHopCaptured(
            admission: { true },
            handover: { old in
                popup = old
                let transferred = model.transferInternetHop(old)
                pending = transferred
                calls.append("transfer")
                return transferred
            }, currentSSID: { "SIMULATED-A" },
            leaveNetwork: { ssid in
                XCTAssertFalse(popup.map(model.ownsInternetHop) ?? true)
                XCTAssertTrue(pending.map(model.ownsInternetHop) ?? false)
                calls.append("leave-\(ssid)")
            })
        _ = try XCTUnwrap(started)
        await settle { calls.count == 2 }
        let current = try XCTUnwrap(pending)
        XCTAssertEqual(calls, ["transfer", "leave-SIMULATED-A"])
        XCTAssertNil(model.endInternetHopCaptured(try XCTUnwrap(popup)))
        let join = try XCTUnwrap(
            model.endInternetHopCaptured(
                current, rejoin: { _, ssid in calls.append("join-\(ssid)") }))
        await join.value
        XCTAssertEqual(calls, ["transfer", "leave-SIMULATED-A", "join-SIMULATED-A"])
    }
    func testReceiptRetiredInsideHandoverRefusesBeforeNativeLeave() async throws {
        let model = NativeAppModel()
        var current = true
        var pending: FrameioInternetHop.Token?
        var leaves = 0
        _ = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { current },
                handover: { old in
                    pending = model.transferInternetHop(old)
                    current = false
                    return pending
                }, currentSSID: { "SIMULATED-A" }, leaveNetwork: { _ in leaves += 1 }))
        await settle { pending != nil && !model.internetHopActive }
        XCTAssertEqual(leaves, 0)
        XCTAssertFalse(model.ownsInternetHop(try XCTUnwrap(pending)))
    }
    func testRefusedHandoverDoesNotLeaveOrRetireSuccessorRoute() async throws {
        let model = NativeAppModel()
        var successor: FrameioInternetHop.Token?
        var leaves: [String] = []
        let old = try XCTUnwrap(
            model.beginInternetHopCaptured(
                admission: { true },
                handover: { old in
                    _ = model.endInternetHopCaptured(old)
                    successor = model.beginInternetHopCaptured(
                        admission: { true }, currentSSID: { "SIMULATED-B" },
                        leaveNetwork: { leaves.append($0) })
                    return nil
                }, currentSSID: { "SIMULATED-A" }, leaveNetwork: { leaves.append($0) }))
        await settle { leaves.count == 1 }
        XCTAssertEqual(leaves, ["SIMULATED-B"])
        XCTAssertFalse(model.ownsInternetHop(old))
        XCTAssertTrue(model.ownsInternetHop(try XCTUnwrap(successor)))
        let join = try XCTUnwrap(
            model.endInternetHopCaptured(try XCTUnwrap(successor), rejoin: { _, _ in }))
        await join.value
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("SIMULATED captured handover did not enter its manual callback")
    }
}
