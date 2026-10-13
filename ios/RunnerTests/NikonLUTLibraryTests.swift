import OpenCineCameraControls
import OpenZCineCore
import SwiftUI
import UIKit
import XCTest

import class OpenCineCameraVocabulary.CustomLUTStore

@testable import Runner

/// A2-60 and A1-57: Nikon's looks reach the shared picker as typed libraries over the shared
/// LUT store, RED included as a value.
@MainActor
final class NikonLUTLibraryTests: XCTestCase {
    private static let cube =
        "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
    private static let red709 =
        "RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and SOFT_HIGHLIGHT.cube"
    private static let red709High =
        "RWG_Log3G10 to REC709_BT1886 with HIGH_CONTRAST and SOFT_HIGHLIGHT.cube"
    private static let red2020 =
        "RWG_Log3G10 to REC2020_BT1886 with LOW_CONTRAST and SOFT_HIGHLIGHT.cube"

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NikonLUTLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model() -> NativeAppModel {
        let model = NativeAppModel(lutFileStore: CustomLUTStore.nikon(root: root))
        model.preferences = OperatorPreferences.defaults
        return model
    }

    private func write(_ fileName: String, in category: String) throws {
        let folder = root.appendingPathComponent(category, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.cube.write(
            to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    private func libraries(
        _ model: NativeAppModel, filter: NikonLUTPicker.RedOutputFilter = .all,
        onFilter: @escaping (NikonLUTPicker.RedOutputFilter) -> Void = { _ in }
    ) -> [LUTPickerLibrary] {
        var current = filter
        return NikonLUTPicker.libraries(
            model: model,
            redFilter: Binding(
                get: { current },
                set: {
                    current = $0
                    onFilter($0)
                }),
            redDownload: .available)
    }

    /// A2-60: with nothing downloaded, RED is an empty library whose action opens RED's download.
    func testAnEmptyRedLibraryOffersTheDownload() throws {
        let model = model()
        let tabs = libraries(model)
        XCTAssertEqual(tabs.map(\.title), ["Built-in", "RED", "Custom"])
        XCTAssertEqual(tabs.map(\.layout), [.drum, .drum, .files])
        let red = tabs[1]
        XCTAssertTrue(red.entries.isEmpty)
        XCTAssertNil(red.filter)
        let action = try XCTUnwrap(red.empty?.action)
        XCTAssertEqual(action.title, "Download from RED")
        action.perform()
        XCTAssertTrue(model.isRedDownloadPresented)
    }

    /// A2-60: a downloaded RED set stars its default, applies it on a tab switch and keeps the
    /// applied look on the filtered drum.
    func testADownloadedRedSetStarsItsDefaultAndFollowsItsFilter() throws {
        try write(Self.red709High, in: "red")
        try write(Self.red709, in: "red")
        try write(Self.red2020, in: "red")
        let model = model()
        model.refreshRedLUTs()
        model.assistConfiguration.selectedLUT = .builtIn(.log3G10Rec709)

        let red = libraries(model)[1]
        XCTAssertFalse(red.isCurrent)
        XCTAssertEqual(red.markedIDs, [Self.red709])
        XCTAssertEqual(red.entries.first?.id, Self.red709, "the default leads the drum")
        XCTAssertEqual(red.representative?.id, Self.red709)
        XCTAssertEqual(red.filter?.options, ["All", "Rec.709", "Rec.2020"])
        red.select(try XCTUnwrap(red.representative))
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT, .stored(category: .red, fileName: Self.red709))
        XCTAssertTrue(model.assist.isOn(.lut))

        var chosen: NikonLUTPicker.RedOutputFilter?
        libraries(model, onFilter: { chosen = $0 })[1].filter?.selection.wrappedValue = "Rec.2020"
        XCTAssertEqual(chosen, .rec2020)
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT, .stored(category: .red, fileName: Self.red2020),
            "a look outside the new filter snaps to its first look")
        let rec2020 = libraries(model, filter: .rec2020)[1]
        XCTAssertEqual(rec2020.entries.map(\.id), [Self.red2020])
        XCTAssertEqual(rec2020.selectedID, Self.red2020)
        XCTAssertTrue(rec2020.isCurrent)
    }

    /// A1-57: imports and deletes go through the shared store, and a deleted selection falls back.
    func testCustomLooksImportAndClearThroughTheSharedStore() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString)-Look.cube")
        try Self.cube.write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = model()

        try XCTUnwrap(libraries(model)[2].importCube)(source)
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .stored(category: .custom, fileName: source.lastPathComponent))
        let custom = libraries(model)[2]
        XCTAssertEqual(custom.entries.map(\.id), [source.lastPathComponent])
        XCTAssertEqual(custom.selectedID, source.lastPathComponent)
        XCTAssertNotNil(
            model.lutFileStore.cube(category: .custom, fileName: source.lastPathComponent))

        try XCTUnwrap(custom.delete)(try XCTUnwrap(custom.entries.first))
        XCTAssertTrue(model.customLUTs.isEmpty)
        XCTAssertEqual(model.assistConfiguration.selectedLUT, .builtIn(.log3G10Rec709))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("custom/\(source.lastPathComponent)").path))
    }

    /// A2-60: Settings > Look presents the shared sheet: Nikon's tabs over one look comparison
    /// with no Exposure control the picture would ignore (A1-37).
    func testSettingsLookIsTheSharedSheet() async throws {
        let model = model()
        for (name, size) in [
            ("portrait", CGSize(width: 402, height: 874)),
            ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let host = UIHostingController(
                rootView: NikonLUTPicker(embedded: false).environment(model))
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                    $0.activationState == .foregroundActive
                })
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
            var labels: [String] = []
            for _ in 0..<150 {
                host.view.layoutIfNeeded()
                labels = Self.labels(window)
                if labels.contains("50 / 50 split") { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "z-settings-look-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            // The title and toggle both speak the label; count the actual interactive rows.
            let comparisonButtons = Self.elements(window).filter {
                $0.accessibilityLabel == "50 / 50 split" && $0.accessibilityTraits.contains(.button)
            }
            XCTAssertEqual(comparisonButtons.count, 1, "\(name): \(labels)")
            let comparison = try XCTUnwrap(comparisonButtons.first)
            let previousSplit = model.assist.splitComparison
            XCTAssertTrue(comparison.accessibilityActivate())
            XCTAssertEqual(model.assist.splitComparison, !previousSplit)
            XCTAssertTrue(comparison.accessibilityActivate())
            XCTAssertEqual(model.assist.splitComparison, previousSplit)
            XCTAssertFalse(labels.contains("Exposure"), "\(name): \(labels)")
            for tab in ["Built-in", "RED", "Custom", "Done"] {
                XCTAssertTrue(labels.contains(tab), "\(name): \(tab) in \(labels)")
            }
        }
    }

    private static func labels(_ root: NSObject) -> [String] {
        elements(root).compactMap(\.accessibilityLabel)
    }

    private static func elements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        @MainActor func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement, let label = object.accessibilityLabel {
                _ = label
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
