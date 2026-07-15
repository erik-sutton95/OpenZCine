import CoreImage
import UIKit
import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {

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

        effects.peaking?.threshold += 0.01
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
    /// The Bluetooth-shutter volume decision: any move off the mid-scale anchor triggers (shutter
    /// remotes send volume-up or volume-down depending on model), but not within the debounce
    /// window after a trigger nor within the echo window after a programmatic re-anchor; the
    /// anchor value itself (our own re-anchor landing) never triggers.
    func testBluetoothShutterTriggerDecision() {
        let t0: TimeInterval = 100
        // Presses in BOTH directions, well clear of both windows → trigger.
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0, lastTriggerAt: 0, lastAnchorAt: 0))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.4375, now: t0, lastTriggerAt: 0, lastAnchorAt: 0))
        // The anchor echo (same value) never triggers.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0))
        // Inside the debounce window after a trigger → suppressed; after it → fires again.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0 + 0.3, lastTriggerAt: t0, lastAnchorAt: t0))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625,
                now: t0 + BluetoothShutterMonitor.debounceInterval + 0.01,
                lastTriggerAt: t0, lastAnchorAt: t0))
        // Right after a programmatic re-anchor, a rise is its echo → suppressed.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: 0, lastAnchorAt: t0))
    }

    /// KVO is the primary detector and the private notification is a rail fallback. On releases
    /// that emit both for one press, the shared debounce must collapse them to one record toggle.
    func testBluetoothShutterDeduplicatesObservationSources() {
        let firstEventAt: TimeInterval = 200
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: firstEventAt, lastTriggerAt: 0, lastAnchorAt: 0))
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625,
                now: firstEventAt + 0.01,
                lastTriggerAt: firstEventAt,
                lastAnchorAt: firstEventAt))
    }

    func testBluetoothShutterReportsWhyVolumeEventsAreIgnored() {
        let t0: TimeInterval = 300
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0),
            .atAnchor)
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: t0, lastAnchorAt: 0),
            .debounced)
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: 0, lastAnchorAt: t0),
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
