import MonitorPresentation
import OpenCineAppKit
import OpenZCineCore
import SwiftUI
import UIKit
import XCTest

@testable import Runner

/// A1-20: portrait fit with three scopes on is the shared floating layout every app gets. Before,
/// Z alone stacked the first two under the picture and hid the third. SIMULATED demo frame.
@MainActor
final class ScopeFitAdoptionTests: XCTestCase {
    private static let scopes: [(OpenZCineCore.MonitorAssistTool, String)] = [
        (.waveform, "waveform"), (.parade, "parade"), (.histogram, "histogram"),
    ]

    func testPortraitFitFloatsEveryActiveScope() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        for (name, size) in [
            ("portrait", CGSize(width: 402, height: 874)),
            ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let model = NativeAppModel(assist: .scratch())
            model.preferences = OperatorPreferences.defaults
            model.preferences.portraitFeedAspect = .fit16x9
            model.startDemoSession()
            for (tool, _) in Self.scopes {
                model.assist.set(tool, visible: true, context: .liveView)
            }
            let panels = model.scopePanels
            let waveOptions = panels.waveform.options
            let paradeOptions = panels.parade.options
            let histogramOptions = panels.histogram.options
            defer {
                panels.waveform.options = waveOptions
                panels.parade.options = paradeOptions
                panels.histogram.options = histogramOptions
            }
            // Use the same store actions as the real panel drag and resize callbacks.
            let canvas = MonitorRect(x: 0, y: 0, width: size.width, height: size.height)
            let slot = MonitorScopeCanvasSlot.forSize(width: size.width, height: size.height)
            func move<Options>(_ store: MonitorScopePanelStore<Options>, index: Int)
            where Options: MonitorScopePanelOptions {
                store.setScale(0.6)
                let point =
                    size.height > size.width
                    ? MonitorScopePoint(
                        x: size.width * 0.5, y: size.height * [0.34, 0.57, 0.8][index])
                    : MonitorScopePoint(
                        x: size.width * [0.24, 0.5, 0.76][index], y: size.height * 0.48)
                store.beginDrag(center: point, slot: slot)
                store.drag(to: point, slot: slot)
                store.endDrag(canvas: canvas)
                XCTAssertEqual(store.storedCenter(in: slot)?.xFraction, point.x / size.width)
                XCTAssertEqual(store.storedCenter(in: slot)?.yFraction, point.y / size.height)
            }
            move(panels.waveform, index: 0)
            move(panels.parade, index: 1)
            move(panels.histogram, index: 2)
            let host = UIHostingController(
                rootView: AnyView(
                    NativeRootContent().environment(model).environment(MediaDeliveryCoordinator())))
            host.safeAreaRegions = []
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            let mock = try XCTUnwrap(model.liveFrameImage ?? UIImage(named: "MockFeed"))
            await model.refreshScopes(from: mock, full: true)
            var labels: [String] = []
            for _ in 0..<150 {
                host.view.layoutIfNeeded()
                labels = Self.labels(window)
                if Self.scopes.allSatisfy({ scope in labels.contains { $0.contains(scope.1) } }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            for _ in 0..<20 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "z-scopes-fit-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            labels = Self.labels(window)
            for (_, scope) in Self.scopes {
                XCTAssertTrue(
                    labels.contains { $0.contains(scope) },
                    "\(name): the \(scope) panel shows: \(labels)")
                let plotLabels = [
                    "Luma waveform", "RGB waveform", "RGB parade", "YRGB parade",
                    "RGB histogram, scale 0 to 100",
                ]
                let matches = Self.elements(window).filter {
                    plotLabels.contains($0.accessibilityLabel ?? "")
                        && ($0.accessibilityLabel ?? "").contains(scope)
                }
                let panel = try XCTUnwrap(
                    matches.first,
                    "\(name): actual \(scope) plot, not its toolbar chip: \(labels)")
                let frame = panel.accessibilityFrame
                XCTAssertGreaterThan(frame.width, 100, "\(name): \(scope) has a real plot")
                XCTAssertGreaterThan(frame.height, 40, "\(name): \(scope) has a real plot")
                XCTAssertTrue(
                    window.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                    "\(name): \(scope) plot \(frame) stays within \(window.bounds)")
            }
        }
    }

    private static func labels(_ root: NSObject) -> [String] {
        elements(root).compactMap(\.accessibilityLabel)
    }

    private static func elements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement, object.accessibilityLabel != nil {
                result.append(object)
            }
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
        visit(root)
        return result
    }
}
