import OpenCineAppKit
import OpenCineCore
import OpenZCineCore
import SwiftUI
import UIKit
import XCTest

@testable import Runner

/// A1-37 and A2-60 on the app's own composition: the demo monitor's LUT inspector, as the shared
/// live surface mounts it, with a SIMULATED source and no camera transport.
@MainActor
final class LUTInspectorAdoptionTests: XCTestCase {
    /// The demo monitor in the foreground scene, walked the way VoiceOver reaches it.
    @MainActor
    private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        private let previousKey: UIWindow?

        init(_ view: some View, size: CGSize) throws {
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

        @discardableResult
        func settle(until done: () -> Bool = { false }) async throws -> Bool {
            for _ in 0..<150 {
                host.view.layoutIfNeeded()
                if done() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }

        func elements(labeled label: String) -> [NSObject] {
            elements().filter { $0.accessibilityLabel == label }
        }

        func element(_ id: String) -> NSObject? {
            elements().first { Self.identifier($0) == id }
        }

        var labels: [String] { elements().compactMap(\.accessibilityLabel).sorted() }

        func image() -> UIImage {
            UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }

        private static func identifier(_ object: NSObject) -> String {
            let getter = NSSelectorFromString("accessibilityIdentifier")
            guard object.responds(to: getter) else { return "" }
            return object.perform(getter)?.takeUnretainedValue() as? String ?? ""
        }

        private func elements() -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            @MainActor func visit(_ object: NSObject) {
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
            visit(window)
            return result.filter { $0.isAccessibilityElement }
        }
    }

    private static let comparison = "50 / 50 split"

    /// The demo monitor with the LUT inspector open, in one orientation.
    private func lutInspector(size: CGSize) async throws -> (NativeAppModel, Hosted) {
        let model = NativeAppModel(assist: .scratch())
        model.preferences = OperatorPreferences.defaults
        model.cameraState = .preview
        model.isMonitorPresented = true
        model.videoSource = .hdmiCapture
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image {
            context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        model.liveFrameImage = picture
        model.shell.present(
            ConnectedCamera(
                saved: SavedCamera(
                    id: "SIMULATED-lut-inspector",
                    integration: IntegrationID("org.opencapture.nikon-ptp"),
                    advertisedName: "SIMULATED camera", model: "SIMULATED"),
                session: NikonPictureLifetimeSession()))
        let hosted = try Hosted(
            GeometryReader { proxy in
                NikonMonitorShell(
                    context: LiveViewLayoutContext(
                        proxy: proxy, deviceOrientation: .unknown, screenWidth: nil)
                )
                .environment(model).environment(MediaDeliveryCoordinator())
                .environment(\.scenePhase, .active)
            }, size: size)
        let monitor = try await hosted.settle {
            hosted.element("monitor.system.settings") != nil && model.operatorSession.interactive
                && model.shell.control.snapshot != nil
        }
        XCTAssertTrue(monitor, "the demo monitor must be up")
        if let expand = hosted.element("monitor.assists.expand") {
            XCTAssertTrue(expand.accessibilityActivate())
        }
        let expanded = try await hosted.settle { hosted.element("monitor.assist.LUT") != nil }
        XCTAssertTrue(expanded, "The real palette must expose its LUT action")
        let chip = try XCTUnwrap(hosted.element("monitor.assist.LUT"))
        let options = try XCTUnwrap(chip.accessibilityCustomActions?.first { $0.name == "Options" })
        let handler = try XCTUnwrap(options.actionHandler)
        XCTAssertTrue(handler(options))
        XCTAssertEqual(model.assist.configureTool, .lut)
        let open = try await hosted.settle {
            hosted.elements(labeled: Self.comparison).contains {
                $0.accessibilityTraits.contains(.button)
            }
        }
        XCTAssertTrue(open, "the LUT inspector must open: \(hosted.labels)")
        try await hosted.settle()
        return (model, hosted)
    }

    /// A1-37: the inspector pins one look comparison, and offers no Exposure control the Nikon
    /// picture would ignore. Before, Z's own picker added a second 50/50 row and the shared
    /// footer a dead Exposure slider.
    func testTheLUTInspectorShowsOneComparisonAndNoDeadExposure() async throws {
        for (name, size) in [
            ("portrait", CGSize(width: 402, height: 874)),
            ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let (_, hosted) = try await lutInspector(size: size)
            defer { hosted.close() }
            let attachment = XCTAttachment(image: hosted.image())
            attachment.name = "z-lut-inspector-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            XCTAssertEqual(
                hosted.elements(labeled: Self.comparison).filter {
                    $0.accessibilityTraits.contains(.button)
                }.count, 1,
                "\(name): one comparison row: \(hosted.labels)")
            XCTAssertTrue(
                hosted.elements(labeled: "Exposure").filter {
                    $0.accessibilityTraits.contains(.adjustable)
                }.isEmpty,
                "\(name): no Exposure slider the picture ignores: \(hosted.labels)")
        }
    }

    /// Actual modal ownership: no persistent rail may cover or receive input over the footer.
    func testTheComparisonIsUnobstructedAndClosingRestoresTheMonitorRail() async throws {
        for (name, size) in [
            ("portrait", CGSize(width: 402, height: 874)),
            ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let (model, hosted) = try await lutInspector(size: size)
            defer { hosted.close() }
            let row = try XCTUnwrap(
                hosted.elements(labeled: Self.comparison).first {
                    $0.accessibilityTraits.contains(.button)
                })
            let frame = row.accessibilityFrame
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(hosted.window.bounds.insetBy(dx: -1, dy: -1).contains(frame))
            let rails = [
                "monitor.system.lock", "monitor.system.display", "monitor.system.settings",
            ]
            let obstructions = rails.compactMap { id -> String? in
                guard let element = hosted.element(id), element.accessibilityFrame.intersects(frame)
                else { return nil }
                return "\(id) \(element.accessibilityFrame)"
            }
            XCTAssertTrue(
                obstructions.isEmpty,
                "\(name): footer \(frame) is covered by monitor controls: \(obstructions)")
            for id in rails {
                XCTAssertNil(
                    hosted.element(id),
                    "\(name): covered rail must leave modal accessibility: \(id)")
            }
            let ready = try await hosted.settle {
                hosted.element("monitor.inspector.preview")?.accessibilityValue == "Picture"
            }
            XCTAssertTrue(ready, "\(name): the admitted held source must render in the modal")
            let before = model.assist.splitComparison
            XCTAssertTrue(row.accessibilityActivate())
            XCTAssertEqual(model.assist.splitComparison, !before)
            XCTAssertEqual(model.assist.configureTool, .lut)
            XCTAssertTrue(row.accessibilityActivate())
            XCTAssertEqual(model.assist.splitComparison, before)
            let updated = try await hosted.settle {
                hosted.element("monitor.inspector.preview")?.accessibilityValue == "Picture"
            }
            XCTAssertTrue(
                updated,
                "\(name): comparison changes must render the held source again: "
                    + "raw=\(model.nativeInspectorImageSource.snapshot != nil), frame=\(model.nativeInspectorFrame != nil), "
                    + "meaning=\(model.nativeInspectorMeaning(tool: .lut) != nil), sourceActive=\(model.liveFrameSource?.isActive == true), "
                    + "tool=\(String(describing: model.assist.configureTool)), covered=\(model.assist.liveCovered), "
                    + "scene=\(model.assist.inspectorSceneActive), armed=\(model.assist.lutArmed), "
                    + "value=\(String(describing: hosted.element("monitor.inspector.preview")?.accessibilityValue))"
            )
            let image = XCTAttachment(image: hosted.image())
            image.name = "z-lut-modal-\(name)"
            image.lifetime = .keepAlways
            add(image)
            let close = try XCTUnwrap(hosted.element("monitor.assist.close"))
            XCTAssertTrue(close.accessibilityActivate())
            let restored = try await hosted.settle {
                model.assist.configureTool == nil && rails.allSatisfy { hosted.element($0) != nil }
            }
            XCTAssertTrue(restored, "\(name): the retained monitor rail returns after closing")
        }
    }

    /// A2-60: the inspector's look menu is the shared picker, its tabs Nikon's libraries.
    func testTheLookMenuIsTheSharedPickerWithNikonsLibraries() async throws {
        let (_, hosted) = try await lutInspector(size: CGSize(width: 402, height: 874))
        defer { hosted.close() }
        for tab in ["Built-in", "RED", "Custom"] {
            XCTAssertNotNil(
                hosted.element("monitor.lut.tab.\(tab)"),
                "\(tab) is a shared picker tab: \(hosted.labels)")
        }
        let custom = try XCTUnwrap(hosted.element("monitor.lut.tab.Custom"))
        XCTAssertTrue(custom.accessibilityActivate())
        // The shared files tab: the import button over the imported looks.
        let files = try await hosted.settle { !hosted.elements(labeled: "Import .cube").isEmpty }
        XCTAssertTrue(files, "the shared Custom tab lists files under its import: \(hosted.labels)")
    }
}
