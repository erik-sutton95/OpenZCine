import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import SwiftUI
import UIKit
import XCTest

import class OpenCineCameraVocabulary.CustomLUTStore

@testable import OpenZCineCore
@testable import Runner

/// A2-21: each member's LUT is a real bake of that member's own frame through the production
/// `LiveFrameProcessor` graph. Pixels are read back; no toolbar state stands in for a picture.
@MainActor
final class MulticamPictureTests: XCTestCase {
    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
        var spread: Int { max(r, g, b) - min(r, g, b) }
    }

    /// A hand-built solid 8 x 8 sRGB frame.
    private func solid(_ r: Int, _ g: Int, _ b: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image {
            UIColor(
                red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1
            ).setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// The pixel at a unit position, drawn into an sRGB RGBA8 buffer.
    private func pixel(_ image: UIImage?, x: CGFloat = 0.5, y: CGFloat = 0.5) throws -> RGB {
        let cg = try XCTUnwrap(
            image?.cgImage
                ?? image.flatMap { CIImage(image: $0) }.flatMap {
                    CIContext().createCGImage($0, from: $0.extent)
                })
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = (CGFloat(cg.width - 1) * x).rounded()
        let py = (CGFloat(cg.height - 1) * y).rounded()
        context.interpolationQuality = .none
        context.draw(
            cg,
            in: CGRect(
                x: -px, y: -(CGFloat(cg.height - 1) - py), width: CGFloat(cg.width),
                height: CGFloat(cg.height)))
        return RGB(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
    }

    /// Readiness only: the shared hang guard (`HostedCondition`) instead of a short fixed window,
    /// which a loaded hosted runner overran.
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        if !(await HostedCondition.wait(until: condition)) {
            XCTFail("timed out waiting for \(what)")
        }
    }

    private func picture(_ look: MonitorLUT) -> MulticamMemberPicture {
        MulticamMemberPicture(selection: .builtIn(look), fileStore: CustomLUTStore())
    }

    /// Holds the first bake after its inputs are captured, so a test can change the world
    /// under it.
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var used = false
        var isHolding: Bool { continuation != nil }
        func pass() async {
            guard !used else { return }
            used = true
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// SIMULATED original LUT-REPLACE-REFRESH-TEST: the same tile and selected filename
    /// must render the replacement bytes through the existing retained production renderer.
    func testSameNameImportRefreshesMultiviewPixelsWithoutChangingTheSelectedLook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Operator Look.cube")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = CustomLUTStore(root: root.appendingPathComponent("library"))
        let suite = "SIMULATED.MulticamLUT." + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let model = NativeAppModel(lutFileStore: store, assist: .restore(storage: storage))
        let originalPreferences = model.preferences
        let originalConfiguration = model.assistConfiguration
        defer {
            model.preferences = originalPreferences
            model.assistConfiguration = originalConfiguration
        }
        let selection = LUTSelection.stored(category: .custom, fileName: source.lastPathComponent)
        let picture = MulticamMemberPicture(selection: selection, fileStore: store)
        defer { picture.retire() }
        let frame = solid(80, 80, 80)
        func cube(_ rgb: String) -> Data {
            Data(("LUT_3D_SIZE 2\n" + String(repeating: rgb + "\n", count: 8)).utf8)
        }
        try cube("1 0 0").write(to: source)
        try model.importCustomLUT(from: source)
        picture.setLUT(enabled: true)
        picture.accept(frame)
        try await waitUntil("first stored look reaches the tile") { picture.publishedBakes == 1 }
        let first = try pixel(picture.image)
        XCTAssertGreaterThan(first.r, 230, "First cube produces red: \(first)")
        XCTAssertLessThan(first.b, 20, "First cube produces red: \(first)")

        try cube("0 0 1").write(to: source)
        try model.importCustomLUT(from: source)
        picture.accept(frame)
        try await waitUntil("same-name replacement reaches the retained tile") {
            picture.publishedBakes == 2
        }
        let replaced = try pixel(picture.image)
        XCTAssertGreaterThan(replaced.b, 230, "Replacement cube produces blue: \(replaced)")
        XCTAssertLessThan(replaced.r, 20, "Replacement cube produces blue: \(replaced)")
        XCTAssertEqual(picture.lutSelection, selection)
        XCTAssertEqual(model.assistConfiguration.selectedLUT, selection)
        XCTAssertTrue(picture.lutEnabled)
        XCTAssertEqual(store.list(.custom).map(\.fileName), ["Operator Look.cube"])

        try Data("not a cube".utf8).write(to: source)
        XCTAssertThrowsError(try model.importCustomLUT(from: source))
        picture.accept(frame)
        try await waitUntil("rejected replacement preserves the valid tile look") {
            picture.publishedBakes == 3
        }
        let preserved = try pixel(picture.image)
        XCTAssertGreaterThan(preserved.b, 230)
        XCTAssertLessThan(preserved.r, 20)
        XCTAssertEqual(picture.lutSelection, selection)
        XCTAssertEqual(
            try Data(
                contentsOf: root.appendingPathComponent(
                    "library/custom/Operator Look.cube")), cube("0 0 1"))
    }

    func testMembersBakeTheirOwnLooksIndependently() async throws {
        let source = solid(200, 60, 40)
        let a = picture(.nLogRec709)
        let b = picture(.monochrome)
        a.accept(source)
        b.accept(source)
        // Off is the camera's own frame, untouched.
        XCTAssertTrue(a.image === source)
        XCTAssertTrue(b.image === source)

        a.setLUT(enabled: true)
        try await waitUntil("A's bake") { a.publishedBakes == 1 }
        let graded = try pixel(a.image)
        XCTAssertTrue(b.image === source, "B's look is its own: still off")
        // N-Log decode to Rec.709 lifts this warm mid code value and keeps its hue order.
        XCTAssertTrue((215...255).contains(graded.r), "A graded \(graded)")
        XCTAssertTrue(graded.r > graded.g && graded.g >= graded.b, "A graded \(graded)")

        b.setLUT(enabled: true)
        try await waitUntil("B's bake") { b.publishedBakes == 1 }
        let mono = try pixel(b.image)
        XCTAssertLessThanOrEqual(mono.spread, 2, "Mono is neutral: \(mono)")
        XCTAssertTrue((60...140).contains(mono.g), "Mono \(mono)")
        XCTAssertEqual(a.publishedBakes, 1, "B's change never re-bakes A")

        // A selection change re-bakes the latest accepted frame without a new camera frame.
        a.setLUT(selection: .builtIn(.monochrome))
        try await waitUntil("A's re-bake") { a.publishedBakes == 2 }
        let regraded = try pixel(a.image)
        XCTAssertLessThanOrEqual(regraded.spread, 2, "A regraded \(regraded)")
        XCTAssertEqual(a.sourceGeneration, 1)

        b.setLUT(enabled: false)
        XCTAssertTrue(b.image === source, "Off returns B to its own raw frame at once")
        XCTAssertLessThanOrEqual(try pixel(a.image).spread, 2)
    }

    func testTheNewestAcceptedFrameWins() async throws {
        let p = picture(.monochrome)
        p.setLUT(enabled: true)
        p.accept(solid(250, 250, 250))
        p.accept(solid(10, 10, 10))
        // Enabled before any frame: nothing raw is shown, only bakes. Read pixels only once one
        // is published (an empty picture is not a failed readback).
        try await waitUntil("latest frame baked") {
            p.image != nil && (try? self.pixel(p.image).g).map { $0 < 60 } == true
        }
        let shown = try pixel(p.image)
        XCTAssertTrue((0...60).contains(shown.g), "Newest dark frame shown: \(shown)")
        XCTAssertEqual(p.sourceGeneration, 2)
    }

    func testALookChangeDuringABakeDiscardsTheOldLook() async throws {
        let p = picture(.nLogRec709)
        let gate = Gate()
        p.bakeGate = { await gate.pass() }
        p.accept(solid(200, 60, 40))
        p.setLUT(enabled: true)
        try await waitUntil("bake held") { gate.isHolding }
        p.setLUT(selection: .builtIn(.monochrome))
        gate.open()
        try await waitUntil("new look baked") { p.publishedBakes >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(p.publishedBakes, 1, "The N-Log bake was superseded and never shown")
        let shown = try pixel(p.image)
        XCTAssertLessThanOrEqual(shown.spread, 2, "Only the current mono look paints: \(shown)")
    }

    func testRetiredAndResetPicturesDiscardLateBakes() async throws {
        for retire in [true, false] {
            let p = picture(.nLogRec709)
            let gate = Gate()
            p.bakeGate = { await gate.pass() }
            p.accept(solid(200, 60, 40))
            p.setLUT(enabled: true)
            try await waitUntil("bake held") { gate.isHolding }
            if retire { p.retire() } else { p.reset() }
            gate.open()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(p.image, "No late pixels after \(retire ? "retire" : "reset")")
            XCTAssertEqual(p.publishedBakes, 0)
            p.accept(solid(10, 10, 10))
            if retire {
                XCTAssertNil(p.image, "A retired member accepts no frame")
            } else {
                try await waitUntil("a fresh frame on the new link bakes") { p.publishedBakes == 1 }
            }
        }
    }

    /// SIMULATED bodies on the actual root: the LUT tool is offered from member renderers and
    /// its group toggle changes both tiles' pixels; the options panel retires under a cover.
    func testActualStageLUTToolBakesEveryMemberAndPanelsRetireWhenHidden() async throws {
        let model = NativeAppModel()
        let first = DemoMulticamLink(serialNumber: "SIMULATED-lut-A")
        let second = DemoMulticamLink(serialNumber: "SIMULATED-lut-B")
        first.frameInterval = .milliseconds(20)
        second.frameInterval = .milliseconds(20)
        model.multicam.connect = { $0.host == "SIMULATED-A" ? first : second }
        model.multicam.defaultLUT = { .builtIn(.monochrome) }
        model.multicam.begin()
        for (host, serial) in [
            ("SIMULATED-A", "SIMULATED-lut-A"), ("SIMULATED-B", "SIMULATED-lut-B"),
        ] {
            model.multicam.add(
                PTPIPSavedCameraRecord(
                    host: host, displayName: "ZR_\(host)",
                    transport: CameraPath.usbC.legacyTransportLabel,
                    lastSeenAt: nil, serialNumber: serial, path: .usbC),
                reachable: true)
        }
        try await waitUntil("two live members with frames") {
            model.multicam.members.filter { $0.isLive && $0.frame != nil }.count == 2
        }
        model.multicam.presentation.toolsExpanded = true
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let host = UIHostingController(
            rootView: NativeRootContent().environment(model).environment(model.delivery.lifetime))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            model.shell.close()
            model.multicam.end()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func element(_ predicate: (NSObject) -> Bool) -> NSObject? {
            HostedAccessibility.elements(in: host.view).first(where: predicate)
        }
        // Readiness only: the shared hang guard, polled, not a 5 s predicate expectation.
        func settle(_ message: String, _ predicate: @escaping @MainActor () -> Bool) async {
            let settled = await HostedCondition.wait {
                host.view.layoutIfNeeded()
                return predicate()
            }
            XCTAssertTrue(settled, message)
        }
        let lutLabel = "Toggle LUT for all cameras"
        await settle("The LUT tool is offered from the members' renderers") {
            element { $0.accessibilityLabel == lutLabel } != nil
        }
        let members = model.multicam.members.sorted { $0.slot < $1.slot }
        XCTAssertEqual(members.count, 2)
        let rawImages = members.map(\.frame)
        XCTAssertTrue(
            try XCTUnwrap(element { $0.accessibilityLabel == lutLabel }).accessibilityActivate())
        try await waitUntil("both members baked") {
            members.allSatisfy { $0.picture.lutEnabled && $0.picture.publishedBakes > 0 }
        }
        XCTAssertTrue(model.multicam.lutOn)
        for (index, member) in members.enumerated() {
            let baked = try pixel(member.frame, x: 0.3, y: 0.4)
            XCTAssertLessThanOrEqual(
                baked.spread, 2, "Member \(index) shows its mono bake: \(baked)")
            XCTAssertFalse(
                member.frame === rawImages[index], "Member \(index) shows a bake, not its raw frame"
            )
        }
        // Per-member: B off leaves A graded.
        model.multicam.setLUT(enabled: false, on: members[1].id)
        XCTAssertTrue(members[0].picture.lutEnabled)
        XCTAssertFalse(members[1].picture.lutEnabled)
        XCTAssertTrue(model.multicam.lutOn)

        // The options panel is member-scoped and transient: a cover over the stage retires it.
        model.multicam.openLookSettings(slot: 1)
        await settle("Look panel opens for member B") {
            element { HostedAccessibility.identifier($0) == "multiview.lut.panel" } != nil
        }
        XCTAssertEqual(model.multicam.lookEditor, members[1].id)
        let session = NikonPictureLifetimeSession()
        model.shell.borrow(
            ConnectedCamera(
                saved: SavedCamera(
                    id: "SIMULATED-lut-cover",
                    integration: IntegrationID("org.opencapture.nikon-ptp"),
                    advertisedName: "SIMULATED cover", model: "SIMULATED"), session: session)
        ) {}
        await settle("Hiding the stage retires the look panel") { model.multicam.lookEditor == nil }
        model.shell.close()
        await settle("Stage returns without the panel") {
            model.shell.monitor == nil
                && element { HostedAccessibility.identifier($0) == "multiview.lut.panel" } == nil
        }
        XCTAssertTrue(members[0].picture.lutEnabled, "Durable look state survives the cover")
        // The camera settings editor retires under a cover the same way.
        await settle("Camera settings are offered") {
            model.multicam.cameraSettingsSlots.contains(0)
        }
        model.multicam.openCameraSettings(slot: 0)
        await settle("Camera settings open") {
            element { HostedAccessibility.identifier($0) == "multiview.settings.panel" } != nil
        }
        model.shell.borrow(
            ConnectedCamera(
                saved: SavedCamera(
                    id: "SIMULATED-settings-cover",
                    integration: IntegrationID("org.opencapture.nikon-ptp"),
                    advertisedName: "SIMULATED cover", model: "SIMULATED"), session: session)
        ) {}
        await settle("Hiding the stage retires the settings editor") {
            model.multicam.cameraEditor == nil
        }
        model.shell.close()
        XCTAssertEqual(session.commands, 0)
        for link in [first, second] {
            XCTAssertFalse(link.received.contains("start") || link.received.contains("stop"))
        }
    }
}
