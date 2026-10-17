#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineHostedAccessibility
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED values exercise the actual shared native header, with no camera ownership.
    @MainActor
    final class MonitorPortraitHeaderNativeTests: XCTestCase {
        /// The user's portrait rule for the shared format group: resolution and frame rate on top,
        /// codec and color directly below it, each with its own target. The top edge shared with the
        /// timecode and STBY/REC needs the production row fit, so the shared
        /// `MonitorPortraitHeaderClearanceTests` prove it on the production header.
        func testPortraitFormatAndDetailHaveOneGroupedColumnWithSeparateControls() async throws {
            let layout = FieldMonitorLayout(width: 320, height: 956, safeArea: .init(top: 59))
            let fixture = try HeaderFixture(
                width: 320, layout: layout, storage: "375 GB", separateFormat: true)
            defer { fixture.close() }
            let nodes = try await fixture.nodes()
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Format" })
            let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
            let primaryLine = try fixture.controlFrame("primaryLine")
            let paintedFormat = try fixture.controlFrame("format")
            let paintedCodec = try fixture.controlFrame("codec")
            let ink = try fixture.attachFrameProof(
                format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                paintedFormat: paintedFormat, paintedCodec: paintedCodec)
            // The stack places glyphs independently of its native target floor. The retained
            // failure has touching 44pt targets and a 14px painted gap at 3x.
            XCTAssertGreaterThanOrEqual(
                ink.codec.minY, ink.format.maxY + 1.5,
                "Portrait detail belongs beneath the large primary format, as one grouped readout")
            for target in [format.accessibilityFrame, codec.accessibilityFrame] {
                XCTAssertGreaterThanOrEqual(target.width, 44)
                XCTAssertGreaterThanOrEqual(target.height, 44)
            }
            XCTAssertEqual(
                primaryLine.maxY, paintedFormat.maxY, accuracy: 0.5,
                "The primary text keeps the lower edge of its expanded target")
            XCTAssertLessThanOrEqual(
                ink.primary.minY - primaryLine.minY, Self.directlyBelow,
                "The primary glyphs keep the top of their visible text line")
            XCTAssertGreaterThanOrEqual(
                ink.primary.minY, primaryLine.minY - 0.5,
                "The invisible target expansion does not move the painted text line")
            XCTAssertLessThanOrEqual(
                format.accessibilityFrame.maxY, codec.accessibilityFrame.minY + 0.5,
                "The full primary and detail targets stay independent")
            XCTAssertGreaterThanOrEqual(
                ink.detail.minY, ink.primary.maxY,
                "Codec glyphs belong beneath the large primary glyphs, as one grouped readout")
            XCTAssertLessThanOrEqual(
                ink.detail.minY - ink.primary.maxY, Self.directlyBelow,
                "Codec sits directly under the primary, not a full target lower")
            for target in [format, codec] {
                XCTAssertGreaterThanOrEqual(
                    target.accessibilityFrame.height, 44 - 0.5,
                    "\(target.accessibilityLabel ?? "") keeps its own 44pt target")
            }
            XCTAssertEqual(
                paintedCodec.maxX, paintedFormat.maxX, accuracy: 0.5,
                "Keep the original alignment threshold on actual native control geometry")
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
            XCTAssertTrue(format.accessibilityActivate())
            XCTAssertEqual(fixture.actions.formatCalls, 1)
            XCTAssertEqual(fixture.actions.codecCalls, 0)
            XCTAssertTrue(codec.accessibilityActivate())
            XCTAssertEqual(fixture.actions.codecCalls, 1)
            XCTAssertEqual(fixture.actions.formatCalls, 1)
        }

        func testMovingPrimaryTextFailsTheFixedTargetAnchorOracle() async throws {
            let layout = FieldMonitorLayout(width: 320, height: 956, safeArea: .init(top: 59))
            var fixedTarget = CGRect.zero
            var originalInk = CGRect.zero
            do {
                let reference = try HeaderFixture(
                    width: 320, layout: layout, storage: "375 GB", separateFormat: true)
                defer { reference.close() }
                let nodes = try await reference.nodes()
                let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Format" })
                let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
                fixedTarget = try reference.controlFrame("format")
                let line = try reference.controlFrame("primaryLine")
                XCTAssertEqual(line.maxY, fixedTarget.maxY, accuracy: 0.5)
                originalInk = try reference.attachFrameProof(
                    format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                    paintedFormat: fixedTarget, paintedCodec: reference.controlFrame("codec")
                ).primary
            }
            let displaced = try HeaderFixture(
                width: 320, layout: layout, storage: "375 GB", separateFormat: true,
                primaryTextOffset: 2)
            defer { displaced.close() }
            let nodes = try await displaced.nodes()
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Format" })
            let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
            let target = try displaced.controlFrame("format")
            let line = try displaced.controlFrame("primaryLine")
            for (actual, original) in zip(
                [target.minX, target.minY, target.width, target.height],
                [fixedTarget.minX, fixedTarget.minY, fixedTarget.width, fixedTarget.height]
            ) {
                XCTAssertEqual(
                    actual, original, accuracy: 0.5, "Only the text moves, not its target")
            }
            let ink = try displaced.attachFrameProof(
                format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                paintedFormat: target, paintedCodec: displaced.controlFrame("codec"))
            XCTAssertEqual(
                ink.primary.minY - originalInk.minY, 2, accuracy: 0.5,
                "The negative control moves real native paint")
            XCTAssertEqual(line.maxY - target.maxY, 2, accuracy: 0.5)
            XCTAssertGreaterThan(
                abs(line.maxY - target.maxY), 0.5,
                "The same unchanged anchor oracle rejects displaced text in a fixed target")
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
            let ink = try fixture.attachFrameProof(
                format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                paintedFormat: primary, paintedCodec: detail)
            XCTAssertLessThan(
                ink.detail.minY, ink.primary.maxY,
                "The old horizontal control must fail the vertical grouping oracle")
            XCTAssertGreaterThan(
                abs(detail.maxX - primary.maxX), 0.5,
                "The old horizontal control must fail the unchanged alignment oracle")
            XCTAssertEqual(format.accessibilityValue, "[FX] 6K · 25p")
            XCTAssertEqual(codec.accessibilityValue, "R3D NE")
        }

        func testPaintedGroupingObserverRejectsTheLegacyHorizontalControl() async throws {
            let layout = FieldMonitorLayout(width: 320, height: 956, safeArea: .init(top: 59))
            let fixture = try HeaderFixture(
                width: 320, layout: layout, storage: "375 GB", separateFormat: true,
                legacyHorizontal: true)
            defer { fixture.close() }
            let nodes = try await fixture.nodes()
            let format = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Format" })
            let codec = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Codec" })
            let ink = try fixture.attachFrameProof(
                format: format.accessibilityFrame, codec: codec.accessibilityFrame,
                paintedFormat: fixture.controlFrame("format"),
                paintedCodec: fixture.controlFrame("codec"))
            XCTAssertLessThan(
                ink.codec.minY, ink.format.maxY + 1.5,
                "The same painted-spacing observer must reject the old horizontal controls")
        }

        /// Largest gap, in points, between the primary glyphs and the codec glyphs that still
        /// reads as directly below. The pre-stack column left a full 44pt target between them.
        private static let directlyBelow: CGFloat = 8

        func testCompactPortraitStorageAndPerformanceRemainAdjacentBeforePower() async throws {
            for width in [CGFloat(320), 360, 440] {
                let layout = FieldMonitorLayout(
                    width: Double(width), height: 956,
                    safeArea: .init(top: 59, leading: 20, trailing: 20))
                let fixture = try HeaderFixture(
                    width: width, layout: layout, storage: "123456789 GB")
                defer { fixture.close() }
                let nodes = try await fixture.nodes()
                let storage = try XCTUnwrap(
                    nodes.first { $0.accessibilityLabel == "Storage remaining" })
                let link = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Performance" })
                let power = try XCTUnwrap(nodes.first { $0.accessibilityLabel == "Power" })
                XCTAssertGreaterThanOrEqual(
                    storage.accessibilityFrame.minY, layout.telemetry.y - 13,
                    "Storage stays inside the restored corner band")
                XCTAssertGreaterThanOrEqual(
                    link.accessibilityFrame.minY, layout.telemetry.y - 13,
                    "Performance stays inside the restored corner band")
                XCTAssertGreaterThanOrEqual(
                    power.accessibilityFrame.minY, layout.telemetry.y - 13,
                    "Power shares the safe telemetry row")
                XCTAssertLessThanOrEqual(
                    storage.accessibilityFrame.maxX + 8, link.accessibilityFrame.minX + 0.5)
                XCTAssertLessThanOrEqual(
                    link.accessibilityFrame.maxX + 8, power.accessibilityFrame.minX + 0.5)
                XCTAssertEqual(
                    storage.accessibilityValue, "123456789 GB",
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
            separateFormat: Bool = false, legacyHorizontal: Bool = false,
            primaryTextOffset: CGFloat = 0
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
                                    .anchorPreference(
                                        key: HeaderControlAnchorsKey.self, value: .bounds
                                    ) {
                                        ["primaryLine": $0]
                                    }
                                    .offset(y: primaryTextOffset)
                                    .frame(
                                        minWidth: 44, maxHeight: .infinity,
                                        alignment: legacyHorizontal ? .topTrailing : .bottomTrailing
                                    )
                                }.buttonStyle(.monitorTapTarget).accessibilityLabel("Format")
                                    .accessibilityValue("[FX] 6K · 25p")
                                    .transformAnchorPreference(
                                        key: HeaderControlAnchorsKey.self, value: .bounds
                                    ) { frames, anchor in frames["format"] = anchor }
                            },
                            detail: {
                                Button {
                                    actions.codecCalls += 1
                                } label: {
                                    MonitorBoundedReadoutText(
                                        "R3D NE", maximumSize: 11, minimumSize: 11
                                    )
                                    .frame(
                                        minWidth: 44, maxHeight: .infinity,
                                        alignment: .topTrailing)
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
                        .foregroundStyle(.white).background(Color.black)
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
        @discardableResult
        func attachFrameProof(
            format: CGRect, codec: CGRect, paintedFormat: CGRect, paintedCodec: CGRect
        ) throws -> (format: CGRect, codec: CGRect, primary: CGRect, detail: CGRect) {
            func values(_ rect: CGRect) -> [CGFloat] {
                [rect.minX, rect.minY, rect.width, rect.height]
            }
            let rendererFormat = UIGraphicsImageRendererFormat()
            rendererFormat.scale = window.screen.scale
            rendererFormat.opaque = true
            rendererFormat.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: rendererFormat)
            var complete = false
            let image = renderer.image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(complete, "The actual native window must render the control evidence")
            let ink = (
                format: try inkBounds(in: window.convert(paintedFormat, from: nil), image: image),
                codec: try inkBounds(in: window.convert(paintedCodec, from: nil), image: image)
            )
            let primaryStrip = CGRect(
                x: paintedFormat.minX, y: paintedFormat.minY,
                width: max(0, min(paintedFormat.maxX, paintedCodec.minX) - paintedFormat.minX),
                height: paintedFormat.height)
            let primaryInk = try Self.inkBounds(image, in: primaryStrip)
            let detailInk = try Self.inkBounds(image, in: paintedCodec)
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "AXFormat": values(format), "AXCodec": values(codec),
                    "controlFormat": values(paintedFormat), "controlCodec": values(paintedCodec),
                    "inkFormat": values(ink.format), "inkCodec": values(ink.codec),
                    "screenScale": window.screen.scale, "alignmentThreshold": 0.5,
                    "paintedGapThreshold": 1.5, "targetMinimum": 44,
                    "inkPrimary": values(primaryInk), "inkDetail": values(detailInk),
                ], options: [.sortedKeys])
            let geometry = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            geometry.name = "SIMULATED B5 native control and AX geometry"
            geometry.lifetime = .keepAlways
            let picture = XCTAttachment(image: image)
            picture.name = "SIMULATED B5 native grouping window"
            picture.lifetime = .keepAlways
            XCTContext.runActivity(named: "Native geometry and rendered control evidence") {
                activity in
                activity.add(geometry)
                activity.add(picture)
            }
            return (ink.format, ink.codec, primaryInk, detailInk)
        }
        private func inkBounds(in rect: CGRect, image: UIImage) throws -> CGRect {
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cg.bitsPerPixel, 32)
            XCTAssertEqual(cg.bitsPerComponent, 8)
            guard cg.bitsPerPixel == 32, cg.bitsPerComponent == 8 else {
                throw NSError(domain: "NativeHeaderRaster", code: 1)
            }
            XCTAssertTrue(CGRect(origin: .zero, size: image.size).contains(rect))
            let data = try XCTUnwrap(cg.dataProvider?.data) as Data
            let left = max(0, Int(floor(rect.minX * image.scale)))
            let right = min(cg.width, Int(ceil(rect.maxX * image.scale)))
            let top = max(0, Int(floor(rect.minY * image.scale)))
            let bottom = min(cg.height, Int(ceil(rect.maxY * image.scale)))
            guard left < right, top < bottom else {
                throw NSError(domain: "NativeHeaderRaster", code: 2)
            }
            var first = bottom
            var last = top - 1
            var minX = right
            var maxX = left - 1
            var pixels = 0
            for y in top..<bottom {
                for x in left..<right {
                    let offset = y * cg.bytesPerRow + x * 4
                    // Same opaque-white threshold as the native storage glyph proof below.
                    if (0..<4).allSatisfy({ data[offset + $0] >= 200 }) {
                        first = min(first, y)
                        last = max(last, y)
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        pixels += 1
                    }
                }
            }
            guard first <= last else {
                XCTFail("No native glyph ink in \(rect); an empty capture cannot prove spacing")
                throw NSError(domain: "NativeHeaderRaster", code: 3)
            }
            XCTAssertLessThan(
                Double(pixels) / Double((right - left) * (bottom - top)), 0.8,
                "A solid light frame cannot substitute for native glyphs")
            return CGRect(
                x: CGFloat(minX) / image.scale, y: CGFloat(first) / image.scale,
                width: CGFloat(maxX - minX + 1) / image.scale,
                height: CGFloat(last - first + 1) / image.scale)
        }
        /// Bounds, in points, of the white glyph pixels inside `rect` of an opaque black render.
        private static func inkBounds(_ image: UIImage, in rect: CGRect) throws -> CGRect {
            let cg = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data) as Data
            let scale = image.scale
            let left = max(0, Int(floor(rect.minX * scale)))
            let right = min(cg.width, Int(ceil(rect.maxX * scale)))
            let top = max(0, Int(floor(rect.minY * scale)))
            let bottom = min(cg.height, Int(ceil(rect.maxY * scale)))
            var minX = right
            var minY = bottom
            var maxX = left - 1
            var maxY = top - 1
            for y in top..<max(top, bottom) {
                for x in left..<max(left, right) {
                    let offset = y * cg.bytesPerRow + x * 4
                    // White is channel-order independent; the black ground and shadows are excluded.
                    if (0..<3).allSatisfy({ data[offset + $0] >= 160 }) {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else {
                throw NSError(domain: "NativeHeaderFixture", code: 2)
            }
            return CGRect(
                x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }
        func nodes() async throws -> [NSObject] {
            for _ in 0..<200 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                let nodes = HostedAccessibility.leaves(in: host.view)
                let hasLabels = ["Storage remaining", "Performance", "Power"].allSatisfy { label in
                    nodes.contains {
                        $0.accessibilityLabel == label && $0.accessibilityFrame.height > 0
                    }
                }
                let hasFrames =
                    !needsControlFrames
                    || ["format", "codec", "primaryLine"].allSatisfy { key in
                        guard let rect = actions.frames[key] else { return false }
                        return rect.width > 0 && rect.height > 0 && host.view.window === window
                    }
                if hasLabels && hasFrames {
                    // UIKit attachment and the display transaction must finish before a painted-frame proof.
                    try await Task.sleep(for: .milliseconds(60))
                    return HostedAccessibility.leaves(in: host.view)
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
                if HostedAccessibility.leaves(in: host.view).filter({
                    $0.accessibilityLabel?.hasPrefix("Scale ") == true
                }).count == samples.count {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(60))
            let nodes = HostedAccessibility.leaves(in: host.view)
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
    }

#endif
