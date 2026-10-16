import Foundation
import OpenCineAppKit
import SwiftUI
import UIKit
import XCTest

@testable import Runner

@MainActor private final class NikonRouteGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func wait() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}

/// SIMULATED Nikon Wi‑Fi joiner: each hop reads the next SSID answer.
@MainActor private final class NikonHopFake {
    var answers: [@MainActor () async -> String?] = []
    var leaves: [String] = []
    var joins: [String] = []
    var joinGate: NikonRouteGate<Void>?

    func install(on model: NativeAppModel) {
        model.hopNative = .init(
            currentSSID: { [self] in await answers.removeFirst()() },
            leaveNetwork: { [self] in leaves.append($0) },
            rejoin: { [self] _, ssid in
                if let joinGate { await joinGate.wait() }
                joins.append(ssid)
            })
    }
}

/// The Nikon port of the shared internet hop (A2-16): the actual root route over SIMULATED
/// native SSID, leave and join callbacks, never a camera.
@MainActor final class NikonDeliveryRouteAdmissionTests: XCTestCase {
    private func hop(_ fake: NikonHopFake) -> NativeAppModel {
        let model = NativeAppModel()
        fake.install(on: model)
        return model
    }

    func testCurrentRouteLeavesAndRestoresItsOriginalSSIDOnce() async throws {
        let fake = NikonHopFake()
        fake.answers = [{ "SIMULATED-A" }]
        let model = hop(fake)
        let token = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }
        XCTAssertTrue(model.internetHop.owns(token) && model.internetHopActive)
        let entered = try XCTUnwrap(model.internetHop.end(token))
        await entered.value
        XCTAssertEqual(fake.leaves, ["SIMULATED-A"])
        XCTAssertEqual(fake.joins, ["SIMULATED-A"])
        XCTAssertFalse(model.internetHopActive)
        XCTAssertNil(model.internetHop.end(token))
        XCTAssertEqual(fake.joins, ["SIMULATED-A"])
    }

    func testASecondHopIsRefusedWhileOneRuns() async throws {
        let fake = NikonHopFake()
        fake.answers = [{ "SIMULATED-A" }]
        let model = hop(fake)
        let token = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        XCTAssertNil(model.internetHop.begin(model.hopRoute()), "A running hop is never stolen")
        await settle { fake.leaves.count == 1 }
        await model.internetHop.end(token)?.value
        XCTAssertEqual(fake.leaves, ["SIMULATED-A"])
    }

    func testLateOldSSIDCannotLeaveOrReleaseTheSuccessorRoute() async throws {
        let fake = NikonHopFake()
        let oldSSID = NikonRouteGate<String?>()
        fake.answers = [{ await oldSSID.wait() }, { "SIMULATED-B" }]
        let model = hop(fake)
        let old = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { oldSSID.count == 1 }
        XCTAssertNil(model.internetHop.end(old), "Nothing has left yet")
        let successor = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }
        oldSSID.release("SIMULATED-A")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fake.leaves, ["SIMULATED-B"])
        XCTAssertTrue(model.internetHop.owns(successor) && model.internetHopActive)
        XCTAssertNil(model.internetHop.end(old))
        await model.internetHop.end(successor)?.value
        XCTAssertEqual(fake.joins, ["SIMULATED-B"])
    }

    func testSourceRevokedDuringSSIDReadRefusesUnsentLeave() async throws {
        let fake = NikonHopFake()
        let ssid = NikonRouteGate<String?>()
        fake.answers = [{ await ssid.wait() }]
        let model = hop(fake)
        var current = true
        let token = try XCTUnwrap(model.internetHop.begin(model.hopRoute(), admission: { current }))
        await settle { ssid.count == 1 }
        current = false
        ssid.release("SIMULATED-A")
        await settle { !model.internetHopActive }
        XCTAssertFalse(model.internetHop.owns(token))
        XCTAssertTrue(fake.leaves.isEmpty)
        XCTAssertTrue(fake.joins.isEmpty, "A phone that never left has nothing to rejoin")
    }

    func testTransferKeepsOnlyTheOriginalNativeReturnFacts() async throws {
        let fake = NikonHopFake()
        fake.answers = [{ "SIMULATED-A" }]
        let model = hop(fake)
        let popup = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }
        let delivery = try XCTUnwrap(model.internetHop.transfer(popup))
        XCTAssertFalse(model.internetHop.owns(popup))
        XCTAssertTrue(model.internetHop.owns(delivery))
        XCTAssertNil(model.internetHop.end(popup))
        await model.internetHop.end(delivery)?.value
        XCTAssertEqual(fake.leaves, ["SIMULATED-A"])
        XCTAssertEqual(fake.joins, ["SIMULATED-A"])
    }

    func testBeginEndABABeforeQueuedRejoinCannotReviveOldNativeDispatch() async throws {
        let fake = NikonHopFake()
        fake.answers = [{ "SIMULATED-A" }, { "SIMULATED-B" }]
        let model = hop(fake)
        let old = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }
        let oldJoin = try XCTUnwrap(model.internetHop.end(old))
        let successor = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        XCTAssertNil(model.internetHop.end(successor))
        await oldJoin.value
        XCTAssertTrue(fake.joins.isEmpty)
        XCTAssertEqual(fake.leaves, ["SIMULATED-A"])
    }

    func testEnteredRejoinStillJoinsOnlyItsOriginalRoute() async throws {
        let fake = NikonHopFake()
        let join = NikonRouteGate<Void>()
        fake.joinGate = join
        fake.answers = [{ "SIMULATED-A" }, { "SIMULATED-B" }]
        let model = hop(fake)
        let old = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }
        let entered = try XCTUnwrap(model.internetHop.end(old))
        await settle { join.count == 1 }
        fake.joinGate = nil
        let successor = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 2 }
        join.release(())
        await entered.value
        XCTAssertEqual(fake.joins, ["SIMULATED-A"])
        XCTAssertTrue(model.internetHop.owns(successor))
        await model.internetHop.end(successor)?.value
        XCTAssertEqual(fake.joins, ["SIMULATED-A", "SIMULATED-B"])
    }

    /// A2-59: dismissing the RED download screen ends only a hop that screen began. Another
    /// owner's hop (here one started before the screen appeared) keeps running and is never
    /// rejoined by the screen's disappearance.
    func testRedDownloadScreenDisappearingLeavesAnotherOwnersHopRunning() async throws {
        let fake = NikonHopFake()
        fake.answers = [{ "SIMULATED-A" }]
        let model = hop(fake)
        let other = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }

        var appeared = false
        var disappeared = false
        let host = UIHostingController(
            rootView: RedDownloadView { _ in 0 }
                .environment(model)
                .onAppear { appeared = true }
                .onDisappear { disappeared = true })
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "Presenting the RED screen requires the app's foreground scene")
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        await pump { appeared }

        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
        await pump { disappeared }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(model.internetHop.owns(other), "The screen ended a hop it did not begin")
        XCTAssertTrue(model.internetHopActive)
        XCTAssertTrue(fake.joins.isEmpty, "The screen rejoined the camera for another owner")
        await model.internetHop.end(other)?.value
        XCTAssertEqual(fake.joins, ["SIMULATED-A"])
    }

    /// Spins the main run loop until SwiftUI has delivered a lifecycle callback.
    private func pump(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "SwiftUI lifecycle callback did not arrive")
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("SIMULATED native route did not reach its manual callback")
    }
}
