import OpenCineApple
import OpenCineAppKit
import OpenCineCore
import OpenZCineCore
import SwiftUI
import UIKit
import XCTest

@testable import Runner

/// F03 P1 regressions against the app's own composition: the root, the shell and the shared live
/// surface as the app mounts them, with SIMULATED sources and no camera transport.
@MainActor
final class LiveSurfaceRegressionTests: XCTestCase {

    /// One hosted composition in the foreground scene, with the accessibility tree walker the
    /// other composition tests use.
    @MainActor private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        private let previousKey: UIWindow?

        init(_ view: some View, size: CGSize = CGSize(width: 874, height: 402)) throws {
            host = UIHostingController(rootView: AnyView(view))
            host.safeAreaRegions = []
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                    $0.activationState == .foregroundActive
                })
            previousKey = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKeyAndVisible()
        }

        /// Lays out until `done` holds (or about two seconds pass).
        @discardableResult
        func settle(until done: () -> Bool = { false }) async throws -> Bool {
            for _ in 0..<100 {
                host.view.layoutIfNeeded()
                if done() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }

        func element(_ id: String) -> NSObject? {
            elements().first { Self.identifier($0) == id }
        }

        func element(prefix: String) -> NSObject? {
            elements().first { Self.identifier($0).hasPrefix(prefix) }
        }

        /// What VoiceOver reaches, for a failure message.
        var identifiers: [String] { elements().map(Self.identifier).filter { !$0.isEmpty }.sorted() }

        private static func identifier(_ object: NSObject) -> String {
            let getter = NSSelectorFromString("accessibilityIdentifier")
            guard object.responds(to: getter) else { return "" }
            return object.perform(getter)?.takeUnretainedValue() as? String ?? ""
        }

        private func elements() -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                result.append(object)
                for child in object.accessibilityElements as? [NSObject] ?? [] { visit(child) }
                let count = object.accessibilityElementCount()
                if count > 0 && count < 512 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject {
                            visit(child)
                        }
                    }
                }
                if let view = object as? UIView { for child in view.subviews { visit(child) } }
            }
            visit(host.view)
            return result.filter { $0.isAccessibilityElement }
        }
    }

    private func monitor(_ model: NativeAppModel) -> some View {
        GeometryReader { proxy in
            NikonMonitorShell(
                context: LiveViewLayoutContext(
                    proxy: proxy, deviceOrientation: .unknown, screenWidth: nil))
        }
        .environment(model).environment(MediaDeliveryCoordinator())
    }

    // MARK: A1-01, A2-01

    /// A1-01 / A2-01: rail Settings on a relay watcher, a capture card or the demo opened a cover
    /// nothing rendered, because those monitors mounted outside `AppShell`. Every monitor is now
    /// the shell's, so its cover renders over it and closes back to the live monitor.
    func testSettingsOpensItsCoverFromEveryMonitorSource() async throws {
        for source in ["hdmi", "relay", "demo"] {
            let model = NativeAppModel()
            model.preferences = OperatorPreferences.defaults
            switch source {
            case "hdmi":
                model.debugPresentHostedPictureMonitor(source: .hdmiCapture)
            case "relay":
                model.debugPresentHostedPictureMonitor(source: .relay)
            default:
                model.startDemoSession()
            }
            let hosted = try Hosted(
                NativeRootContent().environment(model).environment(MediaDeliveryCoordinator()))
            defer { hosted.close() }
            let monitorShown = try await hosted.settle {
                hosted.element("monitor.system.settings") != nil
            }
            XCTAssertTrue(monitorShown, "\(source): the live monitor must be up")
            XCTAssertNotNil(model.shell.monitor, "\(source): the monitor must be the shell's")

            model.activePanel = .settings
            // The cover's tab strip is a container; its tabs are the elements VoiceOver reaches.
            let coverShown = try await hosted.settle {
                hosted.element(prefix: "monitor.settings.tab.") != nil
            }
            XCTAssertTrue(coverShown, "\(source): Settings must render its cover: \(hosted.identifiers)")

            model.activePanel = nil
            let backToLive = try await hosted.settle {
                hosted.element(prefix: "monitor.settings.tab.") == nil
                    && hosted.element("monitor.system.settings") != nil
            }
            XCTAssertTrue(
                backToLive, "\(source): closing Settings must return to the monitor: \(hosted.identifiers)")
        }
    }

    /// A2-01: a camera with no saved record still gets a shell monitor, named by its session.
    func testACameraWithoutASavedRecordStillGetsAShellMonitor() throws {
        let saved = try XCTUnwrap(
            NativeAppModel.shellCamera(
                host: "192.0.2.10", name: "SIMULATED Z", model: "SIMULATED", serial: "",
                saved: [], legacy: []))
        XCTAssertEqual(saved.displayName, "SIMULATED Z")
        XCTAssertEqual(saved.integration, NikonCameraSession.integration)
        XCTAssertNil(saved.device, "no serial was reported, so no durable identity is claimed")
    }

    // MARK: A1-02

    /// A1-02: a monitor-time failure went to `connectionMessage`, which only the connect screens
    /// render. A capture card that drops while the monitor is up now says so on the monitor.
    func testAMonitorTimeFailureShowsInTheMonitorNote() async throws {
        let model = NativeAppModel()
        model.preferences = OperatorPreferences.defaults
        model.isMonitorPresented = true
        model.videoSource = .hdmiCapture
        let hosted = try Hosted(monitor(model))
        defer { hosted.close() }
        try await hosted.settle()

        model.applyHDMICaptureState(.failed(reason: "SIMULATED capture card unplugged"))

        let shown = try await hosted.settle {
            (hosted.element("monitor.note")?.accessibilityLabel ?? "")
                .contains("SIMULATED capture card unplugged")
        }
        XCTAssertTrue(shown, "the failure must read on the mounted monitor")
    }

    // MARK: A1-03

    /// A1-03: the live chrome started from the `.preview` fixture (ISO 800, "6K · 25p", a battery
    /// at 80) and kept the last body's values after the session ended.
    func testNoFixtureOrPreviousBodyValuesReachTheMonitor() {
        let model = NativeAppModel()
        XCTAssertEqual(model.cameraState, .blank)
        XCTAssertFalse(model.cameraReportsTimecode, "no header has said timecode runs")
        XCTAssertTrue(
            model.shownCameraValues.allSatisfy { $0.value == CameraDisplayState.unavailableValue },
            "unreported camera values must read as unavailable")

        // A first body reported its values; ending its session must not hand them to the next.
        model.cameraState = .preview
        model.clearCameraSessionState(resetConnection: true)
        XCTAssertEqual(model.cameraState, .blank)
    }

    // MARK: A1-04

    /// A1-04: a vignette and grain sat above the processed raster, shading corners and assist
    /// paint. The live picture adds no light or shade of its own: with no frame it is uniform.
    func testThePictureAddsNoTextureOverTheRaster() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "F03-A1-04-\(UUID().uuidString)"))
        let model = NativeAppModel(assist: .restore(storage: defaults))
        for tool in MonitorAssistTool.allCases {
            model.assist.set(tool, visible: false, context: .liveView)
        }
        let renderer = ImageRenderer(
            content: LiveFeedModule(viewportWidth: 320, fixedContentHeight: 180)
                .environment(model)
                .frame(width: 320, height: 180))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var lowest = UInt8.max
        var highest = UInt8.min
        for (index, value) in bytes.enumerated() where index % 4 != 3 {
            lowest = min(lowest, value)
            highest = max(highest, value)
        }
        XCTAssertLessThanOrEqual(
            Int(highest) - Int(lowest), 1, "the picture must not texture or shade the raster")
    }

    // MARK: A1-56

    /// A1-56: a tap before any live-view header sent the camera a point in an invented
    /// 1000-wide space. With no coordinate space from the camera the tap is refused, and the
    /// monitor says why.
    func testATapBeforeTheCameraStatesItsCoordinateSpaceIsRefused() {
        let model = NativeAppModel()
        model.isMonitorPresented = true
        XCTAssertNil(model.liveViewFocus)

        model.setFocusPoint(at: CGPoint(x: 50, y: 50), feedSize: CGSize(width: 160, height: 90))

        XCTAssertEqual(model.monitorNote, "Focus point waits for the camera's live view.")
    }

    // MARK: A1-24, A1-25

    /// A1-24: a volume key or Bluetooth remote started a take under the interface lock and in
    /// photo mode. A remote press now takes the same admission as the on-screen button.
    func testARemoteRecordPressObeysTheLockAndPhotoMode() {
        let model = NativeAppModel()
        model.startDemoSession()

        model.interfaceLocked = true
        model.remoteShutterToggleRecord()
        XCTAssertFalse(model.isRecording, "a locked monitor refuses a remote record")

        model.interfaceLocked = false
        model.applyDemoProperty(.liveViewSelector, data: Data([0]))
        XCTAssertTrue(model.isPhotographyMode)
        model.remoteShutterToggleRecord()
        XCTAssertFalse(model.isRecording, "photo mode never sends a movie record")

        model.applyDemoProperty(.liveViewSelector, data: Data([1]))
        model.remoteShutterToggleRecord()
        XCTAssertTrue(model.isRecording, "an unlocked movie monitor takes the remote press")
    }

    /// A1-25: a relayed record ran through the shared record entry without the host's interface
    /// lock, against its own documented contract. That entry now refuses under the lock.
    func testTheSharedRecordEntryRefusesUnderTheHostLock() {
        let model = NativeAppModel()
        model.startDemoSession()
        model.interfaceLocked = true

        model.toggleRecording()

        XCTAssertFalse(model.isRecording)
        XCTAssertNil(model.pendingRecordConfirmation, "no prompt may stand in for a refused press")
    }
}

/// The demo monitor as the root mounts it, in both phone orientations: it is the shell's
/// monitor, and each frame is attached for visual review.
@MainActor
final class LiveSurfaceScreens: XCTestCase {
    func testTheDemoMonitorInBothOrientations() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        for (name, size) in [
            ("portrait", CGSize(width: 402, height: 874)), ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let model = NativeAppModel()
            model.preferences = OperatorPreferences.defaults
            model.startDemoSession()
            let host = UIHostingController(
                rootView: AnyView(
                    NativeRootContent().environment(model).environment(MediaDeliveryCoordinator())))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            for _ in 0..<60 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNotNil(model.shell.monitor, "\(name): the demo monitor is the shell's")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "after-z-demo-monitor-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
