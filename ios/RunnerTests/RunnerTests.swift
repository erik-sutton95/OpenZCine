import CoreImage
import SwiftUI
import UIKit
import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {

    @MainActor
    func testGlassChoiceKeepsCinemaRatioOnOneLineAtCompactProWidth() {
        let choice = GlassChoice(title: "2.76:1")
            .frame(width: 48)
        let host = UIHostingController(rootView: choice)

        let fittingSize = host.sizeThatFits(in: CGSize(width: 48, height: 1_000))

        XCTAssertLessThanOrEqual(fittingSize.height, 52)
    }

    func testDemoSettingsTabSelection() {
        XCTAssertEqual(OperatorSettingsTab.demoLaunchTab("assist"), .assist)
        XCTAssertEqual(OperatorSettingsTab.demoLaunchTab("storage"), .storage)
        XCTAssertEqual(OperatorSettingsTab.demoLaunchTab("unknown"), .link)
    }

    func testMediaClipStoreBuildsContainedURLsForSafeBasenames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)

        let mediaURL = try store.localURL(
            cameraID: "../camera serial", filename: "Scene 12 – Göteborg.MOV")
        let thumbnailURL = try store.thumbURL(
            cameraID: "../camera serial", filename: "Scene 12 – Göteborg.MOV")

        XCTAssertTrue(mediaURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertTrue(thumbnailURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertEqual(mediaURL.lastPathComponent, "Scene 12 – Göteborg.MOV")
        XCTAssertEqual(thumbnailURL.lastPathComponent, "Scene 12 – Göteborg.jpg")
    }

    func testMediaClipStoreRejectsTraversalSeparatorsAndControls() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)

        for filename in [
            "../outside.mp4",
            "folder/clip.mov",
            "folder\\clip.mov",
            "clip\n.mp4",
            "clip\0.mp4",
        ] {
            XCTAssertThrowsError(try store.localURL(cameraID: "camera", filename: filename))
            XCTAssertThrowsError(try store.thumbURL(cameraID: "camera", filename: filename))
            XCTAssertThrowsError(
                try store.openForStreaming(cameraID: "camera", filename: filename))
        }
    }

    func testMediaClipStoreRejectsTraversalDeletionAndPreservesOutsideFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appendingPathComponent("outside.mp4")
        try Data("keep".utf8).write(to: outsideURL)
        let store = MediaClipStore(root: root)

        XCTAssertThrowsError(
            try store.removeLocalFile(cameraID: "camera", filename: "../outside.mp4"))
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("keep".utf8))
    }

    func testMediaClipStoreDeletesOnlyValidatedMediaBasename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let url = try store.localURL(cameraID: "camera", filename: "clip.mp4")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: url)

        try store.removeLocalFile(cameraID: "camera", filename: "clip.mp4")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLUTFileStoreDeletesStoredLUTAndRejectsBuiltInDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lut = StoredLUT(fileName: "Operator Look.cube")
        let lutURL = custom.appendingPathComponent(lut.fileName)
        try Data("stored".utf8).write(to: lutURL)
        let store = LUTFileStore(root: root)

        try store.remove(lut, from: .custom)

        XCTAssertFalse(FileManager.default.fileExists(atPath: lutURL.path))
        XCTAssertThrowsError(try store.remove(lut, from: .builtIn)) { error in
            XCTAssertEqual(error as? LUTDeletionError, .builtInProtected)
        }
    }

    func testLUTFileStoreRejectsTraversalDeletionAndPreservesOutsideFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appendingPathComponent("outside.cube")
        try Data("keep".utf8).write(to: outsideURL)
        let store = LUTFileStore(root: root)

        XCTAssertThrowsError(
            try store.remove(StoredLUT(fileName: "../outside.cube"), from: .custom)
        ) { error in
            XCTAssertEqual(error as? LUTDeletionError, .invalidFileName)
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("keep".utf8))
    }

    func testLUTCubeCacheInvalidationRebuildsSameNamedStoredLook() throws {
        let key = "test-stored:\(UUID().uuidString)"
        var buildCount = 0
        func makeCube() -> CubeLUT {
            buildCount += 1
            return MonitorLUT.monochrome.cube(size: 2)
        }

        _ = try XCTUnwrap(LUTCubeCache.cube(forKey: key) { makeCube() })
        _ = try XCTUnwrap(LUTCubeCache.cube(forKey: key) { makeCube() })
        XCTAssertEqual(buildCount, 1)

        LUTCubeCache.invalidate(forKey: key)
        _ = try XCTUnwrap(LUTCubeCache.cube(forKey: key) { makeCube() })

        XCTAssertEqual(buildCount, 2)
    }

    @MainActor
    func testDeletingSelectedStoredLUTChoosesRemainingLookThenBuiltInFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for fileName in ["A.cube", "B.cube"] {
            try Data(fileName.utf8).write(to: custom.appendingPathComponent(fileName))
        }
        let model = NativeAppModel(lutFileStore: LUTFileStore(root: root))
        model.refreshCustomLUTs()
        model.assistConfiguration.selectedLUT = .stored(category: .custom, fileName: "B.cube")

        try model.deleteStoredLUT(StoredLUT(fileName: "B.cube"), from: .custom)

        XCTAssertEqual(model.customLUTs.map(\.fileName), ["A.cube"])
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .stored(category: .custom, fileName: "A.cube"))

        try model.deleteStoredLUT(StoredLUT(fileName: "A.cube"), from: .custom)

        XCTAssertTrue(model.customLUTs.isEmpty)
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .builtIn(.log3G10Rec709))
    }

    @MainActor
    func testDeletingNonselectedStoredLUTPreservesSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for fileName in ["A.cube", "B.cube"] {
            try Data(fileName.utf8).write(to: custom.appendingPathComponent(fileName))
        }
        let model = NativeAppModel(lutFileStore: LUTFileStore(root: root))
        model.refreshCustomLUTs()
        model.assistConfiguration.selectedLUT = .stored(category: .custom, fileName: "B.cube")

        try model.deleteStoredLUT(StoredLUT(fileName: "A.cube"), from: .custom)

        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .stored(category: .custom, fileName: "B.cube"))
    }

    @MainActor
    func testDemoKeyCatcherRegistersStartupAndInDemoCommands() {
        let commands = DemoKeyCatcherView().keyCommands ?? []

        XCTAssertTrue(
            commands.contains {
                $0.input == "o" && $0.modifierFlags == .command
            })
        XCTAssertTrue(
            commands.contains {
                $0.input == "d" && $0.modifierFlags == .command
            })
        XCTAssertFalse(commands.contains { Int($0.input ?? "") != nil })
    }

    @MainActor
    func testStartupShortcutEntersInteractiveDemo() {
        let model = NativeAppModel()

        model.enterInteractiveDemoFromStartupShortcut()

        XCTAssertTrue(model.isDemoSession)
        XCTAssertTrue(model.isMonitorPresented)
        XCTAssertTrue(model.demoUIMode)
        XCTAssertEqual(model.connection, .connected)
        XCTAssertEqual(model.liveViewFocus?.boxes.count, 2)
    }

    @MainActor
    func testStartupShortcutCannotReplaceAnOpenMonitor() {
        let model = NativeAppModel()
        model.isMonitorPresented = true

        model.enterInteractiveDemoFromStartupShortcut()

        XCTAssertFalse(model.isDemoSession)
        XCTAssertFalse(model.demoUIMode)
    }

    @MainActor
    func testDemoKeyRoutesMarketingStillsOneThroughFive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try (1...5).map { number in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image {
                context in
                UIColor(hue: CGFloat(number) / 5, saturation: 1, brightness: 1, alpha: 1)
                    .setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
            }
            let url = directory.appendingPathComponent("\(number).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            return url.path
        }

        let model = NativeAppModel()
        model.startDemoSession()
        model.demoFeedImagePaths = paths
        for number in 1...5 {
            model.liveFrameImage = nil
            model.handleDemoKey(input: "\(number)", hasCommand: false)
            XCTAssertNotNil(model.liveFrameImage)
        }
        model.liveFrameImage = nil
        model.handleDemoKey(input: "6", hasCommand: false)
        XCTAssertNil(model.liveFrameImage)
    }

    @MainActor
    func testDemoKeyCatcherRoutesPrintableDigitsThroughUIKeyInput() {
        let catcher = DemoKeyCatcherView()
        var inputs: [String] = []
        catcher.onKey = { input, hasCommand in
            inputs.append("\(input):\(hasCommand)")
        }

        catcher.insertText("1a28")

        XCTAssertEqual(inputs, ["1:false", "2:false", "8:false"])
    }

    @MainActor
    func testDemoFeedDiscoveryScansOnlyConfiguredDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marketing = root.appendingPathComponent("marketing", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: marketing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedNames = try (1...5).map { number in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image {
                context in
                UIColor(hue: CGFloat(number) / 5, saturation: 1, brightness: 1, alpha: 1)
                    .setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
            }
            let name = "Still \(number).jpg"
            let url = root.appendingPathComponent(name)
            try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: url)
            return name
        }
        try Data("not a demo still".utf8).write(
            to: marketing.appendingPathComponent("marketing.png"))

        let paths = DemoFeedImageDiscovery.imagePaths(in: root.path)

        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent }, expectedNames)
        XCTAssertTrue(
            paths.allSatisfy { URL(fileURLWithPath: $0).deletingLastPathComponent() == root })

        let model = NativeAppModel()
        model.startDemoSession()
        model.demoFeedImagePaths = paths
        var selectedImages: [Data] = []
        for number in 1...3 {
            model.handleDemoKey(input: "\(number)", hasCommand: false)
            selectedImages.append(try XCTUnwrap(model.liveFrameImage?.pngData()))
        }
        XCTAssertEqual(Set(selectedImages).count, 3)
    }

    @MainActor
    func testDemoFeedLaunchDiscoveryFallsBackWhenEnvironmentIsAbsentOrStale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.green.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
        }
        let imageURL = root.appendingPathComponent("Still 1.jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: imageURL)
        let nestedDirectory = root.appendingPathComponent("not-a-feed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(
            to: nestedDirectory.appendingPathComponent("marketing-export.png"))

        for environment in [[:], ["ZC_DEMO_FEED_DIR": root.appendingPathComponent("missing").path]]
        {
            let paths = DemoFeedImageDiscovery.launchImagePaths(
                environment: environment, fallbackDirectoryPath: root.path)
            XCTAssertEqual(paths, [imageURL.path])
        }
    }

    @MainActor
    func testDemoKeyEightTogglesEyeBox() throws {
        let model = NativeAppModel()
        model.enterInteractiveDemoFromStartupShortcut()

        model.handleDemoKey(input: "8", hasCommand: false)

        let withoutEye = try XCTUnwrap(model.liveViewFocus)
        XCTAssertEqual(withoutEye.boxes.count, 1)
        XCTAssertFalse(withoutEye.subjectDetectionActive)
        XCTAssertFalse(withoutEye.trackingAFActive)
        XCTAssertEqual(withoutEye.selectedBoxIndex, 0)

        model.handleDemoKey(input: "8", hasCommand: false)

        let restored = try XCTUnwrap(model.liveViewFocus)
        XCTAssertEqual(restored.boxes.count, 2)
        XCTAssertTrue(restored.subjectDetectionActive)
        XCTAssertEqual(restored.selectedBoxIndex, 1)
    }

    @MainActor
    func testDemoDragOnEyeMovesOnlyEyeAndClampsItInsideFocusBox() throws {
        let model = NativeAppModel()
        model.enterInteractiveDemoFromStartupShortcut()
        let feedSize = CGSize(width: 6048, height: 3400)
        let initial = try XCTUnwrap(model.liveViewFocus)
        let focusBox = initial.boxes[0]
        let eye = initial.boxes[1]

        XCTAssertEqual(
            model.demoFocusDragTarget(
                at: CGPoint(x: eye.centerX, y: eye.centerY), feedSize: feedSize),
            .eye)
        model.demoMoveEyeBox(to: .zero, feedSize: feedSize)

        let moved = try XCTUnwrap(model.liveViewFocus)
        XCTAssertEqual(moved.boxes[0], focusBox)
        let movedEye = moved.boxes[1]
        XCTAssertGreaterThanOrEqual(
            movedEye.centerX - movedEye.width / 2,
            focusBox.centerX - focusBox.width / 2)
        XCTAssertLessThanOrEqual(
            movedEye.centerX + movedEye.width / 2,
            focusBox.centerX + focusBox.width / 2)
        XCTAssertGreaterThanOrEqual(
            movedEye.centerY - movedEye.height / 2,
            focusBox.centerY - focusBox.height / 2)
        XCTAssertLessThanOrEqual(
            movedEye.centerY + movedEye.height / 2,
            focusBox.centerY + focusBox.height / 2)
    }

    @MainActor
    func testFalseColorCurveAlwaysFollowsCodec() {
        let model = NativeAppModel()
        model.preferences.liveViewVisibleAssistTools = [.falseColor]
        model.preferences.playbackVisibleAssistTools = [.falseColor]
        let cases: [(codec: String, curve: ExposureToneCurve)] = [
            ("R3D NE", .redLog3G10),
            ("N-RAW", .nikonNLog),
            ("ProRes RAW HQ", .nikonNLog),
            ("ProRes 422 HQ", .nikonNLog),
            ("H.265 10-bit", .nikonNLog),
        ]
        for value in cases {
            model.cameraState = model.cameraState.updating(codec: value.codec)
            XCTAssertEqual(model.falseColorToneCurve, value.curve)
            XCTAssertEqual(model.liveImageEffects.falseColor?.curve, value.curve)
            XCTAssertEqual(model.playbackImageEffects.falseColor?.curve, value.curve)
        }
    }

    @MainActor
    func testDeletionConfirmMessageIsContextAware() {
        let model = NativeAppModel()

        // A video names the file and never shows stills (RAW+JPEG) wording — the exact
        // regression Erik reported.
        let video = MediaClip(
            cameraID: "cam", filename: "C0001.MOV", handle: 10, storageID: 0x0001_0001,
            sizeBytes: 1, captureDate: "20260724T120000")
        let videoMessage = model.deletionConfirmMessage(for: [video])
        XCTAssertTrue(videoMessage.contains("C0001.MOV"))
        XCTAssertFalse(videoMessage.contains("RAW"))
        XCTAssertFalse(videoMessage.contains("photo"))

        // A lone still: "photo" wording, no companion notes.
        let photo = MediaClip(
            cameraID: "cam", filename: "DSC_0001.JPG", handle: 11, storageID: 0x0001_0001,
            sizeBytes: 1, captureDate: "20260724T120001")
        model.mediaClips = [photo]
        let photoMessage = model.deletionConfirmMessage(for: [photo])
        XCTAssertTrue(photoMessage.contains("photo"))
        XCTAssertFalse(photoMessage.contains("other card"))

        // A backup-mode still lives on both cards (one row, two locations) — the confirm names
        // the cross-card removal.
        var backup = MediaClip(
            cameraID: "cam", filename: "DSC_0002.JPG", handle: 12, storageID: 0x0001_0001,
            sizeBytes: 1, captureDate: "20260724T120002")
        backup.storageLocations = [
            MediaObjectHandle(storageID: 0x0001_0001, handle: 12),
            MediaObjectHandle(storageID: 0x0002_0001, handle: 44),
        ]
        model.mediaClips = [backup]
        XCTAssertTrue(model.deletionConfirmMessage(for: [backup]).contains("other card"))
    }

    @MainActor
    func testDemoStaticRendererAppliesLUTAndFalseColorWithoutMetal() async {
        let encodedSkinHighlight = ExposureToneCurve.redLog3G10.encode(linearLight: 0.18 * 2)
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4)).image { context in
            UIColor(
                red: encodedSkinHighlight, green: encodedSkinHighlight,
                blue: encodedSkinHighlight, alpha: 1
            ).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 4)))
        }
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())

        var lutEffects = LiveImageEffects()
        lutEffects.lut = .builtIn(.log3G10Rec709)
        let lutImage = await renderer.renderStaticFrame(source, effects: lutEffects)

        var falseColorEffects = LiveImageEffects()
        falseColorEffects.falseColor = FalseColorSettings(
            scale: .stops, curve: .redLog3G10)
        let falseColorImage = await renderer.renderStaticFrame(
            source, effects: falseColorEffects)

        XCTAssertEqual(lutImage.size, source.size)
        XCTAssertEqual(falseColorImage.size, source.size)
        let sourcePixel = rgbaPixel(source)
        let lutPixel = rgbaPixel(lutImage)
        let falseColorPixel = rgbaPixel(falseColorImage)
        XCTAssertNotEqual(Array(lutPixel.prefix(3)), Array(sourcePixel.prefix(3)))
        XCTAssertGreaterThan(falseColorPixel[0], falseColorPixel[1] + 40)
        XCTAssertLessThan(abs(Int(falseColorPixel[2]) - Int(falseColorPixel[1])), 15)

    }

    func testReferenceFalseColorRendererUsesLimitZonesAndSmoothHighlightTransition() {
        let red = renderedReferenceFalseColorPixel(
            monitorIRE: 100, scale: .limits, curve: .redLog3G10)
        let yellow = renderedReferenceFalseColorPixel(
            monitorIRE: 96, scale: .limits, curve: .redLog3G10)
        let transition = renderedReferenceFalseColorPixel(
            monitorIRE: 99, scale: .limits, curve: .redLog3G10)
        let purple = renderedReferenceFalseColorPixel(
            monitorIRE: 2, scale: .limits, curve: .redLog3G10)

        XCTAssertGreaterThan(red[0], 180)
        XCTAssertLessThan(red[1], 110)
        XCTAssertGreaterThan(yellow[0], 200)
        XCTAssertGreaterThan(yellow[1], 140)
        XCTAssertLessThan(yellow[2], 100)
        XCTAssertGreaterThan(transition[1], red[1])
        XCTAssertLessThan(transition[1], yellow[1])
        XCTAssertGreaterThan(purple[2], purple[0])
        XCTAssertGreaterThan(purple[0], purple[1])
    }

    func testReferenceFalseColorRendererMapsBothCurvesToSharedIREZones() {
        for curve in ExposureToneCurve.allCases {
            let middleGray = renderedReferenceFalseColorPixel(
                monitorIRE: 42, scale: .ire, curve: curve)
            let skinHighlight = renderedReferenceFalseColorPixel(
                monitorIRE: 66, scale: .ire, curve: curve)
            let clipped = renderedReferenceFalseColorPixel(
                monitorIRE: 100, scale: .ire, curve: curve)

            XCTAssertGreaterThan(middleGray[1], middleGray[0] + 25)
            XCTAssertGreaterThan(middleGray[1], middleGray[2] + 30)
            XCTAssertGreaterThan(skinHighlight[0], skinHighlight[1] + 50)
            XCTAssertGreaterThan(skinHighlight[2], skinHighlight[1] + 20)
            XCTAssertGreaterThan(clipped[0], 170)
            XCTAssertLessThan(clipped[1], 110)
        }
    }

    func testFalseColorReferenceUsesCompactProportionalScales() {
        XCTAssertEqual(FalseColorReference.panelSize, CGSize(width: 264, height: 52))
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let ire = FalseColorReference.segments(scale: .ire, mapping: mapping)

        XCTAssertEqual(ire.count, 9)
        XCTAssertEqual(ire[0].lowerFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(ire[0].upperFraction, 0.05, accuracy: 0.0001)
        XCTAssertEqual(ire[3].lowerFraction, 0.41, accuracy: 0.0001)
        XCTAssertEqual(ire[3].upperFraction, 0.49, accuracy: 0.0001)
        XCTAssertEqual(ire[8].lowerFraction, 0.99, accuracy: 0.0001)
        XCTAssertEqual(ire[8].upperFraction, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(ire[2].lowerFraction, ire[1].upperFraction)

        let stops = FalseColorReference.segments(scale: .stops, mapping: mapping)
        XCTAssertEqual(stops.count, 8)
        XCTAssertEqual(stops.first?.lowerFraction, 0)
        XCTAssertEqual(stops.last?.upperFraction, 1)
        XCTAssertLessThan(stops[0].upperFraction, stops[1].lowerFraction)
        XCTAssertLessThan(stops[1].upperFraction, stops[2].lowerFraction)
        XCTAssertLessThan(stops[2].upperFraction, stops[3].lowerFraction)
        XCTAssertLessThan(stops[4].upperFraction, stops[5].lowerFraction)
        XCTAssertEqual(stops[5].upperFraction, stops[6].lowerFraction, accuracy: 0.0001)
        XCTAssertEqual(stops[6].upperFraction, stops[7].lowerFraction, accuracy: 0.0001)

        let markers = FalseColorReference.stopAxisMarkers(mapping: mapping)
        XCTAssertEqual(markers.map(\.label), ["Min", "−3", "18%", "Skin", "+2", "Max"])
        XCTAssertEqual(
            markers[2].fraction,
            (stops[2].lowerFraction + stops[2].upperFraction) * 0.5,
            accuracy: 0.0001)
    }

    func testAudioMeterPanelUsesQuarterOriginalWidthAndFormatsSensitivity() {
        XCTAssertEqual(AudioMetersPanelMini.panelSize.width, 28)
        XCTAssertEqual(AudioMetersPanelMini.panelSize.height, 168)
        XCTAssertEqual(AudioMetersPanelMini.displayedSensitivity("Auto"), "AUTO")
        XCTAssertEqual(AudioMetersPanelMini.displayedSensitivity("12"), "12")
        XCTAssertEqual(AudioMetersPanelMini.displayedSensitivity("  "), "—")
        XCTAssertEqual(AudioMetersPanelMini.displayedSensitivity(nil), "—")
    }

    /// Live view samples the feed JPEG's raw codes straight through UIKit; playback taps the
    /// composition through Core Image with an explicit BT.709 output space to undo AVFoundation's
    /// working-space conversion. This pins the two pipelines to each other: the same pixels
    /// sampled through both must produce (near-)identical scope readings. [1:1 live/playback]
    func testLiveAndPlaybackScopeTapsReadTheSameCodes() throws {
        // A full-range gradient with per-channel offsets, tagged BT.709 like camera files.
        let width = 256
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x)
                pixels[i + 1] = UInt8((x + 40) % 256)
                pixels[i + 2] = UInt8((x + 90) % 256)
                pixels[i + 3] = 255
            }
        }
        let space = FrameSampling.cameraFileColorSpace
        let data = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: data, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        // Path A — live view: straight UIKit decode into the untagged sampling context.
        let live = try XCTUnwrap(
            FrameSampling.rgbaBuffer(from: UIImage(cgImage: cgImage), maxWidth: 256))
        let liveSamples = ScopeSampler.sample(
            rgba: live.data, width: live.width, height: live.height,
            bytesPerRow: live.bytesPerRow, stride: ScopeAssistSampling.pointStride)

        // Path B — playback: through the composition render context (working sRGB) with the
        // BT.709 output space, exactly like the player's scope tap.
        let ciImage = CIImage(cgImage: cgImage)
        let rendered = try XCTUnwrap(
            MediaLUT.renderContext.createCGImage(
                ciImage, from: ciImage.extent, format: .RGBA8,
                colorSpace: FrameSampling.cameraFileColorSpace))
        let playback = try XCTUnwrap(
            FrameSampling.rgbaBuffer(from: UIImage(cgImage: rendered), maxWidth: 256))
        let playbackSamples = ScopeSampler.sample(
            rgba: playback.data, width: playback.width, height: playback.height,
            bytesPerRow: playback.bytesPerRow, stride: ScopeAssistSampling.pointStride)

        XCTAssertEqual(
            liveSamples.histogramLuma.reduce(0, +), playbackSamples.histogramLuma.reduce(0, +),
            "both taps must sample the same number of pixels")
        // Mean code value per channel must agree to well under one 8-bit code — the round trip
        // through the working space is only float quantization, never a transfer-curve shift.
        func meanCode(_ histogram: [Int]) -> Double {
            let total = histogram.reduce(0, +)
            guard total > 0 else { return 0 }
            let weighted = histogram.enumerated().reduce(0.0) {
                $0 + Double($1.offset * $1.element)
            }
            return weighted / Double(total)
        }
        for (a, b) in [
            (liveSamples.histogramRed, playbackSamples.histogramRed),
            (liveSamples.histogramGreen, playbackSamples.histogramGreen),
            (liveSamples.histogramBlue, playbackSamples.histogramBlue),
            (liveSamples.histogramLuma, playbackSamples.histogramLuma),
        ] {
            XCTAssertEqual(meanCode(a), meanCode(b), accuracy: 0.75)
        }
    }

    func testScopeBundleKeepsRawSamples() {
        let point = ScopePoint(xRatio: 0.5, red: 112, green: 68, blue: 62, luma: 82)
        let samples = ScopeSamples(
            histogramLuma: Array(repeating: 0, count: 256),
            histogramRed: Array(repeating: 0, count: 256),
            histogramGreen: Array(repeating: 0, count: 256),
            histogramBlue: Array(repeating: 0, count: 256),
            points: [point])

        let bundle = ScopeAssistSampling.bundle(
            samples: samples,
            trafficLightsCrushClip: .quarter,
            mapping: ExposureSignalMapping(curve: .redLog3G10))
        // Every scope — vectorscope included — reads the untouched source/log points.
        XCTAssertEqual(bundle.samples, samples)
    }

    func testWaveformAndParadePaletteUsesCalibratedBrightness() {
        XCTAssertEqual(ScopePalette.dataOpacity(brightness: 0), 0)
        XCTAssertEqual(ScopePalette.dataOpacity(brightness: 100), 0.25)
        XCTAssertEqual(ScopePalette.dataOpacity(brightness: 200), 0.5)
    }

    func testVectorscopeDensityRasterUsesRGBAAndFlipsPositiveCrUp() {
        let bins = VectorscopeBins(
            binCount: 2,
            counts: [1, 0, 0, 1],
            redSums: [255, 0, 0, 0],
            greenSums: [0, 0, 0, 0],
            blueSums: [0, 0, 0, 255])
        XCTAssertEqual(
            VectorscopeDensityRasterizer.premultipliedRGBA(bins: bins, brightness: 100),
            [
                0, 0, 0, 0, 0, 0, 255, 255,
                255, 0, 0, 255, 0, 0, 0, 0,
            ])

        let neutral = VectorscopeBins(
            binCount: 1, counts: [1], redSums: [128], greenSums: [128], blueSums: [128])
        XCTAssertEqual(
            VectorscopeDensityRasterizer.premultipliedRGBA(bins: neutral, brightness: 50),
            [127, 127, 127, 127])
        XCTAssertNil(
            VectorscopeDensityRasterizer.premultipliedRGBA(bins: .empty, brightness: 100))
    }

    @MainActor
    func testVectorscopeAloneActivatesScopeSampling() {
        let model = NativeAppModel()
        model.preferences.liveViewVisibleAssistTools = [.vectorscope]
        XCTAssertTrue(model.scopesActive)
    }

    @MainActor
    func testDemoRendererMapsBothCurvesToSharedStopZones() async {
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())
        for curve in ExposureToneCurve.allCases {
            let encoded = curve.encode(linearLight: 0.18 * 2)
            let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4)).image {
                context in
                UIColor(red: encoded, green: encoded, blue: encoded, alpha: 1).setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 4)))
            }
            var effects = LiveImageEffects()
            effects.falseColor = FalseColorSettings(scale: .stops, curve: curve)
            let output = await renderer.renderStaticFrame(source, effects: effects)
            let pixel = rgbaPixel(output)

            XCTAssertGreaterThan(pixel[0], pixel[1] + 35)
            XCTAssertLessThan(abs(Int(pixel[2]) - Int(pixel[1])), 15)
        }
    }

    private func renderedReferenceFalseColorPixel(
        monitorIRE: Double,
        scale: FalseColorScale,
        curve: ExposureToneCurve
    ) -> [UInt8] {
        let mapping = ExposureSignalMapping(curve: curve)
        let encoded = curve.encode(
            linearLight: linearValue(monitorIRE: monitorIRE, mapping: mapping))
        let encodedSource = CIImage(
            color: CIColor(red: encoded, green: encoded, blue: encoded, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        // The compositor's cube is indexed by the display-encoded signal values it receives from
        // live view and playback. Keep this synthetic source encoded too, matching production.
        let source = encodedSource
        var effects = LiveImageEffects()
        effects.falseColor = FalseColorSettings(scale: scale, curve: curve)
        let resolved = ImageEffectsCompositor.resolve(effects) { _ in nil }
        let output = ImageEffectsCompositor.apply(to: source, effects: resolved)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                output,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil)
        }
        return pixel
    }

    private func linearValue(
        monitorIRE: Double, mapping: ExposureSignalMapping
    ) -> Double {
        if monitorIRE <= 0 { return 0 }
        let clip = mapping.curve.decode(encodedValue: mapping.clipNative / 255)
        if monitorIRE >= 100 { return clip }
        var lower = 0.0
        var upper = clip
        for _ in 0..<80 {
            let middle = (lower + upper) * 0.5
            let actual = FalseColorMap.exposureValue(
                linearLuminance: middle, scale: .ire, mapping: mapping)
            if actual < monitorIRE {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (lower + upper) * 0.5
    }

    private func rgbaPixel(_ image: UIImage) -> [UInt8] {
        guard let input = CIImage(image: image) else { return [] }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                input,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil)
        }
        return pixel
    }

    private func rgbaPixel(_ image: CIImage) -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                image,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil)
        }
        return pixel
    }

    /// The paused-frame refresh keys off whether the composition payload actually changed, so the
    /// effects box must report mutations accurately: `true` only for a genuinely new payload,
    /// `false` for repeats (unrelated `assistConfiguration` changes re-set the same effects).
    func testPlaybackEffectsBoxReportsWhetherEffectsChanged() {
        let box = MediaLUT.PlaybackEffectsBox()

        XCTAssertFalse(box.set(effects: ImageEffectsCompositor.ResolvedEffects()))

        var effects = ImageEffectsCompositor.ResolvedEffects()
        effects.peaking = PeakingSettings()
        XCTAssertTrue(box.set(effects: effects))
        XCTAssertFalse(box.set(effects: effects))

        effects.peaking?.sensitivity = .high
        XCTAssertTrue(box.set(effects: effects))

        XCTAssertTrue(box.set(effects: ImageEffectsCompositor.ResolvedEffects()))
    }

    /// The watch relay now encodes the display-baked frame (an RGBAh 16-bit-float bitmap out of the
    /// LUT bake), not a camera JPEG. Guard the encode path end to end for that input: downscale to
    /// the target width and produce a decodable JPEG.
    func testWatchThumbnailEncodesFloatBakedFrame() async throws {
        // Render a gradient through the same context settings as LiveFrameRenderer's bake output.
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAh, .workingColorSpace: space,
        ])
        let gradient = CIFilter(
            name: "CISmoothLinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 1024, y: 576),
                "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3),
                "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.7),
            ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 576))
        let cg = try XCTUnwrap(
            context.createCGImage(
                gradient, from: gradient.extent, format: .RGBAh, colorSpace: space)
        )
        let baked = UIImage(cgImage: cg)

        let encoded = await WatchRelay.thumbnailJPEG(from: baked, maxWidth: 416, quality: 0.3)
        let jpeg = try XCTUnwrap(encoded)
        let decoded = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(decoded.size.width, 416, accuracy: 2)
        XCTAssertEqual(
            decoded.size.height, (416 * 576 / 1024 as CGFloat).rounded(), accuracy: 2)
    }

    /// Metal and demo feeds reach the relay as raw images. Guard the real Watch encode path: it
    /// must apply the selected monitor LUT after adaptive downscaling, then survive JPEG decoding
    /// with pixels materially different from the ungraded log source.
    func testWatchThumbnailAppliesLUTToRawFrameBeforeJPEG() async throws {
        let encodedHighlight = ExposureToneCurve.redLog3G10.encode(linearLight: 0.18 * 2)
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 576)).image {
            context in
            UIColor(
                red: encodedHighlight, green: encodedHighlight, blue: encodedHighlight, alpha: 1
            ).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 1024, height: 576)))
        }
        var effects = LiveImageEffects()
        effects.lut = .builtIn(.log3G10Rec709)
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())

        let rawJPEG = await WatchRelay.thumbnailJPEG(
            from: source, maxWidth: 416, quality: 0.32)
        let gradedJPEG = await WatchRelay.thumbnailJPEG(
            from: source, applying: effects, renderer: renderer,
            maxWidth: 416, quality: 0.32)
        let rawImage = try XCTUnwrap(UIImage(data: try XCTUnwrap(rawJPEG)))
        let gradedImage = try XCTUnwrap(UIImage(data: try XCTUnwrap(gradedJPEG)))

        XCTAssertLessThanOrEqual(try XCTUnwrap(gradedImage.cgImage?.width), 416)
        XCTAssertLessThanOrEqual(try XCTUnwrap(gradedImage.cgImage?.height), 234)
        let rawPixel = rgbaPixel(rawImage)
        let gradedPixel = rgbaPixel(gradedImage)
        let colorDistance = zip(rawPixel.prefix(3), gradedPixel.prefix(3))
            .reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertGreaterThan(colorDistance, 30)
    }
}

extension RunnerTests {
    /// The anchor is the operator's own level, not mid-scale. Arming the shutter used to set every
    /// phone to half volume — remote or not — and drag whatever they were listening to with it.
    /// All the mechanism needs is a step of room each way, which nearly every real setting has.
    func testTheVolumeAnchorLeavesAnOrdinaryLevelExactlyWhereItIs() {
        // Anything with a step of headroom either side is its own anchor: nothing to hear.
        for volume in stride(from: Float(0.0625), through: Float(0.9375), by: 0.0625) {
            XCTAssertEqual(
                BluetoothShutterMonitor.anchor(forCurrentVolume: volume), volume, accuracy: 0.0001,
                "volume \(volume) should not be moved")
        }
        // Only the rails move, and only by the one step a press needs to be visible.
        XCTAssertEqual(
            BluetoothShutterMonitor.anchor(forCurrentVolume: 0), 0.0625, accuracy: 0.0001)
        XCTAssertEqual(
            BluetoothShutterMonitor.anchor(forCurrentVolume: 1), 0.9375, accuracy: 0.0001)
        // Both rails keep room to MOVE, which is the whole reason the anchor exists: a press
        // either way from the anchored value lands somewhere detectably different.
        for rail in [Float(0), Float(1)] {
            let anchored = BluetoothShutterMonitor.anchor(forCurrentVolume: rail)
            XCTAssertGreaterThan(anchored, 0)
            XCTAssertLessThan(anchored, 1)
        }
    }

    /// The decision travels with whatever anchor the session took, not a hardcoded half.
    func testTheTriggerDecisionFollowsTheOperatorsOwnAnchor() {
        let t0: TimeInterval = 100
        let anchor: Float = 0.25
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.25, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor),
            "the anchor's own echo is never a press")
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.3125, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.1875, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor))
        // 0.5 is just a volume now — at this anchor it is a press, not a resting place.
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor))
    }

    /// The Bluetooth-shutter volume decision: any move off the mid-scale anchor triggers (shutter
    /// remotes send volume-up or volume-down depending on model), but not within the debounce
    /// window after a trigger nor within the echo window after a programmatic re-anchor; the
    /// anchor value itself (our own re-anchor landing) never triggers.
    func testBluetoothShutterTriggerDecision() {
        let t0: TimeInterval = 100
        // Presses in BOTH directions, well clear of both windows → trigger.
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.4375, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5))
        // The anchor echo (same value) never triggers.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5))
        // Inside the debounce window after a trigger → suppressed; after it → fires again.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0 + 0.3, lastTriggerAt: t0, lastAnchorAt: t0, anchor: 0.5))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625,
                now: t0 + BluetoothShutterMonitor.debounceInterval + 0.01,
                lastTriggerAt: t0, lastAnchorAt: t0, anchor: 0.5))
        // Right after a programmatic re-anchor, a rise is its echo → suppressed.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: 0, lastAnchorAt: t0, anchor: 0.5))
    }

    /// KVO is the primary detector and the private notification is a rail fallback. On releases
    /// that emit both for one press, the shared debounce must collapse them to one record toggle.
    func testBluetoothShutterDeduplicatesObservationSources() {
        let firstEventAt: TimeInterval = 200
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: firstEventAt, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5
            ))
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625,
                now: firstEventAt + 0.01,
                lastTriggerAt: firstEventAt,
                lastAnchorAt: firstEventAt, anchor: 0.5))
    }

    func testBluetoothShutterReportsWhyVolumeEventsAreIgnored() {
        let t0: TimeInterval = 300
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5),
            .atAnchor)
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: t0, lastAnchorAt: 0, anchor: 0.5),
            .debounced)
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: 0, lastAnchorAt: t0, anchor: 0.5),
            .selfInflicted)
    }

    func testBluetoothShutterRunsOnlyForEnabledActiveFrontLiveView() {
        XCTAssertTrue(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: false, monitorPresented: true, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: false, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: true))
        // Settings / Media / Tool Library covering the monitor must disarm the rocker — a press
        // inside a menu may not start recording.
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: false,
                applicationIsActive: true, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: true,
                applicationIsActive: false, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: false))
    }

    @MainActor
    func testBluetoothShutterFindsNestedSystemVolumeSlider() {
        let volumeView = UIView()
        let container = UIView()
        let slider = UISlider()
        container.addSubview(slider)
        volumeView.addSubview(container)

        XCTAssertIdentical(BluetoothShutterMonitor.firstSlider(in: volumeView), slider)
    }
}

// MARK: - Media favorite / rating sync

extension RunnerTests {
    private func mediaRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func mediaClip(
        _ filename: String, stars: Int? = nil, favorite: Bool = false, captureDate: String = ""
    ) -> MediaClip {
        var clip = MediaClip(
            cameraID: "cam", filename: filename, handle: nil, storageID: nil,
            sizeBytes: 0, captureDate: captureDate)
        clip.starRating = stars
        clip.isFavorite = favorite
        return clip
    }

    /// A shot favorited during a shoot must count under Favorites whether the signal is the
    /// local heart or a camera star — this is exactly the tab's filter predicate.
    func testIsFavoritedCountsLocalHeartOrAnyCameraStar() {
        XCTAssertTrue(mediaClip("A.JPG", favorite: true).isFavorited)
        XCTAssertTrue(mediaClip("B.JPG", stars: 1).isFavorited)
        XCTAssertTrue(mediaClip("C.JPG", stars: 5).isFavorited)
        XCTAssertFalse(mediaClip("D.JPG").isFavorited)
        XCTAssertFalse(mediaClip("E.JPG", stars: 0).isFavorited)

        let clips = [
            mediaClip("A.JPG", favorite: true), mediaClip("B.JPG", stars: 2), mediaClip("D.JPG"),
        ]
        XCTAssertEqual(clips.filter(\.isFavorited).map(\.filename), ["A.JPG", "B.JPG"])
    }

    /// The write-through a rating write performs (`mirrorRatingIntoIndex` → `store.update`)
    /// persists both the star and the derived favorite flag, offline (no camera in this test).
    func testMediaIndexUpdateWritesStarRatingAndFavoriteThrough() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch([mediaClip("DSC_0001.JPG")], cameraID: "cam")

        store.update(cameraID: "cam", filename: "DSC_0001.JPG") {
            $0.starRating = 3
            $0.isFavorite = true
        }

        let row = try XCTUnwrap(
            store.list(cameraID: "cam").first { $0.filename == "DSC_0001.JPG" })
        XCTAssertEqual(row.starRating, 3)
        XCTAssertTrue(row.isFavorite)
        XCTAssertTrue(row.isFavorited)
    }

    /// Instant playback rates a raw handle the index has never seen — the mirror must upsert.
    func testMediaIndexUpdateUpsertsRowWhenClipNotYetIndexed() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)

        store.update(cameraID: "cam", filename: "DSC_0009.JPG") {
            $0.starRating = 5
            $0.isFavorite = true
        }

        let row = try XCTUnwrap(
            store.list(cameraID: "cam").first { $0.filename == "DSC_0009.JPG" })
        XCTAssertEqual(row.starRating, 5)
        XCTAssertTrue(row.isFavorited)
    }

    /// A RAW+JPEG pair mirrors onto the JPEG row the grid renders; the RAW sibling stays untouched.
    func testMediaRatingMirrorsOntoJPEGRowLeavingRawSiblingUntouched() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch([mediaClip("DSC_0001.JPG"), mediaClip("DSC_0001.NEF")], cameraID: "cam")

        store.update(cameraID: "cam", filename: "DSC_0001.JPG") {
            $0.starRating = 4
            $0.isFavorite = true
        }

        let rows = store.list(cameraID: "cam")
        let jpeg = try XCTUnwrap(rows.first { $0.filename == "DSC_0001.JPG" })
        let nef = try XCTUnwrap(rows.first { $0.filename == "DSC_0001.NEF" })
        XCTAssertEqual(jpeg.starRating, 4)
        XCTAssertTrue(jpeg.isFavorited)
        XCTAssertNil(nef.starRating)
        XCTAssertFalse(nef.isFavorited)
    }

    /// Index rows written before `starRating` existed decode to nil (additive Codable) — an
    /// unrated legacy row is not silently promoted into Favorites.
    func testMediaClipDecodesLegacyIndexRowWithoutStarRatingAsNil() throws {
        let legacy = """
            {"cameraID":"cam","filename":"DSC_0001.JPG","sizeBytes":100,\
            "captureDate":"20260724T101500","isFavorite":false,\
            "frameioStatus":"notUploaded","exportStatus":"none"}
            """
        let clip = try JSONDecoder().decode(MediaClip.self, from: Data(legacy.utf8))
        XCTAssertNil(clip.starRating)
        XCTAssertFalse(clip.isFavorited)
    }

    /// Rating-descending sort clusters the highest-starred shots at the top for culling.
    func testRatingSortClustersHighestStarsFirst() {
        let clips = [
            mediaClip("A.JPG", stars: 0), mediaClip("B.JPG", stars: 5),
            mediaClip("C.JPG", stars: 2), mediaClip("D.JPG"),
        ]
        let sorted = MediaClipSorting.sort(clips, order: .rating).map(\.filename)
        XCTAssertEqual(sorted.first, "B.JPG")
        XCTAssertEqual(sorted[1], "C.JPG")
        XCTAssertEqual(Set(sorted.suffix(2)), ["A.JPG", "D.JPG"])
    }

    // MARK: - Fused peaking kernel vs the reference filter chain

    /// The single-pass CIKL detector must reproduce the filter chain exactly — every constant in
    /// `Peaking` was calibrated against the chain, so any divergence here is the kernel being
    /// WRONG, not different. The frame mixes the four cases that matter: hard sharp edges, fine
    /// texture, a defocused (pre-blurred) region, and per-pixel noise dense enough to exercise the
    /// gate's partial band. Checked at every sensitivity because the gains and biases change with
    /// it.
    /// The frame the peaking equivalence tests measure on: sharp strokes and fine texture on the
    /// left half, the same content defocused on the right, and sensor-like noise over all of it —
    /// so a detector that confuses grain for detail, or blur for focus, separates here.
    private func peakingProbeFrame(width w: Int, height h: Int) throws -> CIImage {
        // Scale pinned to 1 — the renderer defaults to the screen scale, which would silently make
        // the frame 3x the stated size and every readback a partial crop of it.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let frame = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
            .image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor(white: 0.3, alpha: 1).cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
                var seed: UInt64 = 0x5_DEEC_E66D
                func rand() -> Double {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return Double(seed >> 33) / Double(UInt64(1) << 31)
                }
                // Sharp strokes and fine texture on the left half.
                for i in 0..<24 {
                    cg.setFillColor(UIColor(white: i % 2 == 0 ? 0.85 : 0.12, alpha: 1).cgColor)
                    cg.fill(CGRect(x: 8 + i * 5, y: 10, width: 2, height: 70))
                    cg.fill(CGRect(x: 8, y: 90 + i * 3, width: 130, height: 1))
                }
                // Noise everywhere, including over the edges.
                for _ in 0..<4_000 {
                    cg.setFillColor(UIColor(white: rand(), alpha: 1).cgColor)
                    cg.fill(
                        CGRect(
                            x: Int(rand() * Double(w - 1)), y: Int(rand() * Double(h - 1)),
                            width: 1, height: 1))
                }
            }
        let source = try XCTUnwrap(CIImage(image: frame, options: [.colorSpace: NSNull()]))
        // Defocus the right half by pre-blurring — the ratio must read it as out of focus.
        let blurredHalf =
            source
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        return blurredHalf.composited(over: source).cropped(to: source.extent)
    }

    /// `Peaking.overlay` is the transcription target for all three Android shells, so it has to be
    /// a transcription of what iOS actually renders. This test is the only thing standing behind
    /// that, and without it "Android matches iOS" is an intention rather than a fact.
    ///
    /// Checked end to end against the composited frame rather than against an intermediate mask, so
    /// every part of the port lands here as pixels: the operator's tap quad, the measured re-blur
    /// weights, the ratio ceiling, the ramps being LINEAR rather than the smoothstep a shader
    /// reaches for by habit, the closing's five-point element, and the order the dark hairline and
    /// the stroke composite in.
    func testSharedCoreReferenceReproducesTheRenderedDetector() throws {
        let w = 320
        let h = 180
        let frame = try peakingProbeFrame(width: w, height: h)

        // Colour management off and float readback: this compares the MATH, so nothing may convert
        // between the two paths. Under the shipping BGRA8 space the chain quantises every one of its
        // ~25 intermediates to 1/255, which is below the detector's own gates.
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ])
        func rendered(_ image: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: w * h * 4)
            context.render(
                image, toBitmap: &out, rowBytes: w * 16,
                bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
            return out
        }

        // `CIContext.render(toBitmap:)` writes buffer row 0 as the image's TOP row — probed, not
        // assumed — which is the same top-down order `Peaking.overlay` reads, so the operator's
        // `+y` tap lands on the same neighbour in both. Getting this backwards would shift the
        // whole overlay by one row, which is exactly the sort of thing this test exists to catch.
        let base = rendered(frame)
        let grey = (0..<(w * h)).map { i in
            (Double(base[i * 4]) + Double(base[i * 4 + 1]) + Double(base[i * 4 + 2])) / 3
        }
        let dark = Peaking.underColor

        for sensitivity in Peaking.Sensitivity.allCases {
            let settings = PeakingSettings(color: .red, sensitivity: sensitivity)
            let actual = rendered(
                ImageEffectsCompositor.applyPeaking(
                    over: frame, source: frame, settings: settings, extent: frame.extent))
            let reference = Peaking.overlay(
                grey: grey, width: w, height: h, sensitivity: sensitivity)
            let tint = settings.color.rgb

            /// The hairline first, then the stroke over it — `composite`'s two blends.
            func expected(_ baseValue: Float, _ darkValue: Double, _ tintValue: Double, _ i: Int)
                -> Double
            {
                let under = reference.under[i]
                let stroke = reference.stroke[i]
                let withUnder = Double(baseValue) * (1 - under) + darkValue * under
                return withUnder * (1 - stroke) + tintValue * stroke
            }

            var painted = 0
            var worst = 0.0
            var worstAt = (0, 0)
            var beyondTolerance = 0
            for i in 0..<(w * h) {
                if reference.stroke[i] > 0.35 { painted += 1 }
                let channels = [
                    expected(base[i * 4], dark.red, tint.0, i),
                    expected(base[i * 4 + 1], dark.green, tint.1, i),
                    expected(base[i * 4 + 2], dark.blue, tint.2, i),
                ]
                for (channel, want) in channels.enumerated() {
                    let delta = abs(Double(actual[i * 4 + channel]) - want)
                    if delta > worst {
                        worst = delta
                        worstAt = (i % w, i / w)
                    }
                    if delta > 2.0 / 255 { beyondTolerance += 1 }
                }
            }
            // The frame must actually paint, or an all-zero overlay would agree with anything.
            XCTAssertGreaterThan(
                painted, 200, "\(sensitivity): probe frame drew almost nothing to compare")
            // 2/255 absorbs float ordering across the graph's passes; a formula divergence moves
            // whole strokes, not a handful of channels on a ramp knee.
            XCTAssertLessThan(
                Double(beyondTolerance) / Double(w * h * 3), 0.001,
                "\(sensitivity): \(beyondTolerance) of \(w * h * 3) channels differ by >2/255, "
                    + "worst \(worst) at \(worstAt) (\(painted) px painted)")
        }
    }

    func testFusedPeakingMatchesFilterChainPixelForPixel() throws {
        try XCTSkipIf(
            !ImageEffectsCompositor.fusedPeakingAvailable,
            "fused peaking disabled on this OS (kernel missing or the runtime self-check found it "
                + "does not reproduce the chain) — chain fallback is in force, nothing to compare")
        let w = 320
        let h = 180
        let mixed = try peakingProbeFrame(width: w, height: h)
        let source = mixed

        // Float working space, deliberately NOT the shipping BGRA8: this test compares the MATH.
        // Under BGRA8 the chain quantises every intermediate to 1/255 across its ~25 passes — the
        // detector's own gates sit below one code value there, which is exactly the precision loss
        // the 8-bit switch was measured to cost — while the fused kernel holds float through its
        // single pass. Their shipping outputs therefore differ legitimately (the kernel is the
        // more faithful one); equality of the formulas is only decidable where both see exact
        // intermediates.
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ])
        func rendered(_ image: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            context.render(
                image, toBitmap: &out, rowBytes: w * 4,
                bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return out
        }

        for sensitivity in Peaking.Sensitivity.allCases {
            let settings = PeakingSettings(color: .red, sensitivity: sensitivity)
            let fused = rendered(
                ImageEffectsCompositor.applyPeaking(
                    over: mixed, source: mixed, settings: settings, extent: source.extent))
            let chain = rendered(
                ImageEffectsCompositor.applyPeakingFilterChain(
                    over: mixed, source: mixed, settings: settings, extent: source.extent))
            var worst = 0
            var differing = 0
            var inRing = 0
            var worstAt = (0, 0)
            let inset = Int(Peaking.edgeInset)
            for i in 0..<fused.count {
                let d = abs(Int(fused[i]) - Int(chain[i]))
                if d > worst {
                    worst = d
                    worstAt = ((i / 4) % w, (i / 4) / w)
                }
                if d > 1 {
                    differing += 1
                    let px = (i / 4) % w
                    let py = (i / 4) / w
                    if px < inset || py < inset || px >= w - inset || py >= h - inset {
                        inRing += 1
                    }
                }
            }
            // ±1/255 allows float-order-of-operations rounding; anything past that on more than a
            // stray pixel means a real formula divergence.
            XCTAssertLessThanOrEqual(
                differing, 8,
                "\(sensitivity): \(differing) channels differ by >1/255 (\(inRing) of them in the "
                    + "\(inset)px inset ring), worst \(worst) at \(worstAt)")
        }
    }

    // MARK: - Live-feed bake resolution

    /// A 16:9 feed on a 2.17:1 panel bakes the WHOLE source at source resolution: fit, never
    /// crop (#115) — the present letterboxes, so no source pixel is ever discarded here.
    func testFeedBakeKeepsSourceResolutionAndItsOwnAspect() {
        let size = MetalFeedFrameBaker.bakeSize(
            source: CGSize(width: 1_024, height: 576),
            drawable: CGSize(width: 2_868, height: 1_320))

        XCTAssertEqual(size, CGSize(width: 1_024, height: 576))
    }

    /// A source wider than the drawable downscales uniformly — the SOURCE's aspect survives,
    /// because the present letterboxes rather than the bake cropping (#115).
    func testFeedBakeDownscalesPreservingTheSourceAspect() {
        let size = MetalFeedFrameBaker.bakeSize(
            source: CGSize(width: 1_024, height: 256),
            drawable: CGSize(width: 800, height: 600))

        XCTAssertEqual(size.width, 800, accuracy: 0.5)
        XCTAssertEqual(size.width / size.height, 1_024.0 / 256.0, accuracy: 0.001)
    }

    /// Demo stills out-resolve the panel. Baking at their size would render pixels that can never
    /// be shown — slower than the drawable-sized path this replaced — so it clamps.
    func testFeedBakeClampsToDrawableWhenSourceOutResolvesThePanel() {
        let drawable = CGSize(width: 1_024, height: 768)

        XCTAssertEqual(
            MetalFeedFrameBaker.bakeSize(
                source: CGSize(width: 4_032, height: 3_024), drawable: drawable),
            drawable)
    }

    /// An empty or infinite source extent (a CI generator with no bounds) falls back to the drawable.
    func testFeedBakeFallsBackToDrawableForADegenerateSource() {
        let drawable = CGSize(width: 1_024, height: 768)

        XCTAssertEqual(
            MetalFeedFrameBaker.bakeSize(source: .zero, drawable: drawable), drawable)
        XCTAssertEqual(
            MetalFeedFrameBaker.bakeSize(source: CGRect.infinite.size, drawable: drawable), drawable
        )
    }

    // MARK: - Hardware JPEG decode

    /// The decoder against a REAL ZR live-view frame, not a synthetic baseline JPEG.
    ///
    /// The MockFeed test below passed while the camera's own frames silently fell back to ImageIO
    /// on device — camera motion-JPEG differs from `UIImage.jpegData` output (subsampling,
    /// restart markers), and a fallback nobody sees means every feature living on the hardware
    /// path (the noise filter) quietly never runs. The peaking corpus carries genuine
    /// LiveViewObjects, so this is the frame class the device actually decodes.
    func testHardwareJPEGDecodeTakesARealZRLiveViewFrame() throws {
        #if targetEnvironment(simulator)
            // The simulator's software VideoToolbox stack is not the device's: it refuses this
            // frame class while macOS accepts the identical bytes (probed step-by-step, forced
            // 420v AND native). Device truth comes from the on-feed debug key, which reports the
            // decode path and the filter's verdict live (`LiveDenoiseSwitch.pipelineReport`).
            throw XCTSkip("simulator VideoToolbox refuses the ZR frame class")
        #else
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // RunnerTests
                .deletingLastPathComponent()  // ios
                .appendingPathComponent("Tests/OpenZCineCoreTests/Fixtures/peaking/zr-sweep-12.bin")
            let object = try Data(contentsOf: url)
            let soi = try XCTUnwrap(
                object.firstRange(of: Data([0xFF, 0xD8, 0xFF])), "no JPEG in the fixture")
            let jpeg = object[soi.lowerBound...]
            let header = try XCTUnwrap(JPEGPixelBufferDecoder.dimensions(of: jpeg))
            let decoder = JPEGPixelBufferDecoder()
            let buffer = try XCTUnwrap(
                decoder.decode(jpeg),
                "the hardware decoder refuses a real ZR live-view frame (\(decoder.report))")
            XCTAssertGreaterThanOrEqual(CVPixelBufferGetWidth(buffer), header.width)
            XCTAssertGreaterThanOrEqual(CVPixelBufferGetHeight(buffer), header.height)
        #endif
    }
    // MARK: - Hardware JPEG decode

    /// The camera's live view is motion JPEG, and `420v` is what a JPEG already is inside. This
    /// decoder is the whole reason the super-resolution input needs no colour conversion — so it
    /// has to actually produce that format, at the right size, with real content in it.
    func testHardwareJPEGDecodeProducesA420vBufferWithRealPixels() throws {
        let image = try XCTUnwrap(UIImage(named: "MockFeed"), "MockFeed asset missing")
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let header = try XCTUnwrap(
            JPEGPixelBufferDecoder.dimensions(of: jpeg), "dimensions must come off the header")

        let buffer = try XCTUnwrap(
            JPEGPixelBufferDecoder().decode(jpeg), "hardware JPEG decode returned nothing")

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            JPEGPixelBufferDecoder.pixelFormat,
            "the decoder must land in the model's own format, not RGB")
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), header.width)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), header.height)

        // A buffer of one constant value is what every failure so far looked like — flat green —
        // so "it decoded" is not the claim; "it decoded a picture" is.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytes = luma.assumingMemoryBound(to: UInt8.self)
        var lowest = UInt8.max
        var highest = UInt8.min
        for row in stride(from: 0, to: rows, by: 8) {
            for column in stride(from: 0, to: CVPixelBufferGetWidthOfPlane(buffer, 0), by: 8) {
                let value = bytes[row * rowBytes + column]
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        XCTAssertGreaterThan(
            Int(highest) - Int(lowest), 16,
            "the luma plane is nearly uniform — this decoded to a flat field, not a frame")
    }

    // MARK: - Feed upscaler availability

    /// The picker lists only what this device can run, and the Lanczos floor is the one thing every
    /// device can — the simulator, which has neither MetalFX nor VideoToolbox super resolution,
    /// lists that alone.
    func testOfferedUpscalersAreAllRunnableAndAlwaysIncludeTheFloor() {
        XCTAssertTrue(FeedUpscaler.supportedOnThisDevice.contains(.off))
        XCTAssertTrue(FeedUpscaler.supportedOnThisDevice.contains(.lanczos))
        for upscaler in FeedUpscaler.supportedOnThisDevice {
            XCTAssertTrue(
                upscaler.isSupportedOnThisDevice, "\(upscaler) is offered but not runnable")
        }
        #if targetEnvironment(simulator)
            XCTAssertEqual(FeedUpscaler.supportedOnThisDevice, [.off, .lanczos])
        #endif
    }

    /// A stored choice outlives the device it was made on. Whatever it names, what comes back is
    /// something this device actually runs — never a setting that reads as active while the
    /// renderer quietly does something else.
    func testAStoredChoiceThisDeviceCannotRunResolvesToOneItCan() {
        XCTAssertTrue(FeedUpscaler.supported(or: nil).isSupportedOnThisDevice)
        for upscaler in FeedUpscaler.allCases {
            XCTAssertTrue(FeedUpscaler.supported(or: upscaler).isSupportedOnThisDevice)
        }
        XCTAssertEqual(FeedUpscaler.supported(or: .lanczos), .lanczos)
    }

    /// An untouched install starts at the floor, on every device — the picker is how an operator
    /// spends GPU on the feed, not something they have to find to stop spending it.
    func testTheDefaultUpscalerIsTheFastFloorEvenWhereBetterOnesExist() {
        XCTAssertEqual(FeedUpscaler.supported(or: nil), .lanczos)
        XCTAssertEqual(FeedUpscaler.lanczos.rawValue, "Fast")
        // A stored choice still wins wherever the device can run it — the default is a starting
        // point, not a cap.
        for upscaler in FeedUpscaler.supportedOnThisDevice {
            XCTAssertEqual(FeedUpscaler.supported(or: upscaler), upscaler)
        }
    }

    // MARK: - Super-resolution input size

    /// The low-latency processor tops out at 960×960, and a Quality-preset ZR feed is 1024×576 —
    /// over the ceiling, which is why it offered no scale factor and the option did nothing. A 6%
    /// shrink clears it and buys a ×2 ML upscale of the result.
    func testSuperResolutionShrinksABakeThatOutsizesTheProcessor() {
        let input = FeedUpscaler.superResolutionInputSize(
            source: (1_024, 576), target: (2_347, 1_320), scale: 0, maximum: (960, 960))

        XCTAssertEqual(input.width, 960)
        XCTAssertEqual(input.height, 540)
        // Uniform: the present letterboxes against this aspect, so it must not change.
        XCTAssertEqual(
            Double(input.width) / Double(input.height), 1_024.0 / 576.0, accuracy: 0.01)
    }

    /// Never an upscale — a source already inside the limit is handed over untouched, and
    /// enlarging before the model would only give it invented detail to sharpen.
    func testSuperResolutionLeavesASourceInsideTheLimitAlone() {
        let input = FeedUpscaler.superResolutionInputSize(
            source: (640, 480), target: (1_280, 960), scale: 2, maximum: (960, 960))

        XCTAssertEqual(input.width, 640)
        XCTAssertEqual(input.height, 480)
    }

    /// Height can be the binding limit as easily as width.
    func testSuperResolutionShrinksToWhicheverDimensionBindsFirst() {
        let input = FeedUpscaler.superResolutionInputSize(
            source: (1_000, 2_000), target: (4_000, 8_000), scale: 0, maximum: (1_440, 1_080))

        XCTAssertEqual(input.height, 1_080)
        XCTAssertEqual(input.width, 540)
    }

    /// A fixed ×4 against a 2347×1320 panel produced 4096×2304 — 75 MB a surface, three deep,
    /// and the drawable queue starved until `nextDrawable` timed out on every frame. The input
    /// has to be sized so the model's OUTPUT lands on the panel, not far past it.
    func testSuperResolutionShrinksTheInputSoAFixedFactorLandsOnThePanel() {
        let input = FeedUpscaler.superResolutionInputSize(
            source: (1_024, 576), target: (2_347, 1_320), scale: 4, maximum: (1_440, 1_080))

        // ×4 of this clears the panel with nothing meaningful left over.
        XCTAssertEqual(Double(input.width) * 4, 2_347, accuracy: 8)
        XCTAssertEqual(Double(input.height) * 4, 1_320, accuracy: 8)
        XCTAssertLessThan(input.width, 1_024)
    }

    /// When the factor cannot reach the panel even from the whole source, there is nothing to
    /// give back — the fit enlarges the remainder and the model gets every pixel available.
    func testSuperResolutionKeepsTheWholeSourceWhenTheFactorCannotReachThePanel() {
        let input = FeedUpscaler.superResolutionInputSize(
            source: (960, 540), target: (2_347, 1_320), scale: 2, maximum: (1_440, 1_080))

        XCTAssertEqual(input.width, 960)
        XCTAssertEqual(input.height, 540)
    }

    // MARK: - Super-resolution scale selection

    /// The model only offers discrete factors, so the one it runs at has to CLEAR the blow-up the
    /// present needs — 1024×576 into a 2868×1320 panel is 2.8×, and 2× would leave Lanczos to
    /// enlarge the model's own output by the rest, which is the whole thing being paid for.
    func testSuperResolutionScaleClearsTheRatioSoTheFitOnlyShrinks() {
        XCTAssertEqual(
            FeedUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2.8), 3)
        XCTAssertEqual(
            FeedUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2), 2)
    }

    /// When nothing on offer clears the ratio the largest gets as close as the processor allows —
    /// a softer last leg beats refusing the model outright.
    func testSuperResolutionScaleFallsToTheLargestOfferedWhenNoneClearsTheRatio() {
        XCTAssertEqual(FeedUpscaler.superResolutionScale(offered: [1.5, 2], ratio: 2.8), 2)
    }

    /// An empty list is the processor saying it does not serve this source size at all.
    func testSuperResolutionScaleIsNilWhenNoFactorsAreOffered() {
        XCTAssertNil(FeedUpscaler.superResolutionScale(offered: [], ratio: 2.8))
    }

    /// Order comes from the processor, not from us — an unsorted list must not pick a factor that
    /// happens to be first.
    func testSuperResolutionScaleDoesNotTrustTheOfferedOrder() {
        XCTAssertEqual(FeedUpscaler.superResolutionScale(offered: [3, 1.5, 2], ratio: 1.6), 2)
    }

    /// A layout animation walks the drawable through a dozen sizes — a device log caught the
    /// MetalFX scaler rebuilt five times across one. Changing factor restarts the processor and
    /// loads an ML model on the draw thread, so a running factor that still clears the ratio is
    /// kept rather than traded down.
    func testSuperResolutionScaleKeepsARunningFactorThatStillClearsTheRatio() {
        XCTAssertEqual(
            FeedUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 1.3, held: 3), 3)
        XCTAssertEqual(
            FeedUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2, held: 2), 2)
    }

    /// It is kept, not pinned: once the panel outgrows what the running factor covers, the model
    /// has to be restarted at one that clears it or the fit goes back to enlarging its output.
    func testSuperResolutionScaleReplacesARunningFactorThatNoLongerClearsTheRatio() {
        XCTAssertEqual(
            FeedUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2.8, held: 2), 3)
    }

    /// The Focus dial is opt-in, and switching the default off must not overrule an operator who
    /// already made the choice — in either direction. The stored key IS the migration: it only
    /// exists once the FOCUS-popup toggle wrote it.
    @MainActor
    func testFocusDialDefaultsOffAndPreservesAnExplicitOperatorChoice() {
        let key = "mfDriveScrubEnabled"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Fresh install / settings reset: nothing stored, so the dial is off — and a new model
        // (the relaunch case) reads the same answer.
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(PreferencesStore.loadMFScrubEnabled())
        XCTAssertFalse(NativeAppModel().mfDriveScrubEnabled)

        // An operator who deliberately switched the dial ON keeps it across the default change.
        PreferencesStore.saveMFScrubEnabled(true)
        XCTAssertTrue(PreferencesStore.loadMFScrubEnabled())
        XCTAssertTrue(NativeAppModel().mfDriveScrubEnabled)

        // …and one who deliberately switched it OFF is never migrated back on.
        PreferencesStore.saveMFScrubEnabled(false)
        XCTAssertFalse(PreferencesStore.loadMFScrubEnabled())
        XCTAssertFalse(NativeAppModel().mfDriveScrubEnabled)
    }

    /// Preference off hides the dial whatever else is true — mode included, since the chrome no
    /// longer gates it. (Visible-when-on needs a live focus mode from a camera; that is the
    /// simulator/hardware check.)
    @MainActor
    func testFocusDialStaysHiddenWhileThePreferenceIsOff() {
        let key = "mfDriveScrubEnabled"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let model = NativeAppModel()
        model.mfDriveScrubEnabled = false
        model.connection = .connected
        model.activePanel = nil

        XCTAssertFalse(model.showsMFDriveScrub)
    }

    /// The camera-values strip must not migrate to the left edge when the assist toolbar is
    /// hidden — an operator who configures DISP 2 with only the values on would see them move as
    /// soon as they left the Edit view, which renders with both bars mounted.
    func testBottomBandKeepsEachStripOnItsOwnSide() {
        XCTAssertEqual(
            MonitorBottomBandAlignment.alignment(photography: false, assistVisible: true),
            .leading, "with both bars up the assist strip fills the space and values land trailing")
        XCTAssertEqual(
            MonitorBottomBandAlignment.alignment(photography: false, assistVisible: false),
            .trailing, "values alone must stay on the right, not slide to the left edge")
        XCTAssertEqual(
            MonitorBottomBandAlignment.alignment(photography: true, assistVisible: false),
            .center, "photography centres its shared strip under the centred feed")
    }

    /// #272: no focus-drive exit path may leave focus commands owned. Cancelling with nothing in
    /// flight, twice, and with no session must all be no-ops that leave the dial usable.
    @MainActor
    func testCancellingAFocusDriveIsAlwaysSafeAndNeverLatches() {
        let model = NativeAppModel()

        model.driveManualFocus(pulses: 400)
        model.cancelManualFocusDrive()
        model.cancelManualFocusDrive()

        // Nothing latched: the dial still reports a usable, re-armable position.
        model.resetMFDriveDial()
        XCTAssertEqual(model.mfDriveNetPulses, 0)
        XCTAssertNil(model.mfDriveAtEnd)
    }

    // MARK: - CODEC bit-depth pair (#276 follow-up)

    /// The Z6III's `MovFileType` enum: H.264 once, H.265 at both depths.
    private static let hevcBothDepthsEnum: [UInt32] = [0x0000_0801, 0x0001_0800, 0x0001_0A00]

    /// The codec drum lists ONE H.265 row, and the depth beside it is whatever the body's own
    /// readback reports — never a remembered UI choice that could disagree with the camera.
    /// Picking a depth writes that exact advertised value; settling the drum on a family carries
    /// the depth the body is currently recording at, and only falls back to the family's lowest
    /// advertised depth when the body's current depth is not one it offers.
    @MainActor
    func testCodecRowsCarryTheirBitDepthAndKeepItAcrossAFamilySwitch() {
        let model = NativeAppModel()
        model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: Self.hevcBothDepthsEnum)

        // One row per family; only the two-variant family offers a depth choice.
        XCTAssertEqual(model.codecOptions, ["H.264", "H.265"])
        XCTAssertEqual(model.codecFamilies.map(\.offersBitDepthChoice), [false, true])
        let hevc = model.codecFamilies[1]
        XCTAssertEqual(hevc.depths.map(\.bitDepthLabel), ["8-bit", "10-bit"])

        // Body on H.265 8-bit: the drum centres on the family row, the pair reads 8-bit.
        model.applyDemoProperty(
            .movieFileType, data: PTPCameraPropertyWrite.fileType(raw: 0x0001_0800).data)
        XCTAssertEqual(model.cameraValue(for: .codec), "H.265")
        XCTAssertEqual(model.activeCodecMode?.bitDepth, 8)

        // Tapping "10-bit" writes the advertised 10-bit value.
        model.applyPickerValue("H.265 10-bit", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.bitDepth, 10)
        XCTAssertEqual(model.cameraValue(for: .codec), "H.265")

        // Settling the drum on a family row carries the depth the body is on: H.264 is 8-bit, so
        // coming back to H.265 records 8-bit, and the pair — not a second row — moves it to 10.
        model.applyPickerValue("H.264", for: .codec)
        XCTAssertEqual(model.cameraValue(for: .codec), "H.264")
        model.applyPickerValue("H.265", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.raw, 0x0001_0800)
        model.applyPickerValue("H.265 10-bit", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.raw, 0x0001_0A00)
    }

    /// A depth the body is on but does not advertise for the codec being selected must not be
    /// carried across — the row falls back to that family's lowest advertised depth instead of
    /// writing a combination the body never offered.
    @MainActor
    func testAFamilyThatCannotHoldTheCurrentDepthFallsBackToItsLowest() {
        let model = NativeAppModel()
        // R3D NE is 12-bit only; H.265 is offered at 8 and 10.
        model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: [0x0031_0C03, 0x0001_0800, 0x0001_0A00])
        model.applyDemoProperty(
            .movieFileType, data: PTPCameraPropertyWrite.fileType(raw: 0x0031_0C03).data)
        XCTAssertEqual(model.activeCodecMode?.bitDepth, 12)

        model.applyPickerValue("H.265", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.raw, 0x0001_0800)
    }

    /// A body that advertises one variant of a codec gets no depth buttons at all — a dead button
    /// for a depth the body cannot record is exactly what this feature must not ship.
    @MainActor
    func testASingleVariantCodecOffersNoBitDepthChoice() {
        let model = NativeAppModel()
        model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: [0x0031_0A03, 0x0002_0C02, 0x0001_0A01])
        XCTAssertEqual(model.codecOptions, ["R3D NE", "N-RAW", "H.265"])
        XCTAssertTrue(model.codecFamilies.allSatisfy { !$0.offersBitDepthChoice })
    }

    // MARK: - Picker option sourcing (#274)

    /// Every function picker must name the PTP property whose descriptor drives its drum. A nil
    /// here is a picker silently rendering the app's fixed union again — the whole #274 defect.
    /// (Which property each one names is asserted in the shared core's `PickerOptionPolicyTests`,
    /// where the descriptor decoders live; this target does not link the core module.)
    func testEveryFunctionPickerNamesItsDescriptorProperty() {
        let sourced: [(CameraPicker, Int)] = [
            (.mode, 0), (.stillMode, 0), (.stillMode, 1), (.stillDrive, 0),
            (.stillFocus, 0), (.stillFocus, 1), (.stillFocus, 2),
            (.stillFlash, 0), (.stillMeter, 0), (.stillQuality, 0), (.stillPicture, 0),
            (.focus, 0), (.focus, 1), (.focus, 2),
        ]
        for (picker, mode) in sourced {
            XCTAssertNotNil(
                picker.optionProperty(forMode: mode),
                "\(picker.rawValue) mode \(mode) is not sourced from the camera")
        }
        // Focus mode / area / subject are three separate Nikon settings, so the three tabs must
        // read three different properties — never collapsed onto one.
        for picker: CameraPicker in [.focus, .stillFocus] {
            let properties = (0...2).compactMap { picker.optionProperty(forMode: $0) }
            XCTAssertEqual(Set(properties).count, 3, "\(picker.rawValue) conflates its focus tabs")
        }
        // The Drive picker's two Timer tabs are app state, not camera enums.
        XCTAssertNil(CameraPicker.stillDrive.optionProperty(forMode: 1))
        XCTAssertNil(CameraPicker.stillDrive.optionProperty(forMode: 2))
    }

    /// The fallback a body without a descriptor gets must be conservative: no user banks (the
    /// reported Zf), and the drive ladder in the body's release order (the reported Z6III).
    func testPickerFallbackLaddersAreConservativeAndInBodyOrder() {
        for picker: CameraPicker in [.mode, .stillMode] {
            XCTAssertFalse(
                picker.options.contains { $0.hasPrefix("U") },
                "\(picker.rawValue) invents user banks without a descriptor")
        }
        XCTAssertEqual(CameraPicker.stillMode.modes[0].options, ["Auto", "P", "S", "A", "M"])
        XCTAssertEqual(
            CameraPicker.stillDrive.options,
            [
                "Single", "Continuous L", "Continuous H", "Continuous H+", "C15", "C30", "C60",
                "C120",
            ]
        )
    }

    /// Focus AREA and subject DETECTION are separate Nikon settings, and neither tab may wear the
    /// other's name. The core suite proves these exact labels encode back to their own raw values.
    func testFocusAreaLabelsNameTheBodysSettings() {
        for picker: CameraPicker in [.focus, .stillFocus] {
            let areas = picker.modes[1].options
            let subjects = picker.modes[2].options
            // The bare forms are the reported confusion: "Subject" reads as the detection tab and
            // "3D" is not what the body calls 3D-tracking.
            XCTAssertFalse(areas.contains("Subject"), "\(picker.rawValue) area tab says 'Subject'")
            XCTAssertFalse(areas.contains("3D"), "\(picker.rawValue) area tab says bare '3D'")
            // Only "Auto" legitimately names a position in both spaces.
            XCTAssertTrue(Set(areas).intersection(subjects).isSubset(of: ["Auto"]))
        }
        // Each chrome's own tracking position, spelled the way the body spells it.
        XCTAssertTrue(CameraPicker.focus.modes[1].options.contains("Subject tracking"))
        XCTAssertTrue(CameraPicker.stillFocus.modes[1].options.contains("3D tracking"))
    }
}

/// The watch feed's encoder. HEIC carries roughly JPEG's perceived quality in half the bytes,
/// which is what buys back the cost of the larger frames.
@MainActor
final class WatchFrameEncodingTests: XCTestCase {
    private func solidImage(width: Int = 64, height: Int = 36) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// HEIC, not JPEG. An ISOBMFF file names its box type at bytes 4..8 ("ftyp"), where a JPEG
    /// opens 0xFFD8. Checking the container rather than "some bytes came back" is the point: the
    /// JPEG fallback is silent by design, so it would look identical to success at the call site,
    /// and shipping the fallback everywhere would quietly undo the whole change.
    func testFramesEncodeAsHeic() throws {
        let data = try XCTUnwrap(WatchRelay.encodedFrameData(solidImage(), quality: 0.5))
        XCTAssertGreaterThan(data.count, 0)
        let isJPEG =
            data.count >= 2 && data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
        XCTAssertFalse(isJPEG, "still JPEG — the HEIC destination silently fell back")
        let ftyp = data.count >= 8 ? Array(data[(data.startIndex + 4)..<(data.startIndex + 8)]) : []
        XCTAssertEqual(ftyp, Array("ftyp".utf8), "not an ISOBMFF container")
    }

    /// Quality has to actually reach the encoder. A parameter accepted and ignored would leave the
    /// feed exactly as compressed as before while the ladder claims otherwise.
    func testQualityReachesTheEncoder() throws {
        // A gradient, not a flat fill: a solid colour compresses to nearly the same size at any
        // quality, so it would pass this test without the parameter doing anything.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 72)).image { ctx in
            let colors = [UIColor.black.cgColor, UIColor.white.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                ctx.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 128, y: 72), options: [])
            }
        }
        let low = try XCTUnwrap(WatchRelay.encodedFrameData(image, quality: 0.1))
        let high = try XCTUnwrap(WatchRelay.encodedFrameData(image, quality: 0.9))
        XCTAssertGreaterThan(high.count, low.count, "quality is not reaching the encoder")
    }
}

extension RunnerTests {
    /// The app target compiles the shared core from its OWN file references, so a rule the SPM
    /// suite proves is not thereby proven here — and the store the app writes through is this
    /// target's. Two routers on different subnets are two setups.
    func testTwoRoutersOnDifferentSubnetsStaySeparateInTheAppTarget() {
        let records = PTPIPSavedCameraRecords.canonicalized([
            PTPIPSavedCameraRecord(
                host: "10.99.0.20", displayName: "ZR_6002199", transport: "Wi-Fi",
                lastSeenAt: Date(timeIntervalSince1970: 1), serialNumber: "6002199",
                path: .infrastructure(networkName: nil)),
            PTPIPSavedCameraRecord(
                host: "192.168.129.66", displayName: "ZR_6002199", transport: "Wi-Fi",
                lastSeenAt: Date(timeIntervalSince1970: 2), serialNumber: "6002199",
                path: .infrastructure(networkName: nil)),
        ])
        XCTAssertEqual(records.count, 2, "hosts: \(records.map(\.host))")
    }
}

extension RunnerTests {
    /// Failure copy is matched on the TEXT of a status, which carries no idea which path produced
    /// it — so a cable failure used to be answered with "check Wi-Fi", sending the operator to
    /// inspect a radio the attempt never used.
    func testCableFailuresAreNotToldToCheckWiFi() {
        let timedOut = "PTP-IP connect timed out"
        XCTAssertTrue(
            StartupConnectionCopy.friendly(timedOut, path: .usbC).contains("Check the cable"))
        XCTAssertTrue(
            StartupConnectionCopy.friendly(timedOut, path: .hdmiCapture).contains("Check the cable")
        )

        // Every path with a network keeps the Wi-Fi wording, including an unknown one.
        for network in [CameraPath.Kind.cameraAccessPoint, .infrastructure, .phoneHotspot] {
            XCTAssertTrue(
                StartupConnectionCopy.friendly(timedOut, path: network).contains("Check Wi"),
                "\(network) should still be told to check Wi-Fi")
        }
        XCTAssertTrue(StartupConnectionCopy.friendly(timedOut).contains("Check Wi"))
    }

    /// The wizard's step headings describe the SHAPE of the wizard, not what any one path does in
    /// it — "Set up the network" over a cable is a different instruction from the one on screen.
    func testEveryPathsNetworkStepIsTitledForWhatItActuallyDoes() {
        // The generic title survives only where it is still true.
        XCTAssertEqual(
            NativeAppModel.FirstPairWizardStep.connectNetwork.title, "Set up the network")
        XCTAssertEqual(NativeAppModel.FirstPairWizardStep.discoverAndPair.title, "Find and pair")
        // HDMI never visits the network step; every other path does, and each needs its own words.
        XCTAssertFalse(
            NativeAppModel.FirstPairWizardStep.sequence(
                transport: .hdmiCapture, skipsPermissions: false
            ).contains(.connectNetwork))
        // Camera-AP pairing ends at the network step — nothing to find afterwards.
        XCTAssertFalse(
            NativeAppModel.FirstPairWizardStep.sequence(
                transport: .cameraAccessPoint, skipsPermissions: false
            ).contains(.discoverAndPair))
    }
}
