import OpenCineAppUITesting
import UIKit
import XCTest

/// Real device qualification reuses the same shared driver as every camera app.
final class PhysicalReferenceAppTests: OpenCineAppUITesting.PhysicalReferenceAppTests {}

/// Opted-in current-build camera qualification through the common physical driver.
final class PhysicalMigrationQualificationTests: OpenCineAppUITesting
        .PhysicalMigrationQualificationTests
{}

// The receipt value types below mirror the app-side definitions in RunnerTests
// (`GyroCaptureTests.swift`): the accepted cross-process contract keeps one shape on both
// sides, carried by the `NativeUIReceiptBridge` container convention.

/// Screen-space point as the app observed it; the reader taps exactly this point.
struct GyroReachPoint: Codable, Equatable {
    let x: Double
    let y: Double
    let nativeX: Double
    let nativeY: Double

    var nativePoint: CGPoint { CGPoint(x: nativeX, y: nativeY) }
    var point: CGPoint { CGPoint(x: x, y: y) }
    var finite: Bool { [x, y, nativeX, nativeY].allSatisfy(\.isFinite) }
}

/// Screen-space rectangle; the reader compares its device-coordinate edges at screen scale.
struct GyroReachRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = min(rect.origin.x, rect.origin.x + rect.size.width)
        y = min(rect.origin.y, rect.origin.y + rect.size.height)
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    func contains(_ point: GyroReachPoint, margin: Double = 0) -> Bool {
        point.x >= x - margin && point.x < x + width + margin
            && point.y >= y - margin && point.y < y + height + margin
    }

    var finite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

/// One gyro control as the reader must see it: identity, painted and expanded frames, and
/// a reach point 2pt inside the expanded lower edge.
struct GyroReachControl: Codable, Equatable {
    let identifier: String?
    let label: String?
    let button: Bool
    let axFrame: GyroReachRect
    let textFrame: GyroReachRect?
    let expandedFrame: GyroReachRect
    let reachPoint: GyroReachPoint
}

/// The owner observation snapshot the reader waits on.
struct GyroReachOutcome: Codable, Equatable {
    let calibrationPoseCount: Int
    let calibrationInProgress: Bool
    let mountCalibrationSaved: Bool
    let logsPresented: Bool
    let logsCount: Int
    let presentedClass: String?
}

/// The app-published reach receipt, bridged from the host app's container.
struct GyroReachReceipt: Codable {
    let schema: Int
    let nonce: String
    let sourceSeal: String
    let bundleID: String
    let simulatorID: String
    let processID: Int32
    let sequence: UInt64
    let observedAt: Double
    let mode: String
    let foreground: Bool
    let keyWindow: Bool
    let rootMounted: Bool
    let rootFillsScene: Bool
    let sceneID: String
    let windowIdentity: String
    let windowFrame: GyroReachRect
    let screenFrame: GyroReachRect
    let screenScale: Double
    let orientation: Int
    let controls: [GyroReachControl]
    let outsidePoint: GyroReachPoint?
    let neighborPoint: GyroReachPoint?
    let outcome: GyroReachOutcome
    let ownerObservations: [String]
}

/// Attach-only native input for the gyro 44pt reach proof.
///
/// Input only: attaches to the unit-test host (the real Runner app) mounting the gyro
/// fixture in its actual scene; never launches, activates or drives the product UI. Every
/// tap is a public `XCUICoordinate.tap()` at a point the app published in its receipt, and
/// the outcome is the app's own coordinator state, bridged back as receipt revisions.
/// Outside the focused native input envelope the whole case skips.
@MainActor
final class GyroNativeInputUITests: XCTestCase {
    private var nonce = ""
    private var sourceSeal = ""
    private var bundleID = ""
    private var simulatorID = ""
    private var receiptURL: URL!
    private var finalSequence: UInt64 = 0

    func testSupplyNativeInputToTheGyroReachProof() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["OPENCINE_NATIVE_UI_MODE"] != nil else {
            throw XCTSkip("The gyro reach reader needs the native input bridge envelope.")
        }
        guard env["OPENCINE_NATIVE_UI_MODE"] == "gyro-hosted-native-input",
            let nonce = env["OPENCINE_NATIVE_UI_NONCE"], UUID(uuidString: nonce) != nil,
            let sourceSeal = env["OPENCINE_NATIVE_UI_SOURCE_SEAL"], sourceSeal.count == 64,
            let bundleID = env["OPENCINE_NATIVE_UI_BUNDLE_ID"],
            let simulatorID = env["SIMULATOR_UDID"], UUID(uuidString: simulatorID) != nil
        else {
            XCTFail("The native input envelope is incomplete.")
            return
        }
        self.nonce = nonce
        self.sourceSeal = sourceSeal
        self.bundleID = bundleID
        self.simulatorID = simulatorID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-native-reader-" + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        receiptURL = directory.appendingPathComponent("app-receipt.json")
        FileHandle.standardOutput.write(
            Data("SIMULATED_NATIVE_UI_INBOX:\(receiptURL.path)\n".utf8))
        // Input only: attaches to the hosted bundle; never launch or activate.
        let app = XCUIApplication(bundleIdentifier: bundleID)
        var notes: [String] = []
        var tapInvoked = 0
        defer { recordOutcome(tapInvoked: tapInvoked, notes: notes) }

        let initial = try await receipt(deadline: .seconds(90)) {
            $0.mode == "gyro-restart-ready" && $0.outcome.calibrationPoseCount == 2
        }
        try verifyIdentity(initial, app: app)
        try verifyGeometry(initial)
        notes.append("identity and geometry verified for \(initial.controls.count) controls")

        // Outside negative: outside every expanded control region nothing may react. The
        // app-side test asserts the same unchanged outcome independently.
        let outside = try XCTUnwrap(initial.outsidePoint)
        try tap(outside, app: app)
        tapInvoked += 1
        try await requireUnchanged(since: initial, window: .seconds(3), what: "outside negative")

        // Reach: restart. Restarting resets the pose sequence to zero.
        try await reach(
            "gyro.calibration.restart", from: initial, app: app,
            until: { $0.mode == "gyro-cancel-ready" && $0.outcome.calibrationPoseCount == 0 })
        tapInvoked += 1
        notes.append("restart: poses 0")

        // Reach: cancel. Ending the calibration is the cancel control's outcome.
        try await reach(
            "gyro.calibration.cancel", app: app,
            until: {
                $0.mode == "gyro-capture-ready" && $0.outcome.calibrationInProgress
                    && $0.ownerObservations.contains("cancel: in progress false")
            })
        tapInvoked += 1
        notes.append("cancel: in progress false")

        // Reach: capture. A fresh first pose must be capturable through the 44pt region.
        try await reach(
            "gyro.calibration.capture", app: app,
            until: {
                // The fixture verifies pose 1 before cancelling calibration to prepare logs.
                // Keep that original owner observation instead of asserting on the reset state.
                $0.mode == "gyro-logs-ready"
                    && $0.ownerObservations.contains("capture: poses 1, in progress true")
            })
        tapInvoked += 1
        notes.append("capture: poses 1")

        // Neighbor negative: in the passive area above the Share/Delete gap, outside both
        // action bands, nothing may react.
        let logsReceipt = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-logs-ready"
        }
        try verifyGeometry(logsReceipt)
        let neighbor = try XCTUnwrap(logsReceipt.neighborPoint)
        try tap(neighbor, app: app)
        tapInvoked += 1
        try await requireUnchanged(
            since: logsReceipt, window: .seconds(3), what: "neighbor negative")

        // Reach: the status pill. `openLogs` is the coordinator's own observation.
        try await reach(
            "monitor.gyroStatus", app: app,
            until: { $0.mode == "gyro-share-ready" && $0.outcome.logsPresented })
        tapInvoked += 1
        notes.append("status: logs presented")

        let shareReceipt = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-share-ready"
        }
        try tapReach(
            try control(labelled: "Share", in: shareReceipt), app: app, receipt: shareReceipt)
        tapInvoked += 1
        _ = try await receipt(deadline: .seconds(30)) { $0.outcome.presentedClass != nil }
        notes.append("share: system sheet presented")
        let closeShare = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeShare.waitForExistence(timeout: 15), "The real Share sheet must close")
        closeShare.tap()
        tapInvoked += 1

        // Reach: delete. The confirmation dialog exists beforehand and is gone after the
        // destructive confirm; the coordinator's own delete empties the logs.
        let deleteReceipt = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-delete-ready"
        }
        let deleteControl = try control(labelled: "Delete", in: deleteReceipt)
        try tapReach(deleteControl, app: app, receipt: deleteReceipt)
        tapInvoked += 1
        var dialogButton = app.sheets.buttons["Delete"].firstMatch
        if !dialogButton.waitForExistence(timeout: 15) {
            dialogButton = app.alerts.buttons["Delete"].firstMatch
            XCTAssertTrue(
                dialogButton.waitForExistence(timeout: 15),
                "The confirmation dialog must exist")
        }
        notes.append("delete: confirmation dialog present")
        dialogButton.tap()
        tapInvoked += 1
        let settled = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-settled" && $0.outcome.logsCount == 0
        }
        XCTAssertEqual(app.sheets.count, 0, "The confirmation dialog must be gone")
        XCTAssertEqual(settled.outcome.logsCount, 0, "The confirmed delete must empty the logs")
        notes.append("delete: logs emptied after confirm")
    }

    // MARK: reader mechanics (accepted attach-only patterns)

    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition {
            throw NSError(
                domain: "GyroReachReader", code: 2,
                userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    /// The accepted device-edge comparator at screen scale: floating-safe frame equality.
    private func deviceEdges(_ frame: GyroReachRect, scale: Double) -> [Double] {
        [
            frame.x * scale, frame.y * scale,
            (frame.x + frame.width) * scale, (frame.y + frame.height) * scale,
        ]
    }

    private func verifyIdentity(_ receipt: GyroReachReceipt, app: XCUIApplication) throws {
        try require(receipt.schema == 1, "Unexpected receipt schema")
        try require(receipt.nonce == nonce, "Receipt nonce mismatch")
        try require(receipt.sourceSeal == sourceSeal, "Receipt source seal mismatch")
        try require(receipt.bundleID == bundleID, "Receipt bundle mismatch")
        try require(
            UUID(uuidString: receipt.simulatorID) == UUID(uuidString: simulatorID),
            "Receipt simulator mismatch")
        try require(receipt.processID > 0, "Receipt process id must be positive")
        try require(receipt.foreground, "The host app must be foreground active")
        try require(receipt.keyWindow, "The fixture window must be key")
        try require(receipt.rootMounted && receipt.rootFillsScene, "The fixture root must fill")
        try require(app.state == .runningForeground, "The host app must be running foreground")
        let appFrame = GyroReachRect(app.frame)
        try require(
            receipt.screenScale > 0 && receipt.windowFrame.finite && appFrame.finite
                && deviceEdges(appFrame, scale: receipt.screenScale)
                    == deviceEdges(receipt.windowFrame, scale: receipt.screenScale),
            "The app frame must match the receipt window at device edges")
    }

    /// Every control's expanded region meets the 44pt floor, and its reach point lies
    /// inside that region and outside every sibling's.
    private func verifyGeometry(_ receipt: GyroReachReceipt) throws {
        for control in receipt.controls {
            try require(
                control.expandedFrame.finite, "The expanded frame must be finite")
            try require(
                control.expandedFrame.width >= 44 && control.expandedFrame.height >= 44,
                "The expanded region must meet the 44pt floor")
            try require(
                control.expandedFrame.contains(control.reachPoint),
                "The reach point must lie inside the expanded region")
            for sibling in receipt.controls where sibling != control {
                try require(
                    !sibling.expandedFrame.contains(control.reachPoint, margin: 1),
                    "The reach point must not sit inside a sibling's region")
            }
        }
    }

    private func control(identifier: String, in receipt: GyroReachReceipt) throws
        -> GyroReachControl
    {
        try XCTUnwrap(
            receipt.controls.first { $0.identifier == identifier },
            "Missing \(identifier) in the receipt")
    }

    private func control(labelled label: String, in receipt: GyroReachReceipt) throws
        -> GyroReachControl
    {
        try XCTUnwrap(
            receipt.controls.first { $0.label == label && $0.button },
            "Missing the \(label) control in the receipt")
    }

    /// Builds the accepted coordinate from the app anchor and requires the dynamic
    /// screenPoint to equal the app-observed point exactly before tapping.
    private func tap(_ point: GyroReachPoint, app: XCUIApplication) throws {
        try require(point.finite, "The tapped point must be finite")
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
        let actual = coordinate.screenPoint
        print(
            "GYRO_NATIVE_POINT: expected=\(point.nativePoint) scene=\(point.point) actual=\(actual) app=\(app.frame)"
        )
        try require(
            actual == point.nativePoint,
            "The reader coordinate \(actual) must equal the app-observed point \(point.nativePoint) exactly"
        )
        coordinate.tap()
    }

    /// Asserts a control's reach geometry before tapping its reach point.
    private func tapReach(
        _ control: GyroReachControl, app: XCUIApplication, receipt: GyroReachReceipt
    ) throws {
        try require(control.button, "A same-label StaticText must never replace the Button")
        try require(
            !(control.textFrame ?? control.axFrame).contains(control.reachPoint),
            "The reach tap must be outside the observed compact paint frame")
        try require(
            control.expandedFrame.width >= 44 && control.expandedFrame.height >= 44,
            "The control must declare a 44pt region")
        try require(
            control.expandedFrame.contains(control.reachPoint),
            "The reach point must lie inside the expanded region")
        for sibling in receipt.controls where sibling != control {
            try require(
                !sibling.expandedFrame.contains(control.reachPoint, margin: 1),
                "The reach point must not sit inside a sibling's region")
        }
        try tap(control.reachPoint, app: app)
    }

    /// Taps the named control's reach point and waits for the next phase condition.
    private func reach(
        _ identifier: String, from current: GyroReachReceipt? = nil, app: XCUIApplication,
        until condition: @escaping (GyroReachReceipt) -> Bool
    ) async throws {
        let source: GyroReachReceipt
        if let current {
            source = current
        } else {
            source = try await receipt(deadline: .seconds(30)) { _ in true }
        }
        let control = try control(identifier: identifier, in: source)
        try tapReach(control, app: app, receipt: source)
        _ = try await receipt(deadline: .seconds(30), condition)
    }

    /// The latest bridged receipt, identity-verified and fresh.
    private func receipt(
        deadline: Duration, _ condition: ((GyroReachReceipt) -> Bool)? = nil
    ) async throws -> GyroReachReceipt {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: deadline)
        while clock.now < limit {
            if let data = FileManager.default.contents(atPath: receiptURL.path),
                let value = try? JSONDecoder().decode(GyroReachReceipt.self, from: data),
                value.schema == 1, value.nonce == nonce, value.sourceSeal == sourceSeal,
                value.bundleID == bundleID,
                UUID(uuidString: value.simulatorID) == UUID(uuidString: simulatorID),
                value.processID > 0,
                value.foreground, value.keyWindow, value.rootMounted, value.rootFillsScene,
                Date().timeIntervalSince1970 - value.observedAt <= 10,
                condition?(value) ?? true
            {
                finalSequence = value.sequence
                return value
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(
            domain: "GyroReachReader", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a receipt"])
    }

    /// The accepted negative shape: over a bounded window every receipt keeps the outcome
    /// unchanged, while the receipt stream keeps flowing (freshness proves liveness).
    private func requireUnchanged(
        since baseline: GyroReachReceipt, window: Duration, what: String
    ) async throws {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: window)
        while clock.now < limit {
            let current = try await receipt(deadline: .seconds(2)) { _ in true }
            try require(
                current.outcome == baseline.outcome, "\(what) changed an owner outcome")
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func recordOutcome(tapInvoked: Int, notes: [String]) {
        let record: [String: Any] = [
            "nonce": nonce, "sourceSeal": sourceSeal, "bundleID": bundleID,
            "simulatorID": simulatorID, "tapInvoked": tapInvoked, "notes": notes,
            "finalSequence": Int(finalSequence),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(
            Data("GYRO_NATIVE_INPUT_OUTCOME:\(String(decoding: data, as: UTF8.self))\n".utf8))
    }
}
