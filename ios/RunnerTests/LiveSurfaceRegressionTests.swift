import Observation
import OpenCineAppKit
import OpenCineApple
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineCore
import OpenCineHostedAccessibility
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
        var identifiers: [String] {
            elements().map(Self.identifier).filter { !$0.isEmpty }.sorted()
        }

        private static func identifier(_ object: NSObject) -> String {
            HostedAccessibility.identifier(object) ?? ""
        }

        private func elements() -> [NSObject] {
            HostedAccessibility.elements(in: host.view).filter(\.isAccessibilityElement)
        }
    }

    private func monitor(_ model: NativeAppModel) -> some View {
        GeometryReader { proxy in
            NikonMonitorShell(
                context: LiveViewLayoutContext(
                    proxy: proxy, deviceOrientation: .unknown, screenWidth: nil))
        }
        .environment(model).environment(model.delivery)
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
                // The state `startHDMIMonitorSession` leaves once a capture card streams, staged
                // without a UVC device (the simulator has none) and so without its wait for one.
                model.isMonitorPresented = true
                model.connection = .connected
                model.videoSource = .hdmiCapture
                model.hdmiCaptureState = .streaming(
                    deviceName: "SIMULATED capture", format: "1920×1080 @30")
            case "relay":
                // The state `joinRelay` leaves, without a broadcast to join.
                model.videoSource = .relay
                model.isMonitorPresented = true
                model.connection = .connected
            default:
                model.startDemoSession()
            }
            let hosted = try Hosted(
                NativeRootContent().environment(model).environment(model.delivery))
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
            XCTAssertTrue(
                coverShown, "\(source): Settings must render its cover: \(hosted.identifiers)")

            model.activePanel = nil
            let backToLive = try await hosted.settle {
                hosted.element(prefix: "monitor.settings.tab.") == nil
                    && hosted.element("monitor.system.settings") != nil
            }
            XCTAssertTrue(
                backToLive,
                "\(source): closing Settings must return to the monitor: \(hosted.identifiers)")
            // A connected monitor starts no camera discovery when the root appears: no sweep of
            // the machine's real network runs behind it and takes the monitor down.
            XCTAssertEqual(
                model.connection, .connected, "\(source): no discovery may run behind the monitor")
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

    /// A same-host recovery held a stills body but drew video chrome (STBY, red ring, GB) until
    /// a re-read that never came. The capture mode survives the recovery; a disconnect clears it.
    func testASameHostRecoveryKeepsTheStillsMode() {
        let model = NativeAppModel()
        model.startDemoSession()
        model.applyDemoProperty(.liveViewSelector, data: Data([0]))
        model.applyDemoProperty(.exposureRemaining, data: Data([0xED, 0x1B, 0, 0]))
        XCTAssertTrue(model.isPhotographyMode)

        model.clearCameraSessionState(resetConnection: false, preserveMonitorSurface: true)
        XCTAssertTrue(model.isPhotographyMode, "recovery keeps the held body in stills")
        XCTAssertEqual(model.cameraPropertySnapshot.shotsRemaining, 7149)
        XCTAssertNil(model.cameraPropertySnapshot.iso, "every other value waits for its re-read")

        model.clearCameraSessionState(resetConnection: true)
        XCTAssertFalse(model.isPhotographyMode, "a disconnect leaves no mode for the next body")
        XCTAssertNil(model.cameraPropertySnapshot.shotsRemaining)
    }

    /// ZT-04: with two cards the counter shows the stills card alone. A same-host recovery keeps
    /// that figure, and the next ExposureRemaining read (both cards under overflow) must not
    /// bring the summed count back.
    func testARecoveryKeepsTheStillsCardCountNotTheSummedOne() {
        let readout = NikonCardSlotReadout(
            cards: [
                NikonStorageCard(
                    storageID: 0x0001_0001, slot: 1,
                    info: PTPStorageInfo(
                        totalCapacityBytes: 512_000_000_000, freeSpaceBytes: 400_000_000_000,
                        freeSpaceInImages: 10_141)),
                NikonStorageCard(
                    storageID: 0x0002_0001, slot: 2,
                    info: PTPStorageInfo(
                        totalCapacityBytes: 512_000_000_000, freeSpaceBytes: 400_000_000_000,
                        freeSpaceInImages: 10_120)),
            ],
            primarySlot: NikonScalarPropertyDescriptor.parse(
                Data([0x56, 0xD1, 0x02, 0x00, 1, 0, 1, 2, 2, 0, 0, 1]),
                property: PTPPropertyCode.primarySlot.rawValue, valueByteCount: 1))
        let live = PTPCameraPropertySnapshot(captureSelector: .photo)
            .applying(property: .exposureRemaining, data: Data(ByteCoding.uint32LE(20_261)))
            .applyingCardSlots(readout)
        XCTAssertEqual(live.shotsRemaining, 10_120)

        let held = NativeAppModel.heldCaptureMode(live, keeping: true)
        XCTAssertEqual(held.shotsRemaining, 10_120)
        let reread = held.applying(
            property: .exposureRemaining, data: Data(ByteCoding.uint32LE(20_261)))
        XCTAssertEqual(reread.shotsRemaining, 10_120)
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

    // MARK: R-03

    /// R-03: under a full-screen cover the Nikon pump reads one camera property every 250 ms,
    /// and every read re-ran the hidden live surface, so the media page never let the main
    /// thread settle. The display state write is equality-gated already (`@Observable` skips an
    /// equal value), but the shutter lock sync rewrote `lockedControls` in place after every
    /// read, and an in-place write notifies even when nothing changed. A poll that reads back
    /// what the camera already reported must notify nothing the monitor reads.
    func testAnUnchangedCameraPollNotifiesNothingTheMonitorReads() {
        let model = NativeAppModel()
        model.startDemoSession()
        // A movie body in shutter angle mode with the shutter unlocked, as a connected ZR
        // reports it: the shell's shutter readout then reads the lock set.
        model.seedQuickDemoCamera()
        // Everything one property read writes that the live shell reads.
        func reads() {
            _ = model.cameraState
            _ = model.cameraPropertySnapshot
            _ = model.lockedControls
            _ = model.focusArea
            _ = model.focusSubject
            _ = model.cameraBatteryCharging
        }
        let probe = PollObservationProbe()
        let unchanged: [(PTPPropertyCode, Data)] = [
            (.liveViewSelector, Data([1])),
            (.movieShutterMode, Data([PTPCameraPropertyDecoders.shutterModeCode(.angle)])),
            (.movieTVLockSetting, Data([0])),
        ]
        for _ in 0..<8 {
            for (property, data) in unchanged {
                withObservationTracking {
                    reads()
                } onChange: {
                    MainActor.assumeIsolated { probe.unchanged += 1 }
                }
                model.applyBootstrapObservation(.property(property, data))
            }
        }
        XCTAssertEqual(probe.unchanged, 0, "24 unchanged reads must not invalidate the monitor")

        withObservationTracking {
            reads()
        } onChange: {
            MainActor.assumeIsolated { probe.changed = true }
        }
        model.applyBootstrapObservation(.property(.movieTVLockSetting, Data([1])))
        XCTAssertTrue(probe.changed, "a real lock change still reaches the monitor")
        XCTAssertTrue(model.lockedControls.contains(.shutter))
    }

    /// The shared surface consumes picture facts; only the raster consumes every image.
    func testLiveImagesNotifyTheRasterWithoutInvalidatingUnchangedPictureFacts() {
        for source: VideoSourceKind in [.cameraLiveView, .hdmiCapture] {
            let model = NativeAppModel()
            model.videoSource = source
            model.liveFrameImage = frame(size: CGSize(width: 16, height: 12))
            let initial = NikonMonitorShell.picture(model)
            let probe = PollObservationProbe()
            for _ in 0..<24 {
                withObservationTracking {
                    _ = NikonMonitorShell.picture(model)
                } onChange: {
                    MainActor.assumeIsolated { probe.unchanged += 1 }
                }
                withObservationTracking {
                    _ = model.liveFrameImage
                } onChange: {
                    MainActor.assumeIsolated { probe.raster += 1 }
                }
                let size =
                    probe.raster.isMultiple(of: 2)
                    ? CGSize(width: 32, height: 24) : CGSize(width: 16, height: 12)
                let next = frame(size: size)
                model.liveFrameImage = next
                XCTAssertTrue(model.liveFrameImage === next, "the actual raster must advance")
                XCTAssertEqual(NikonMonitorShell.picture(model), initial)
            }
            XCTAssertEqual(probe.unchanged, 0, "same picture facts must not re-drive chrome")
            XCTAssertEqual(probe.raster, 24, "every accepted image must reach the raster")
        }
    }

    func testPictureFactsStillNotifyForFirstFrameClearAndCaptureAspectChange() {
        let model = NativeAppModel()
        model.videoSource = .hdmiCapture
        XCTAssertTrue(NikonMonitorShell.picture(model).waiting)
        let probe = PollObservationProbe()
        func observe() {
            probe.changed = false
            withObservationTracking {
                _ = NikonMonitorShell.picture(model)
            } onChange: {
                MainActor.assumeIsolated { probe.changed = true }
            }
        }
        observe()
        model.liveFrameImage = frame(size: CGSize(width: 16, height: 12))
        XCTAssertTrue(probe.changed)
        XCTAssertFalse(NikonMonitorShell.picture(model).waiting)
        XCTAssertEqual(NikonMonitorShell.picture(model).aspect, 4 / 3)
        observe()
        model.liveFrameImage = frame(size: CGSize(width: 16, height: 9))
        XCTAssertTrue(probe.changed, "changed capture geometry must reach the chrome")
        XCTAssertEqual(NikonMonitorShell.picture(model).aspect, 16 / 9)
        observe()
        model.liveFrameImage = nil
        XCTAssertTrue(probe.changed)
        XCTAssertTrue(NikonMonitorShell.picture(model).waiting)

        let held = frame(size: CGSize(width: 16, height: 12))
        model.liveFrameImage = held
        observe()
        model.forceSessionRecoveryState(.waitingForOperator(attemptsMade: 8))
        XCTAssertTrue(probe.changed, "recovery facts must remain observable")
        XCTAssertTrue(NikonMonitorShell.picture(model).recovering)
        XCTAssertFalse(NikonMonitorShell.picture(model).waiting, "a held picture stays present")
        XCTAssertTrue(model.liveFrameImage === held)
        observe()
        model.forceSessionRecoveryState(.idle)
        XCTAssertTrue(probe.changed)
        XCTAssertFalse(NikonMonitorShell.picture(model).recovering)
        XCTAssertTrue(model.liveFrameImage === held)
    }

    private func frame(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Shared capture popups

    /// Every camera picker except the two independent-switch panels draws on the shared ladder
    /// sheet, movie and photo alike, so no Nikon-only drum panel remains.
    func testEveryValuePickerDrawsTheSharedLadderSheet() {
        XCTAssertEqual(
            Set(CameraPicker.allCases.filter { !$0.usesLadderSheet }),
            [.stillQuality, .stabilization])
    }

    /// SIMULATED native actions: display positions never replace the body's write keys.
    func testSIMULATEDCanonicalWhiteBalanceTabsKeepWriteKeysAndOpeningIsReadOnly() async throws {
        _ = await HostedAccessibility.awaitRuntime()
        for reportedMode: String? in [nil, "Color temp", "Daylight"] {
            let sheet = try XCTUnwrap(CameraPicker.whiteBalance.sharedCaptureSheet)
            var popup = NikonCapturePopupState(
                kind: .whiteBalance, title: sheet.headerLabel, subtitle: sheet.subtitle,
                modes: [
                    NikonLadderMode(index: 0, title: "Kelvin", options: [], current: "5600K"),
                    NikonLadderMode(
                        index: 1, title: "Preset", options: ["Auto", "Daylight"],
                        current: "Daylight"),
                    NikonLadderMode(index: 2, title: "Tint", options: [], current: ""),
                ])
            popup.whiteBalanceMode = reportedMode
            popup.tintAvailable = true
            var writes: [LadderWrite<NikonLadderControl>] = []
            let hosted = try Hosted(
                LadderSheet(
                    presentation: popup.presentation, enabled: true, onWrite: { writes.append($0) })
            )
            defer { hosted.close() }
            let initial = reportedMode == "Daylight" ? 0 : 1
            let mounted = try await hosted.settle {
                hosted.element("monitor.capture.tab.\(initial)")?.accessibilityTraits.contains(
                    .selected) == true
            }
            XCTAssertTrue(mounted, hosted.identifiers.joined(separator: ", "))
            XCTAssertTrue(writes.isEmpty, "Opening the drawer must not request a camera write")
            let order = initial == 1 ? [0, 1] : [1, 0]
            for index in order {
                let tab = try XCTUnwrap(hosted.element("monitor.capture.tab.\(index)"))
                XCTAssertTrue(tab.accessibilityActivate())
                let selected = try await hosted.settle {
                    hosted.element("monitor.capture.tab.\(index)")?.accessibilityTraits.contains(
                        .selected) == true
                }
                XCTAssertTrue(selected)
            }
            let expected = order.map { index in
                index == 0
                    ? LadderWrite(key: NikonLadderControl.value(1), value: "Daylight")
                    : LadderWrite(key: NikonLadderControl.value(0), value: "5600K")
            }
            XCTAssertEqual(writes, expected)
            let tint = try XCTUnwrap(hosted.element("monitor.capture.tab.2"))
            XCTAssertTrue(tint.accessibilityActivate())
            let tintSelected = try await hosted.settle {
                hosted.element("monitor.capture.tab.2")?.accessibilityTraits.contains(.selected)
                    == true
            }
            XCTAssertTrue(tintSelected)
            XCTAssertEqual(writes, expected, "Opening Tint must not invent a selected-value write")
        }
    }

    /// SIMULATED native actions: shutter activation changes only the original camera circuit.
    func testSIMULATEDCanonicalShutterTabsChangeOnlyCircuitAndOpeningIsReadOnly() async throws {
        _ = await HostedAccessibility.awaitRuntime()
        for circuit in [0, 1] {
            let sheet = try XCTUnwrap(CameraPicker.shutter.sharedCaptureSheet)
            var popup = NikonCapturePopupState(
                kind: .shutter, title: sheet.headerLabel, subtitle: sheet.subtitle,
                modes: [
                    NikonLadderMode(index: 0, title: "Angle", options: ["180°"], current: "180°"),
                    NikonLadderMode(index: 1, title: "Speed", options: ["1/50"], current: "1/50"),
                ])
            popup.circuitIndex = circuit
            var writes: [LadderWrite<NikonLadderControl>] = []
            let hosted = try Hosted(
                LadderSheet(
                    presentation: popup.presentation, enabled: true, onWrite: { writes.append($0) })
            )
            defer { hosted.close() }
            let initial = circuit == 1 ? 0 : 1
            let mounted = try await hosted.settle {
                hosted.element("monitor.capture.tab.\(initial)")?.accessibilityTraits.contains(
                    .selected) == true
            }
            XCTAssertTrue(mounted, hosted.identifiers.joined(separator: ", "))
            XCTAssertTrue(writes.isEmpty)
            let next = 1 - initial
            let tab = try XCTUnwrap(hosted.element("monitor.capture.tab.\(next)"))
            XCTAssertTrue(tab.accessibilityActivate())
            let selected = try await hosted.settle {
                hosted.element("monitor.capture.tab.\(next)")?.accessibilityTraits.contains(
                    .selected) == true
            }
            XCTAssertTrue(selected)
            XCTAssertEqual(
                writes, [LadderWrite(key: .shutterMode, value: next == 0 ? "Speed" : "Angle")],
                "A tab switch must not send the landed shutter value")
        }
    }

    /// Nikon AF boxes normalize to the shared focus layer with the result as its colour (twin of
    /// the Android `nikon AF boxes normalize to the shared focus layer with the result as its colour`).
    func testNikonAFBoxesNormalizeToTheSharedFocusLayerWithTheResultAsItsColour() throws {
        func focus(
            width: Int = 1_920, result: PTPLiveViewFocusInfo.FocusResult = .notFocused,
            tracking: Bool = false
        ) -> PTPLiveViewFocusInfo {
            PTPLiveViewFocusInfo(
                coordinateWidth: width, coordinateHeight: 1_080,
                focusResult: result, subjectDetectionActive: false, trackingAFActive: tracking,
                selectedBoxIndex: nil,
                boxes: [
                    PTPLiveViewAFBox(centerX: 960, centerY: 540, width: 192, height: 108),
                    PTPLiveViewAFBox(centerX: 480, centerY: 270, width: 96, height: 54),
                ])
        }
        let areas = try XCTUnwrap(nikonFocusAreas(focus()))
        let primary = try XCTUnwrap(areas.primary)
        XCTAssertEqual(primary.x, 0.45, accuracy: 0.0001)
        XCTAssertEqual(primary.y, 0.45, accuracy: 0.0001)
        XCTAssertEqual(primary.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(areas.others.count, 1)
        XCTAssertEqual(try XCTUnwrap(areas.others.first).x, 0.225, accuracy: 0.0001)
        XCTAssertFalse(areas.confirmed)
        XCTAssertTrue(try XCTUnwrap(nikonFocusAreas(focus(tracking: true))).confirmed)
        XCTAssertTrue(try XCTUnwrap(nikonFocusAreas(focus(result: .focused))).confirmed)
        XCTAssertNil(nikonFocusAreas(focus(width: 0)))
    }

    /// A missing primary observation must not hide the body's valid secondary subject areas.
    func testValidSecondaryAFBoxRendersWhenThePrimaryBoxIsInvalid() throws {
        let focus = PTPLiveViewFocusInfo(
            coordinateWidth: 1_000, coordinateHeight: 500,
            focusResult: .notFocused, subjectDetectionActive: true, trackingAFActive: false,
            selectedBoxIndex: nil,
            boxes: [
                PTPLiveViewAFBox(centerX: 100, centerY: 100, width: 0, height: 0),
                PTPLiveViewAFBox(centerX: 500, centerY: 250, width: 200, height: 100),
            ])
        let areas = try XCTUnwrap(nikonFocusAreas(focus))
        XCTAssertNil(areas.primary)
        XCTAssertEqual(areas.others.count, 1)
        let renderer = ImageRenderer(
            content: LiveFocusBoxOverlay(focus: focus)
                .frame(width: 400, height: 200).background(Color.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var greenPixels = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red: Int = Int(bytes[offset])
            let green: Int = Int(bytes[offset + 1])
            let blue: Int = Int(bytes[offset + 2])
            if green > red + 32 && green > blue + 32 { greenPixels += 1 }
        }
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "SIMULATED secondary AF without primary"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(greenPixels, 40, "The valid secondary AF area must remain visible")
    }

    /// Preserve the original adapter's camera fixture through the shared normalized projection.
    func testOriginalCameraAFProjectionKeepsItsMirrorAndSubjectCentres() throws {
        let focus = originalProjectionFocus()
        let areas = try XCTUnwrap(nikonFocusAreas(focus))
        let primary = try XCTUnwrap(areas.primary).flipped(horizontal: true, vertical: false)
        XCTAssertEqual(primary.centerX, 0.75, accuracy: 0.0001)
        XCTAssertEqual(primary.centerY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(primary.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(primary.height, 0.1, accuracy: 0.0001)
        XCTAssertEqual(areas.others.count, 1)
        let secondary = try XCTUnwrap(areas.others.first).flipped(horizontal: true, vertical: false)
        XCTAssertEqual(secondary.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(secondary.centerY, 0.2, accuracy: 0.0001)
        let image = try projectionImage(focus, mirrored: true)
        let mask = try projectionGreenPixels(image)
        XCTAssertTrue(mask.contains { $0.x >= 558 && $0.x <= 642 && $0.y >= 178 && $0.y <= 222 })
        XCTAssertFalse(mask.contains { $0.x >= 158 && $0.x <= 242 && $0.y >= 178 && $0.y <= 222 })
        XCTAssertTrue(mask.contains { $0.x >= 318 && $0.x <= 482 })
    }

    /// A temporarily empty picture must not paint lock glyphs or marks outside its zero frame.
    func testZeroSizeCameraAFProjectionDrawsNoMarksEvenWhenLocked() throws {
        let focus = originalProjectionFocus()
        let visible = try projectionImage(focus, locked: true)
        XCTAssertGreaterThan(try projectionGreenPixels(visible).count, 40)
        let empty = try projectionImage(focus, locked: true, size: .zero)
        let attachment = XCTAttachment(image: UIImage(cgImage: empty))
        attachment.name = "SIMULATED zero-size AF projection"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(try projectionGreenPixels(empty).count, 0)
    }

    private func originalProjectionFocus() -> PTPLiveViewFocusInfo {
        PTPLiveViewFocusInfo(
            coordinateWidth: 1_000, coordinateHeight: 500,
            focusResult: .focused, subjectDetectionActive: true, selectedBoxIndex: 0,
            boxes: [
                PTPLiveViewAFBox(centerX: 250, centerY: 250, width: 100, height: 50),
                PTPLiveViewAFBox(centerX: 500, centerY: 100, width: 200, height: 100),
            ])
    }

    private func projectionImage(
        _ focus: PTPLiveViewFocusInfo, mirrored: Bool = false, locked: Bool = false,
        size: CGSize = CGSize(width: 800, height: 400)
    ) throws -> CGImage {
        let renderer = ImageRenderer(
            content: LiveFocusBoxOverlay(focus: focus, locked: locked, mirrored: mirrored)
                .frame(width: size.width, height: size.height)
                .frame(width: 800, height: 400).background(Color.black))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func projectionGreenPixels(_ image: CGImage) throws -> [CGPoint] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var points: [CGPoint] = []
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red: Int = Int(bytes[offset])
            let green: Int = Int(bytes[offset + 1])
            let blue: Int = Int(bytes[offset + 2])
            guard green > red + 32, green > blue + 32 else { continue }
            let pixel = offset / 4
            points.append(CGPoint(x: pixel % image.width, y: pixel / image.width))
        }
        return points
    }

    /// Owner report 2026-10-19: after a Quality Bias change the restarted feed showed "--" in the
    /// readouts and the timecode lost its frame field. That restart skips the property burst, so
    /// it must keep the readings; only a restart that re-reads the body holds back to the mode.
    func testAWarmLiveViewRestartKeepsTheReadingsThatDriveTheReadouts() {
        let live = PTPCameraPropertySnapshot(
            iso: 800, shutterSpeed: "1/50", fNumber: "f/2.8", wbKelvin: 5600, resolution: "4K",
            fps: 25, fileType: "N-RAW", captureSelector: .video)

        let warm = NativeAppModel.heldPropertySnapshot(
            live, keepingCaptureMode: true, keepingReadings: true)
        XCTAssertEqual(warm, live)
        // The frame rate sets the timecode's frame precision in the shared session.
        XCTAssertEqual(warm.fps, 25)

        let reread = NativeAppModel.heldPropertySnapshot(
            live, keepingCaptureMode: true, keepingReadings: false)
        XCTAssertEqual(reread, PTPCameraPropertySnapshot(captureSelector: .video))
    }

    /// The restart also drops writes that were queued but never sent, so a kept display must show
    /// what the camera confirmed, not a picker's optimistic value it will never receive.
    func testAWarmLiveViewRestartShowsTheConfirmedReadingsNotADroppedWrite() {
        let reported = PTPCameraPropertySnapshot(iso: 800, fps: 25, captureSelector: .video)
        let optimistic = PTPCameraPropertySnapshot(iso: 1600, fps: 25, captureSelector: .video)

        let warm = NativeAppModel.heldPropertySnapshots(
            display: optimistic, reported: reported, keepingCaptureMode: true,
            keepingReadings: true)
        XCTAssertEqual(warm.display, reported)
        XCTAssertEqual(warm.reported, reported)

        let reread = NativeAppModel.heldPropertySnapshots(
            display: optimistic, reported: reported, keepingCaptureMode: true,
            keepingReadings: false)
        XCTAssertEqual(reread.display, PTPCameraPropertySnapshot(captureSelector: .video))
        XCTAssertEqual(reread.reported, PTPCameraPropertySnapshot(captureSelector: .video))
    }

    /// The camera status shows on the shared waiting plate with Android's words: no camera,
    /// connecting, coming back from an internet hop; a connected camera keeps the waiting plate.
    func testCameraStatusShowsOnTheSharedWaitingPlate() {
        XCTAssertNil(nikonCameraStatusNotice(connection: .connected, internetHopActive: true))
        XCTAssertEqual(
            nikonCameraStatusNotice(connection: .disconnected, internetHopActive: false),
            MonitorOperatorPictureNotice(title: "No camera"))
        XCTAssertEqual(
            nikonCameraStatusNotice(connection: .reconnecting, internetHopActive: false),
            MonitorOperatorPictureNotice(
                title: "Connecting…", detail: "Searching for the camera and restoring live view.",
                progress: true))
        XCTAssertEqual(
            nikonCameraStatusNotice(connection: .disconnected, internetHopActive: true)?.title,
            "Reconnecting to camera…")
    }

    /// SIMULATED actual adapter: camera inventory owns every offered format; opening never writes.
    func testRecordingFormatPanelUsesOnlyAdvertisedTokensAndNeverSeedsAnEmptyInventory()
        async throws
    {
        let token = "4K · 25p"
        let mode = PTPCameraScreenSizeMode(
            raw: UInt64(3840) << 48 | UInt64(2160) << 32 | UInt64(25) << 16,
            label: token)
        for hasInventory in [true, false] {
            let model = NativeAppModel(assist: .scratch())
            model.connection = .connected
            model.videoSource = .cameraLiveView
            model.cameraState = model.cameraState.updating(resolutionFrameRate: token)
            model.cameraScreenModes = hasInventory ? [mode] : []
            XCTAssertEqual(
                model.recordingFormatPresentations.map(\.token), hasInventory ? [token] : [])
            XCTAssertFalse(model.recordingFormatPresentations.contains { $0.token == "6K · 24p" })
            let hosted = try Hosted(LadderPickerPanel(picker: .resolution).environment(model))
            defer { hosted.close() }
            func nodes() -> [NSObject] {
                HostedAccessibility.elements(in: hosted.host.view).filter(\.isAccessibilityElement)
            }
            let mounted = try await hosted.settle {
                nodes().contains { $0.accessibilityLabel == "Value" }
            }
            XCTAssertTrue(mounted, hosted.identifiers.joined(separator: ", "))
            let elements = nodes()
            let drum = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Value" })
            let buttons = elements.filter { $0.accessibilityTraits.contains(.button) }
            let groups = buttons.compactMap(\.accessibilityLabel).sorted()
            // Read the complete native button list, including an unclassified "Other" group.
            // SwiftUI can inherit the sheet's identifier on children; labels and selected traits
            // still prove the actual offered groups rather than an empty identifier-prefix match.
            XCTAssertEqual(groups, hasInventory ? ["4K"] : [])
            if hasInventory {
                let group = buttons.first { $0.accessibilityLabel == "4K" }
                XCTAssertEqual(group?.accessibilityTraits.contains(.selected), true)
            }
            XCTAssertEqual(drum.accessibilityValue, hasInventory ? "25p" : "Not set")
            XCTAssertEqual(model.cameraValue(for: .resolution), token)
            XCTAssertEqual(model.debugPendingCameraWriteCount, 0)
            XCTAssertTrue(model.shell.control.pending.isEmpty)
            let facts: [String: Any] = [
                "SIMULATED": true, "inventory": model.recordingFormatPresentations.map(\.token),
                "resolutionGroups": groups, "drum": drum.accessibilityValue ?? "",
                "cameraToken": model.cameraValue(for: .resolution),
                "nativePendingWrites": model.debugPendingCameraWriteCount,
                "typedPendingWrites": model.shell.control.pending.count,
                "nativeAccessibility": elements.map {
                    [
                        "identifier": HostedAccessibility.identifier($0) ?? "",
                        "label": $0.accessibilityLabel ?? "",
                        "value": $0.accessibilityValue ?? "",
                        "traits": String($0.accessibilityTraits.rawValue),
                    ]
                },
            ]
            let data = try JSONSerialization.data(
                withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
            let values = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            values.name = "SIMULATED format adapter " + (hasInventory ? "advertised" : "empty")
            values.lifetime = .keepAlways
            add(values)
            let image = UIGraphicsImageRenderer(bounds: hosted.host.view.bounds).image { _ in
                _ = hosted.host.view.drawHierarchy(
                    in: hosted.host.view.bounds, afterScreenUpdates: true)
            }
            let picture = XCTAttachment(image: image)
            picture.name = values.name
            picture.lifetime = .keepAlways
            add(picture)
        }
    }

    /// The recording format popup is the ladder sheet's shared format picker, one choice per
    /// camera token; a token the body does not describe stays unclassified.
    func testRecordingFormatsAreTheLadderSheetFormatPickerOneChoicePerToken() {
        let mode = PTPCameraScreenSizeMode(
            raw: UInt64(3840) << 48 | UInt64(2160) << 32 | UInt64(24) << 16, label: "4K 24p")
        let described = NikonRecordingFormatPresentation(
            mode: mode, currentCodec: "H.265", isNikonZR: true)
        let choices = nikonLadderFormats(
            options: [described.token, "Unknown"], recordingFormats: [described])
        XCTAssertEqual(choices.map(\.value), [described.token, "Unknown"])
        XCTAssertEqual(choices[0].resolution?.title, described.resolution)
        XCTAssertEqual(choices[0].frameRate?.title, "24p")
        XCTAssertNil(choices[1].resolution)
        XCTAssertNil(choices[1].frameRate)
    }

    /// The body's exposure indicator reaches the shared EV meter in photography.
    func testTheCameraIndicatorFeedsTheSharedExposureMeter() {
        let model = NativeAppModel()
        model.applyDemoProperty(.exposureIndicateStatus, data: Data([UInt8(bitPattern: -9)]))
        model.applyDemoProperty(.exposureIndicateLightup, data: Data([0]))
        XCTAssertEqual(model.cameraPropertySnapshot.exposureMeter.stops, -1.5)
        XCTAssertEqual(model.cameraPropertySnapshot.exposureMeter.label, "\u{2212}1.5")
        model.applyDemoProperty(.exposureIndicateLightup, data: Data([1]))
        XCTAssertNil(model.cameraPropertySnapshot.exposureMeter.stops)
    }
}

@MainActor
private final class PollObservationProbe {
    var unchanged = 0
    var changed = false
    var raster = 0
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
            ("portrait", CGSize(width: 402, height: 874)),
            ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let model = NativeAppModel()
            model.preferences = OperatorPreferences.defaults
            model.startDemoSession()
            let host = UIHostingController(
                rootView: AnyView(
                    NativeRootContent().environment(model).environment(model.delivery)))
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

/// Behavior audit ZIA-052 / ZIA-360: the baseline still release spoke "End exposure" while a bulb
/// or time exposure was open, was a button, and VoiceOver could not release what touch could not.
final class NikonPhotoReleaseAccessibilityTests: XCTestCase {
    func testOpenExposureIsSpokenAsEndExposure() {
        XCTAssertEqual(
            NikonPhotoReleaseAccessibility.label(
                openShutter: true, capturing: true, timerRunning: false),
            "End exposure")
        XCTAssertEqual(
            NikonPhotoReleaseAccessibility.label(
                openShutter: false, capturing: true, timerRunning: false),
            "Capturing")
        XCTAssertEqual(
            NikonPhotoReleaseAccessibility.label(
                openShutter: false, capturing: false, timerRunning: true),
            "Timer running")
        XCTAssertEqual(
            NikonPhotoReleaseAccessibility.label(
                openShutter: false, capturing: false, timerRunning: false),
            "Shutter")
    }

    func testTheReleaseIsAButton() {
        XCTAssertTrue(NikonPhotoReleaseAccessibility.traits.contains(.isButton))
    }

    func testVoiceOverReleaseTakesTheTouchAdmission() {
        XCTAssertTrue(NikonPhotoReleaseAccessibility.admits(locked: false, surrendered: false))
        XCTAssertFalse(NikonPhotoReleaseAccessibility.admits(locked: true, surrendered: false))
        XCTAssertFalse(NikonPhotoReleaseAccessibility.admits(locked: false, surrendered: true))
    }
}
