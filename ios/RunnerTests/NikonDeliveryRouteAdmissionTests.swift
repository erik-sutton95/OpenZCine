import Foundation
import Network
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineHostedAccessibility
import OpenZCineCore
import SwiftUI
import UIKit
import WebKit
import XCTest

import struct OpenCineCameraVocabulary.MonitorLutPackImportResult

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
    var leaveValidity: [@MainActor () -> Bool] = []
    var joins: [String] = []
    var joinGate: NikonRouteGate<Void>?

    func install(on model: NativeAppModel) {
        model.hopNative = .init(
            currentSSID: { [self] in await answers.removeFirst()() },
            leaveNetwork: { [self] ssid, current in
                leaves.append(ssid)
                leaveValidity.append(current)
            },
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

    /// The leave carries the hop's own validity to the hotspot owner: queued behind a pending
    /// camera join, a stale hop's removal is dropped instead of reaching the OS.
    func testStaleHopLeaveCannotReachTheOS() async throws {
        let fake = NikonHopFake()
        fake.answers = [{ "SIMULATED-A" }]
        let model = hop(fake)
        let token = try XCTUnwrap(model.internetHop.begin(model.hopRoute()))
        await settle { fake.leaves.count == 1 }
        let current = try XCTUnwrap(fake.leaveValidity.first)
        XCTAssertTrue(current(), "The running hop's leave is admitted")
        await model.internetHop.end(token)?.value
        XCTAssertFalse(current(), "A leave still queued when the hop ended never reaches the OS")
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
            rootView: RedDownloadView { _ in MonitorLutPackImportResult(importedCount: 0) }
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

/// SIMULATED local download: the real shared screen must keep its web owner while the opaque
/// progress page is shown, then deliver the fetched archive to the import exactly once.
@MainActor final class LutPackDownloadLifetimeTests: XCTestCase {
    func testProgressCoverRetainsWebOwnerAndDeliversTheArchiveToImport() async throws {
        let traceOrigin = ContinuousClock.now
        let runtimeReady = await HostedAccessibility.awaitRuntime()
        XCTAssertTrue(runtimeReady)
        let server = try LutPackLocalServer()
        let port = try await server.start()
        defer { server.stop() }
        let endpoint = "http://127.0.0.1:\(port)/pack.zip"
        let copy = MonitorLutPackCopy(
            intro: "SIMULATED pack", introDetail: "Local fixture", continueLabel: "Continue",
            hopReady: "Ready", hopUnavailable: "Unavailable", downloading: "Downloading fixture",
            success: { "\($0) added" }, successDetail: "Imported",
            unexpectedSite: "Unexpected site",
            noFile: "No file", pageFailed: "Page failed", httpFailure: { "HTTP \($0)" },
            webPageInsteadOfArchive: "Web page", notAnArchive: "Not an archive")
        var imports: [Data] = []
        let host = UIHostingController(
            rootView: MonitorLutPackDownloadScreen(
                source: MonitorLutPackSource(
                    pageUrl: "about:blank", archiveFileName: "simulated-\(UUID().uuidString).zip",
                    isAllowedDownload: { $0 == endpoint }, cookieOrigins: [], copy: copy),
                readiness: { MonitorLutPackReadiness(network: .available, message: "") },
                hop: nil, noHopMessage: "No hop", hopFailedMessage: "Hop failed",
                closeLabel: "Close",
                importPack: { url in
                    do { imports.append(try Data(contentsOf: url)) } catch {
                        XCTFail("The real download did not leave a readable archive: \(error)")
                    }
                    return .imported(count: 1)
                }, onClose: {}
            ).transaction { $0.disablesAnimations = true })
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let traceState: () -> String = {
            let currentBrowser = host.viewIfLoaded.flatMap { self.webView(in: $0) }
            let fixtureURL: String
            if let url = currentBrowser?.url {
                fixtureURL =
                    url.scheme == "about" || url.host == "127.0.0.1"
                    ? url.absoluteString : "<non-fixture-url>"
            } else {
                fixtureURL = "nil"
            }
            let browserID = currentBrowser.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
            return "sceneState=\(scene.activationState.rawValue) "
                + "sceneBound=\(window.windowScene === scene) key=\(window.isKeyWindow) "
                + "hidden=\(window.isHidden) hostAttached=\(host.viewIfLoaded?.window === window) "
                + "rootMatches=\(window.rootViewController === host) browser=\(browserID) "
                + "browserAttached=\(currentBrowser?.window === window) url=\(fixtureURL) "
                + "loading=\(currentBrowser.map { String($0.isLoading) } ?? "nil") "
                + "request=\(server.receivedRequest) imports=\(imports.count)"
        }
        defer {
            traceLutStage("fixture", event: "exit", origin: traceOrigin, state: traceState())
        }
        try await tracedLutReady("continue-visible", origin: traceOrigin, state: traceState) {
            HostedAccessibility.leaves(in: host.view).contains {
                $0.accessibilityLabel == "Continue"
            }
        }
        let button = try XCTUnwrap(
            HostedAccessibility.leaves(in: host.view).first { $0.accessibilityLabel == "Continue" })
        XCTAssertTrue(button.accessibilityActivate())
        try await tracedLutReady("browser-created", origin: traceOrigin, state: traceState) {
            self.webView(in: host.view) != nil
        }
        let browser = try XCTUnwrap(webView(in: host.view))
        try await tracedLutReady("browser-not-loading", origin: traceOrigin, state: traceState) {
            !browser.isLoading
        }
        traceLutStage("window-open", event: "start", origin: traceOrigin, state: traceState())
        _ = try await browser.evaluateJavaScript("window.open('\(endpoint)'); undefined")
        traceLutStage("window-open", event: "complete", origin: traceOrigin, state: traceState())
        try await tracedLutReady("loopback-request", origin: traceOrigin, state: traceState) {
            server.receivedRequest
        }
        try await tracedLutReady("progress-cover", origin: traceOrigin, state: traceState) {
            HostedAccessibility.leaves(in: host.view).contains {
                $0.accessibilityLabel == "Downloading fixture"
            }
        }
        XCTAssertTrue(
            webView(in: host.view) === browser,
            "The progress cover removed the web owner before its download completed")
        let archive = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4])
        server.complete(with: archive)
        try await tracedLutReady("import-received", origin: traceOrigin, state: traceState) {
            !imports.isEmpty
        }
        XCTAssertEqual(imports, [archive])
        try await tracedLutReady("success-visible", origin: traceOrigin, state: traceState) {
            HostedAccessibility.leaves(in: host.view).contains {
                $0.accessibilityLabel == "1 added"
            }
        }
    }

    /// SIMULATED native component at a compact landscape size first, then portrait. Uses the
    /// production provider copy without opening its page or sending a network request.
    func testBlockedGatewayKeepsItsActionsInsideLandscapeAndPortraitBounds() async throws {
        let runtimeReady = await HostedAccessibility.awaitRuntime()
        XCTAssertTrue(runtimeReady)
        for (name, size) in [
            ("landscape", CGSize(width: 700, height: 340)),
            ("portrait", CGSize(width: 340, height: 700)),
        ] {
            let hop = LutPackGatewayHop()
            let host = UIHostingController(
                rootView: MonitorLutPackDownloadScreen(
                    source: redLutPack,
                    readiness: {
                        RedLUTDownloadAvailability.blockedOnCameraAccessPoint.packReadiness
                    },
                    hop: hop, noHopMessage: "No hop", hopFailedMessage: "Hop failed",
                    closeLabel: "Close",
                    importPack: { _ in
                        XCTFail("The gateway never downloads")
                        return .failed(message: "Unexpected import")
                    },
                    onClose: {}
                ).transaction { $0.disablesAnimations = true })
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            try await ready {
                host.view.layoutIfNeeded()
                return HostedAccessibility.leaves(in: host.view).contains {
                    $0.accessibilityLabel == "Download over internet"
                }
            }
            XCTAssertEqual(host.view.bounds.size, size)
            let capture = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: capture)
            attachment.name = "SIMULATED-lut-blocked-gateway-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let bounds = window.convert(host.view.bounds, from: host.view)
            let screen = UIAccessibility.convertToScreenCoordinates(bounds, in: window)
            let buttons = HostedAccessibility.leaves(in: host.view).filter {
                $0.accessibilityTraits.contains(.button)
            }
            XCTAssertFalse(buttons.isEmpty)
            for button in buttons {
                let frame = button.accessibilityFrame
                XCTAssertGreaterThanOrEqual(
                    frame.minX, screen.minX - 0.5, button.accessibilityLabel ?? name)
                XCTAssertGreaterThanOrEqual(
                    frame.minY, screen.minY - 0.5, button.accessibilityLabel ?? name)
                XCTAssertLessThanOrEqual(
                    frame.maxX, screen.maxX + 0.5, button.accessibilityLabel ?? name)
                XCTAssertLessThanOrEqual(
                    frame.maxY, screen.maxY + 0.5, button.accessibilityLabel ?? name)
                XCTAssertGreaterThanOrEqual(frame.height, 44, button.accessibilityLabel ?? name)
            }
        }
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }

    private func traceLutStage(
        _ stage: String, event: String, origin: ContinuousClock.Instant, state: String
    ) {
        print(
            "SIMULATED-LUT stage=\(stage) event=\(event) elapsed=\(origin.duration(to: ContinuousClock.now)) \(state)"
        )
    }

    private func tracedLutReady(
        _ stage: String, origin: ContinuousClock.Instant, state: () -> String,
        _ predicate: () -> Bool
    ) async throws {
        traceLutStage(stage, event: "start", origin: origin, state: state())
        do {
            try await ready(predicate)
            traceLutStage(stage, event: "complete", origin: origin, state: state())
        } catch {
            traceLutStage(stage, event: "failure", origin: origin, state: state())
            throw error
        }
    }

    private func ready(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "The SIMULATED download did not reach its next real state")
        if !predicate() { throw LutPackReadinessFailure() }
    }

    private struct LutPackReadinessFailure: Error {}
}

/// A loopback-only HTTP response held until the test observes the native progress cover.
@MainActor private final class LutPackLocalServer {
    private let listener: NWListener
    private var connection: NWConnection?
    private(set) var receivedRequest = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.connection = connection
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                    data, _, _, _ in
                    Task { @MainActor in self.receivedRequest = data?.isEmpty == false }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listener.stateUpdateHandler = nil
                        if let port = self.listener.port {
                            continuation.resume(returning: port.rawValue)
                        }
                    case .failed(let error):
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func complete(with body: Data) {
        var response = Data(
            ("HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        response.append(body)
        connection?.send(content: response, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }
}

/// SIMULATED capability only: a ready internet hop, never invoked by the gateway layout proof.
@MainActor private final class LutPackGatewayHop: MonitorLutPackInternetHop {
    var ready: Bool { true }
    var unavailableMessage: String? { nil }
    var switching: Bool { false }
    var active: Bool { false }
    var errorMessage: String? { nil }
    func begin() async -> Bool { false }
    func endAfterDismiss() {}
}
