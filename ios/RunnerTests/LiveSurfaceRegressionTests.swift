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
}
