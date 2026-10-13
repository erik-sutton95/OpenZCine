#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED values exercise the actual shared native header, with no camera ownership.
    @MainActor
    final class MonitorPortraitHeaderNativeTests: XCTestCase {
        func testPortraitFormatAndDetailHaveOneGroupedColumnWithSeparateControls() async throws {
            let layout = FieldMonitorLayout(width: 320, height: 956, safeArea: .init(top: 59))
            let fixture = try HeaderFixture(
                width: 320, layout: layout, storage: "375 GB", separateFormat: true)
            defer { fixture.close() }
            let nodes = try await fixture.nodes()
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Format" })
            let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
            XCTAssertGreaterThanOrEqual(
                codec.accessibilityFrame.minY, format.accessibilityFrame.maxY + 1.5,
                "Portrait detail belongs beneath the large primary format, as one grouped readout")
            let paintedFormat = try fixture.controlFrame("format")
            let paintedCodec = try fixture.controlFrame("codec")
            try fixture.attachFrameProof(
                format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                paintedFormat: paintedFormat, paintedCodec: paintedCodec)
            XCTAssertEqual(
                paintedCodec.maxX, paintedFormat.maxX, accuracy: 0.5,
                "Keep the original alignment threshold on actual native control geometry")
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
            XCTAssertTrue(format.accessibilityActivate())
            XCTAssertEqual(fixture.actions.formatCalls, 1)
            XCTAssertTrue(codec.accessibilityActivate())
            XCTAssertEqual(fixture.actions.codecCalls, 1)
        }

        func testLegacyHorizontalControlViolatesTheSameNativeGroupingOracle() async throws {
            let layout = FieldMonitorLayout(width: 320, height: 956, safeArea: .init(top: 59))
            let fixture = try HeaderFixture(
                width: 320, layout: layout, storage: "375 GB", separateFormat: true,
                legacyHorizontal: true)
            defer { fixture.close() }
            let nodes = try await fixture.nodes()
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Format" })
            let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
            let primary = try fixture.controlFrame("format")
            let detail = try fixture.controlFrame("codec")
            try fixture.attachFrameProof(
                format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                paintedFormat: primary, paintedCodec: detail)
            XCTAssertLessThan(
                detail.minY, primary.maxY + 1.5,
                "The old horizontal control must fail the vertical grouping oracle")
            XCTAssertGreaterThan(
                abs(detail.maxX - primary.maxX), 0.5,
                "The old horizontal control must fail the unchanged alignment oracle")
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
        }

        func testPhoneStorageAndPerformanceClearSafeTopAndRemainBeforePower() async throws {
            for width in [CGFloat(320), 360, 440] {
                let layout = FieldMonitorLayout(
                    width: Double(width), height: 956,
                    safeArea: .init(top: 59, leading: 20, trailing: 20))
                let fixture = try HeaderFixture(
                    width: width, layout: layout, storage: "123456789 GB · 100%")
                defer { fixture.close() }
                let nodes = try await fixture.nodes()
                let storage = try XCTUnwrap(
                    nodes.first { $0.accessibilityLabel == "Storage remaining" })
                let link = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Performance" })
                let power = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Power" })
                XCTAssertGreaterThanOrEqual(
                    storage.accessibilityFrame.minY, 67,
                    "Storage must clear the safe top plus breathing room")
                XCTAssertGreaterThanOrEqual(
                    link.accessibilityFrame.minY, 67, "Performance must never enter the cutout")
                XCTAssertGreaterThanOrEqual(
                    power.accessibilityFrame.minY, 67, "Power shares the safe telemetry row")
                XCTAssertLessThanOrEqual(
                    storage.accessibilityFrame.maxX + 8, link.accessibilityFrame.minX + 0.5)
                XCTAssertLessThanOrEqual(
                    link.accessibilityFrame.maxX + 8, power.accessibilityFrame.minX + 0.5)
                XCTAssertEqual(
                    storage.accessibilityValue, "123456789 GB · 100%",
                    "Truncation must retain the full accessible value")
            }
        }
    }

    @MainActor
    private final class HeaderActions {
        var formatCalls = 0
        var codecCalls = 0
        var frames: [String: CGRect] = [:]
    }

    @MainActor
    private final class HeaderFixture {
        let actions: HeaderActions
        let window: UIWindow
        let host: UIHostingController<AnyView>
        private let needsControlFrames: Bool
        private let previousKeyWindow: UIWindow?
        init(
            width: CGFloat, layout: FieldMonitorLayout, storage: String,
            separateFormat: Bool = false, legacyHorizontal: Bool = false
        ) throws {
            needsControlFrames = separateFormat
            let actions = HeaderActions()
            self.actions = actions
            let chrome = MonitorStatusChrome(
                layout: layout, status: .init(recording: false, timecode: "01:23:45:59"),
                storage: {
                    MonitorBoundedReadoutText(storage).accessibilityLabel("Storage remaining")
                        .accessibilityValue(storage)
                },
                format: {
                    if separateFormat {
                        HeaderGroupingControl(
                            legacyHorizontal: legacyHorizontal,
                            primary: {
                                Button {
                                    actions.formatCalls += 1
                                } label: {
                                    MonitorBoundedReadoutText(
                                        "[FX] 6K · 25p", maximumSize: 23, minimumSize: 16
                                    )
                                    .frame(minHeight: 44, alignment: .bottomTrailing)
                                }.buttonStyle(.monitorTapTarget).accessibilityLabel("Format")
                                    .accessibilityValue("[FX] 6K · 25p")
                                    .anchorPreference(
                                        key: HeaderControlAnchorsKey.self, value: .bounds
                                    ) { ["format": $0] }
                            },
                            detail: {
                                Button {
                                    actions.codecCalls += 1
                                } label: {
                                    MonitorBoundedReadoutText(
                                        "R3D NE", maximumSize: 11, minimumSize: 11
                                    )
                                    .frame(minHeight: 44, alignment: .topTrailing)
                                }.buttonStyle(.monitorTapTarget).accessibilityLabel("Codec")
                                    .accessibilityValue("R3D NE")
                                    .anchorPreference(
                                        key: HeaderControlAnchorsKey.self, value: .bounds
                                    ) { ["codec": $0] }
                            })
                    } else {
                        Text("[FX] 6K · 25p")
                    }
                }, color: { EmptyView() }, mode: { EmptyView() },
                link: {
                    Text("25 fps").frame(width: 58, height: 22).accessibilityLabel("Performance")
                })
            host = UIHostingController(
                rootView: AnyView(
                    ZStack(alignment: .topLeading) {
                        chrome.frame(width: CGFloat(layout.status.width)).offset(
                            x: CGFloat(layout.status.x), y: CGFloat(layout.status.y))
                        Text("100% 5/5").frame(width: CGFloat(layout.telemetry.width), height: 22)
                            .accessibilityLabel("Power")
                            .offset(x: CGFloat(layout.telemetry.x), y: CGFloat(layout.telemetry.y))
                    }.frame(width: width, height: 956, alignment: .topLeading)
                        .overlayPreferenceValue(HeaderControlAnchorsKey.self) { anchors in
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: HeaderControlRectsKey.self,
                                    value: anchors.mapValues { proxy[$0] })
                            }
                        }
                        .onPreferenceChange(HeaderControlRectsKey.self) { actions.frames = $0 }
                        .ignoresSafeArea()))
            host.safeAreaRegions = []
            let bounds = CGRect(x: 0, y: 0, width: width, height: 956)
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive },
                "Rendered native proof requires the app's foreground scene")
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }
        func close() {
            actions.frames.removeAll()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        func controlFrame(_ key: String) throws -> CGRect {
            let rect = try XCTUnwrap(actions.frames[key])
            XCTAssertTrue(host.view.window === window)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            return UIAccessibility.convertToScreenCoordinates(rect, in: host.view)
        }
        func attachFrameProof(
            format: CGRect, codec: CGRect, paintedFormat: CGRect, paintedCodec: CGRect
        ) throws {
            func values(_ rect: CGRect) -> [CGFloat] {
                [rect.minX, rect.minY, rect.width, rect.height]
            }
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "AXFormat": values(format), "AXCodec": values(codec),
                    "controlFormat": values(paintedFormat), "controlCodec": values(paintedCodec),
                    "screenScale": window.screen.scale, "alignmentThreshold": 0.5,
                ], options: [.sortedKeys])
            let geometry = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            geometry.name = "SIMULATED B5 native control and AX geometry"
            geometry.lifetime = .keepAlways
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            var complete = false
            let image = renderer.image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(complete, "The actual native window must render the control evidence")
            let picture = XCTAttachment(image: image)
            picture.name = "SIMULATED B5 native grouping window"
            picture.lifetime = .keepAlways
            XCTContext.runActivity(named: "Native geometry and rendered control evidence") {
                activity in
                activity.add(geometry)
                activity.add(picture)
            }
        }
        func nodes() async throws -> [NSObject] {
            for _ in 0..<200 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                let nodes = Self.elements(host.view)
                let hasLabels = ["Storage remaining", "Performance", "Power"].allSatisfy { label in
                    nodes.contains {
                        $0.accessibilityLabel == label && $0.accessibilityFrame.height > 0
                    }
                }
                let hasFrames =
                    !needsControlFrames
                    || ["format", "codec"].allSatisfy { key in
                        guard let rect = actions.frames[key] else { return false }
                        return rect.width > 0 && rect.height > 0 && host.view.window === window
                    }
                if hasLabels && hasFrames {
                    // UIKit attachment and the display transaction must finish before a painted-frame proof.
                    try await Task.sleep(for: .milliseconds(60))
                    return Self.elements(host.view)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "sceneCount": UIApplication.shared.connectedScenes.count,
                    "windowScene": window.windowScene.map { String(describing: $0.activationState) }
                        ?? "none",
                    "windowVisible": !window.isHidden,
                    "nativeControlFrames": actions.frames.mapValues { String(describing: $0) },
                ], options: [.sortedKeys])
            let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            proof.lifetime = .keepAlways
            XCTContext.runActivity(named: "Native fixture readiness failure") { $0.add(proof) }
            throw NSError(domain: "NativeHeaderFixture", code: 1)
        }
        private static func elements(_ object: NSObject) -> [NSObject] {
            if object.accessibilityElementsHidden { return [] }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject], !children.isEmpty {
                return children.flatMap(elements)
            }
            return ((object as? UIView)?.subviews ?? []).flatMap(elements)
        }
    }
    private struct HeaderControlAnchorsKey: PreferenceKey {
        static var defaultValue: [String: Anchor<CGRect>] { [:] }
        static func reduce(
            value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
        ) {
            value.merge(nextValue(), uniquingKeysWith: { _, next in next })
        }
    }
    private struct HeaderControlRectsKey: PreferenceKey {
        static var defaultValue: [String: CGRect] { [:] }
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, next in next })
        }
    }
    private struct HeaderGroupingControl<Primary: View, Detail: View>: View {
        let legacyHorizontal: Bool
        @ViewBuilder let primary: () -> Primary
        @ViewBuilder let detail: () -> Detail
        var body: some View {
            if legacyHorizontal {
                HStack(spacing: 24) {
                    primary()
                    detail()
                }
            } else {
                MonitorPortraitFormatGroup(showsDetail: true, primary: primary, detail: detail)
            }
        }
    }
    // SIMULATED values, real foreground native text drawing. No camera, file or transport ownership.
    extension MonitorPortraitHeaderNativeTests {
        func testStorageShrinksWithinNativeReadableGlyphBoundsAndKeepsFullValue() async throws {
            let value = "123456789 GB · 100%"
            let samples: [(String, CGFloat, CGFloat, CGFloat)] = [
                ("123 GB", 260, 14, 11), (value, 120, 14, 11), (value, 45, 14, 11),
                (value, 260, 11, 11), (value, 260, 14, 14),
            ]
            let host = UIHostingController(
                rootView: ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(samples.indices, id: \.self) { index in
                        let sample = samples[index]
                        MonitorBoundedReadoutText(
                            sample.0, maximumSize: sample.2, minimumSize: sample.3
                        )
                        .foregroundStyle(.white)
                        .frame(width: sample.1, height: 48, alignment: .leading)
                        .offset(x: 16, y: CGFloat(20 + index * 70))
                        .accessibilityLabel("Scale \(index)").accessibilityValue(sample.0)
                    }
                }.frame(width: 320, height: 956, alignment: .topLeading).ignoresSafeArea())
            host.safeAreaRegions = []
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive })
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 956)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            for _ in 0..<100 {
                host.view.layoutIfNeeded()
                if scaleNodes(host.view).filter({
                    $0.accessibilityLabel?.hasPrefix("Scale ") == true
                }).count == samples.count {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(60))
            let nodes = scaleNodes(host.view)
            for index in samples.indices {
                let node = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Scale \(index)" })
                XCTAssertEqual(node.accessibilityValue, samples[index].0)
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.opaque = true
            format.preferredRange = .standard
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cg.bitsPerPixel, 32)
            let data = try XCTUnwrap(cg.dataProvider?.data) as Data
            let scale = image.scale
            func glyphHeight(_ index: Int) -> Int {
                let left = Int(16 * scale)
                let right = Int(32 * scale)
                let top = Int(CGFloat(20 + index * 70) * scale)
                let bottom = Int(CGFloat(68 + index * 70) * scale)
                var occupied: [Int] = []
                for y in top..<bottom {
                    if (left..<right).contains(where: { x in
                        let offset = y * cg.bytesPerRow + x * 4
                        // White is channel-order independent; opaque black and antialiasing remain excluded.
                        return (0..<4).allSatisfy { data[offset + $0] >= 200 }
                    }) {
                        occupied.append(y)
                    }
                }
                return occupied.last.map { $0 - occupied.first! + 1 } ?? 0
            }
            let heights = samples.indices.map(glyphHeight)
            XCTAssertGreaterThan(heights[3], 0)
            XCTAssertGreaterThan(heights[4], heights[3])
            XCTAssertLessThanOrEqual(abs(heights[0] - heights[4]), 1)
            XCTAssertLessThan(heights[1], heights[4])
            for height in heights.prefix(3) {
                // One raster pixel covers independent antialiasing phase, less than 0.5pt at this device scale.
                XCTAssertGreaterThanOrEqual(height, heights[3] - 1)
                XCTAssertLessThanOrEqual(height, heights[4] + 1)
            }
            XCTAssertLessThanOrEqual(abs(heights[2] - heights[3]), 1)
            let picture = XCTAttachment(image: image)
            picture.lifetime = .keepAlways
            picture.name = "SIMULATED native storage font and lower-bound references"
            let metrics = XCTAttachment(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "glyphHeightsPixels": heights,
                        "scale": scale, "referenceSizesPoints": [11, 14],
                    ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            metrics.lifetime = .keepAlways
            XCTContext.runActivity(named: "Native glyph sizing with fixed readable references") {
                $0.add(picture)
                $0.add(metrics)
            }
        }
        private func scaleNodes(_ object: NSObject) -> [NSObject] {
            if object.accessibilityElementsHidden { return [] }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return [] }
            if object.isAccessibilityElement { return [object] }
            if let children = object.accessibilityElements as? [NSObject], !children.isEmpty {
                return children.flatMap(scaleNodes)
            }
            return ((object as? UIView)?.subviews ?? []).flatMap(scaleNodes)
        }
    }

#endif
