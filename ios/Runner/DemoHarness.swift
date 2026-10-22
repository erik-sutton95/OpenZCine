import MonitorPresentation
import Network
import OpenCineAppKit
import OpenCineApple
import OpenCineCameraControls
import OpenCineCore
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit
import os

/// The demo / screenshot harness: every `ZC_*` launch-environment hook lives in this file and
/// nowhere else (`just check-demo-isolation` enforces it). Stages app state for headless captures
/// without a camera, and is **compiled out of Release builds** — everything below is `#if DEBUG`
/// or an inert stub, so store archives physically cannot trigger demo behaviour.
///
/// Adding a hook: add a named accessor to the registry below (or extend
/// `applyLaunchEnvironment(to:)` for launch-time staging) and call it from the feature — no
/// `ProcessInfo` reads and no raw `ZC_` strings at call sites.
enum DemoHarness {
    /// SIMULATED product layouts, never connected to a camera driver.
    static let focusRackFixture = value("ZC_DEMO_FOCUS_RACK")
    static let opensFocusRackFixture = value("ZC_DEMO_FOCUS_RACK_AUTOOPEN") != "0"

    // MARK: Hook registry — every env toggle, one place.

    /// `ZC_DEMO_OPEN_MEDIA` opens the Media browser on launch; the value `play` also starts the
    /// first downloaded clip and `share` opens the delivery popup over it (read in
    /// `MediaBrowserView`).
    static let openMediaAction = value("ZC_DEMO_OPEN_MEDIA")
    /// `ZC_DEMO_MEDIA_LUT=1` switches the LUT tool on when playback starts.
    static let mediaLUT = flag("ZC_DEMO_MEDIA_LUT")
    /// `ZC_DEMO_PANEL_TAB` picks the Operator Setup rail tab (link/assist/controls/…).
    static let panelTab = value("ZC_DEMO_PANEL_TAB")
    /// `ZC_DEMO_WIZARD_EXPANDED=1` seeds the wizard transport card's nested options open.
    /// Expansion is a tap, unreachable headless, and the expanded overflow is what screenshots
    /// must check.
    static let wizardExpanded = flag("ZC_DEMO_WIZARD_EXPANDED")
    /// `ZC_DEMO_RED_BLOCKED=ap|off` forces the RED download blocked state for screenshots.
    static let forcedRedAvailability = value("ZC_DEMO_RED_BLOCKED")
    /// `ZC_DEMO_OPEN_BUG_REPORT=1` opens the bug-report route chooser for screenshot checks.
    static let openBugReport = flag("ZC_DEMO_OPEN_BUG_REPORT")
    /// `ZC_DEMO_INTERNET_CONFIRM=support|feature` stages the camera-AP confirmation alert.
    static let internetHandoffConfirmation = value("ZC_DEMO_INTERNET_CONFIRM")
    /// `ZC_DEMO_INTERNET_PROGRESS=support|feature` stages the route-waiting overlay.
    static let internetHandoffProgress = value("ZC_DEMO_INTERNET_PROGRESS")
    /// `ZC_DEMO_CPU_FEED=1` forces the old `UIImageView` feed path back, for an A/B against the
    /// default GPU-native renderer. See `FeedRenderMode`.
    static let forceCPUFeed = flag("ZC_DEMO_CPU_FEED")
    /// `ZC_DEMO_FEED_SCALER=lanczos|metalfx|super` seeds which upscaler the feed starts on, for an
    /// A/B on a device that supports more than one. Prefix match, so `metal` and `super` do. The
    /// Display settings row switches it live; this is for a launch that has to start there.
    /// See `FeedUpscaleSwitch`.
    static let forcedFeedUpscaler = value("ZC_DEMO_FEED_SCALER").flatMap { raw in
        MonitorUpscaler.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
    }
    /// `ZC_DEMO_SR_STAGE=input` presents the super-resolution model's INPUT buffer instead of its
    /// output, converted back the same way.
    ///
    /// The two colour legs fail identically from the outside — a buffer nobody wrote reads as flat
    /// green either way — so this splits them: a picture here means the write leg works and the
    /// fault is downstream of the model; green here means the write leg is what is silent.
    static let superResolutionStage = value("ZC_DEMO_SR_STAGE")
    /// `ZC_DEMO_DENOISE=<0…1>` runs VideoToolbox's temporal noise filter over the live feed at
    /// that strength. Env rather than a tool because it is unproven: the super-resolution
    /// processor in the same family completes without error and writes nothing, and this is the
    /// experiment that says whether that is one broken processor or the whole family.
    static let liveDenoiseStrength = value("ZC_DEMO_DENOISE").flatMap(Float.init)
    /// `ZC_DEMO_CPU_DECODE=1` forces the ImageIO decode back, for an A/B against the hardware
    /// JPEG path. See `FrameDecoder`.
    static let forcesCPUJPEGDecode = flag("ZC_DEMO_CPU_DECODE")

    /// `ZC_DEMO_BLOCK_SMOOTH=<strength>` (0…1) enables variance-gated flat-region smoothing, and
    /// `ZC_DEMO_BLOCK_GATE=<levels>` sets the flatness threshold it disengages at (default 5, in
    /// levels out of 255). `ZC_DEMO_BLOCK_DITHER=<levels>` adds masking noise (try 2–4).
    ///
    /// Env rather than a setting because none of these have been calibrated against a real camera
    /// frame — they exist to be swept on hardware and relaunched, and the winning numbers become a
    /// real operator control (and a shared-core constant for the Android shells) afterwards.
    static let blockSmoothStrength = value("ZC_DEMO_BLOCK_SMOOTH").flatMap(Double.init)
    static let blockSmoothGateLevels = value("ZC_DEMO_BLOCK_GATE").flatMap(Double.init)
    static let blockDitherLevels = value("ZC_DEMO_BLOCK_DITHER").flatMap(Double.init)
    /// `ZC_DEMO_WIFI_SCANNER=scan|manual` opens the Wi-Fi credential scanner for screenshots.
    static let cameraWiFiScannerMode = value("ZC_DEMO_WIFI_SCANNER")
    /// `ZC_DEMO_WIFI_OFF=1` makes the camera-AP flows treat the Wi-Fi radio as switched off, so
    /// the "Wi-Fi is off" prompt can be captured — the Simulator borrows the Mac's radio and can
    /// never reach that state for real.
    static let wiFiRadioOff = flag("ZC_DEMO_WIFI_OFF")
    /// `ZC_DEMO_PLAYBACK_CLEAN_VIEW=1` opens the clip player with its chrome already hidden, so
    /// the clean view and its "tap to show controls" hint can be captured headlessly. Synthetic
    /// taps do not reach this app, so the state is otherwise only reachable by hand.
    static let playbackCleanView = flag("ZC_DEMO_PLAYBACK_CLEAN_VIEW")
    /// `ZC_DEMO_RATING_SHADE=handle|open` mounts the star-rating shade in the clip player without a
    /// camera session, closed or already open. Both states need capturing: the rating is read from
    /// the card, so neither is reachable headlessly, and synthetic taps do not reach this app —
    /// which is how an empty shade shipped unnoticed.
    static let ratingShade = value("ZC_DEMO_RATING_SHADE")
    /// `ZC_DEMO_CAPTURE_FRAMES=N` dumps the next N live-view frames to disk — see
    /// ``captureLiveViewObject(_:)``.
    static let captureLiveViewFrameCount = value("ZC_DEMO_CAPTURE_FRAMES").flatMap(Int.init)
    /// `ZC_DEMO_SPLASH_HOLD_MS=N` keeps the launch splash fully visible for N milliseconds instead
    /// of `LaunchSplashTiming.visibleDuration`, so a UI test can observe the covered cameras page
    /// even when the simulator takes longer to launch than the splash normally shows.
    static let launchSplashHold = value("ZC_DEMO_SPLASH_HOLD_MS").flatMap(Int.init)
        .map { Duration.milliseconds($0) }

    // MARK: Environment access — Debug reads the process env; Release is hardwired inert.

    #if DEBUG
        /// The shared conformance kit's staging (`ReviewLaunch`, OpenCine
        /// docs/conformance/SCENARIOS.md), said in the hooks below; an explicit `ZC_*` value wins.
        private static let review = ReviewLaunch.current
        private static let environment = ProcessInfo.processInfo.environment.merging(
            review.map(hooks(for:)) ?? [:]
        ) { explicit, _ in explicit }
        private static func flag(_ name: String) -> Bool { environment[name] == "1" }
        private static func value(_ name: String) -> String? { environment[name] }
    #else
        private static func flag(_ name: String) -> Bool { false }
        private static func value(_ name: String) -> String? { nil }
    #endif

    #if !DEBUG
        /// Release stub — the launch harness does not exist outside Debug builds.
        @MainActor static func applyLaunchEnvironment(to model: NativeAppModel) async {}
    #endif

    #if DEBUG
        @MainActor static var focusRackFixtureState: FocusRackState? {
            guard let fixture = focusRackFixture else { return nil }
            var state = FocusRackState.initial
            state.message = "SIMULATED layout. No camera driver is attached."
            state.capabilities.canEditTiming = true
            state.capabilities.canReset = true
            if fixture == "empty" || fixture == "entry" {
                state.capabilities.canCaptureA = true
                state.capabilities.canCaptureB = true
                state.capabilities.canNudge = true
                state.capabilities.canAutofocus = true
                return state
            }
            state.program = .init(
                marks: [.init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 20)],
                transitions: [state.transition])
            state.captures = [
                .init(markID: "A", revision: 1, sessionID: "SIMULATED", frameSequence: 1),
                .init(markID: "B", revision: 2, sessionID: "SIMULATED", frameSequence: 2),
            ]
            state.stepPosition = 0
            state.referenceValid = true
            state.phase = .ready
            state.capabilities.canCaptureA = true
            state.capabilities.canCaptureB = true
            state.capabilities.canGoToA = true
            state.capabilities.canGoToB = true
            state.capabilities.canNudge = true
            state.primary = .init(
                kind: "rehearse", title: "Rehearse A→B", enabled: true,
                detail: state.transition.playbackDetail)
            if fixture == "calibration" || fixture == "calibrationMeasured" {
                state.program.marks = [
                    .init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 100),
                ]
                state.calibration = .init(
                    kind: "calibrate",
                    title: fixture == "calibration" ? "Calibrate to B" : "Calibration measured",
                    enabled: fixture == "calibration",
                    detail: fixture == "calibration"
                        ? "32-pulse increments · 1/10" : "All 5 sizes in both directions")
            }
            if fixture == "setupChanged" {
                state.message = "Camera setup changed. Check A and B; reset marks if needed."
            } else if fixture == "timing" {
                state.admissionMessage = "Increase duration to at least 16.61s for these marks."
                state.minimumDuration = 16.61
                state.primary.enabled = false
                state.primary.disabledReason = "Adjust timing"
            } else if fixture == "elsewhere" {
                state.stepPosition = 10
                state.primary = .init(
                    kind: "rehearse", title: "Rehearse A→B", enabled: false,
                    detail: state.transition.playbackDetail, disabledReason: "Go to A first")
            } else if fixture == "recording" {
                state.primary = .init(
                    kind: "run", title: "Run A→B", enabled: true,
                    detail: state.transition.playbackDetail)
            } else if fixture == "moving" || fixture == "paused" {
                state.phase = fixture == "moving" ? .moving : .paused
                state.busy = true
                state.completedSteps = 8
                state.totalSteps = 20
                state.stepPosition = 8
                state.capabilities.canCaptureA = false
                state.capabilities.canCaptureB = false
                state.capabilities.canNudge = false
                state.capabilities.canEditTiming = false
                state.capabilities.canGoToA = false
                state.capabilities.canGoToB = false
                state.capabilities.canPause = fixture == "moving"
                state.capabilities.canResume = fixture == "paused"
                state.capabilities.canStop = true
                state.primary = .init(
                    kind: fixture == "moving" ? "pause" : "resume",
                    title: fixture == "moving" ? "Pause" : "Resume", enabled: true)
            } else if fixture == "uncertain" || fixture == "reference" {
                state.phase = fixture == "uncertain" ? .stopUnconfirmed : .uncertain
                state.stepPosition = nil
                state.referenceValid = false
                state.recoveryInstruction =
                    fixture == "uncertain"
                    ? "Reconnect camera, then reset marks." : "Reset marks before moving focus."
                state.message =
                    "SIMULATED: Camera readiness is unconfirmed. Reconnect the camera before resetting marks. "
                    + String(
                        repeating: "The full diagnostic feedback remains scrollable. ", count: 8)
                state.primary = .init(kind: "reset", title: "Reset marks", enabled: false)
                state.capabilities = .init()
            }
            if fixture == "nudgeNear" || fixture == "nudgeFar" {
                let near = fixture == "nudgeNear"
                state.phase = .moving
                state.busy = true
                state.completedSteps = 3
                state.totalSteps = 10
                state.stepPosition = near ? -3 : 3
                state.nudgeProgress = .init(towardNear: near, steps: 10, percent: 30)
                if !near {
                    state.admissionMessage =
                        "This move needs at least 4.00 seconds at the current camera cadence."
                }
                state.capabilities = .init()
                state.capabilities.canStop = true
                state.capabilities.canEditTiming = false
                state.primary = .init(kind: "pause", title: "Pause", enabled: true)
            }
            if fixture == "atB" {
                state.stepPosition = 20
                state.phase = .complete
                state.message = ""
            }
            state.updateTimedActions(recording: fixture == "recording", ready: state.referenceValid)
            return state
        }
    #endif

    #if DEBUG
        /// Exercises typed/legacy precedence at the real shared cameras screen, without a camera.
        @MainActor static func addSetupSlots(_ supplied: IntegrationSlots) -> IntegrationSlots {
            guard let mode = value("ZC_DEMO_CHOOSER_SLOT") else { return supplied }
            var slots = supplied
            slots.addRoute = { _, done in
                AnyView(
                    VStack {
                        Text("Legacy chooser")
                        Button("Cancel") { done(nil) }
                    }.padding())
            }
            if mode == "legacy" {
                slots.addSetup = nil
            } else if let typed = slots.addSetup {
                slots.addSetup = { camera, done in
                    var flow = typed(camera, done)
                    flow.chooser.title = "Typed chooser"
                    return flow
                }
            }
            return slots
        }
    #else
        @MainActor static func addSetupSlots(_ supplied: IntegrationSlots) -> IntegrationSlots {
            supplied
        }
    #endif

    /// Actual shared-screen consent review; release builds have no review path.
    @MainActor static func connectConsentReview() -> AnyView? {
        #if DEBUG
            guard let mode = value("ZC_DEMO_CONSENT_SCREEN") else { return nil }
            return AnyView(ConnectConsentReview(mode: mode))
        #else
            return nil
        #endif
    }

    /// SIMULATED public-input host for the app's typed independent-setting row projection.
    /// Its receipts observe row callbacks only; it owns no camera, transport or app preferences.
    @MainActor static func stabilizationReview() -> AnyView? {
        #if DEBUG
            guard let mode = value("ZC_DEMO_STABILIZATION_PANEL") else { return nil }
            return AnyView(StabilizationReview(mode: mode))
        #else
            return nil
        #endif
    }

    // MARK: Live-view frame capture

    #if DEBUG
        /// Spacing between captured frames. One a second so that slowly racking focus across the
        /// capture produces a focus SWEEP rather than N copies of one moment.
        private static let captureInterval: TimeInterval = 1.0
        /// Grace period between arming and the first frame — long enough to dismiss the setup
        /// panel and get a hand on the focus ring.
        private static let captureLeadIn: TimeInterval = 5.0

        private struct CaptureState {
            var beginsAt: Date?
            var target = 0
            var written = 0
            var run = 0
            var lastWrite = Date.distantPast
        }

        private static let captureState = OSAllocatedUnfairLock(initialState: CaptureState())

        static var captureDirectory: URL? {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }

        /// Next unused run index, read from disk rather than held in memory so a relaunch between
        /// sweeps cannot silently overwrite an earlier one — which is exactly what happened the
        /// first time two sweeps were shot back to back.
        private static func nextRunIndex() -> Int {
            guard let directory = captureDirectory,
                let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { return 0 }
            let used = names.compactMap { name -> Int? in
                guard name.hasPrefix("liveview-r"), name.count > 11 else { return nil }
                return Int(name.dropFirst(10).prefix(2))
            }
            return (used.max() ?? -1) + 1
        }

        /// Arms a capture run. Deliberately a manual trigger rather than "start on the first
        /// frame": the stream opens long before the shot is framed, so an automatic start would
        /// spend the whole run on the connect sequence.
        static func startLiveViewCapture() {
            let target = captureLiveViewFrameCount ?? 25
            let run = nextRunIndex()
            captureState.withLock { state in
                state = CaptureState(
                    beginsAt: Date().addingTimeInterval(captureLeadIn), target: target, run: run)
            }
        }

        /// Short status for the debug row, or nil when idle. Polled by the UI rather than pushed,
        /// so the capture path stays lock-only and never hops to the main actor per frame.
        static func liveViewCaptureStatus() -> String? {
            captureState.withLock { state in
                guard let beginsAt = state.beginsAt else { return nil }
                let countdown = beginsAt.timeIntervalSinceNow
                if countdown > 0 { return "Rack in \(Int(countdown.rounded(.up)))…" }
                if state.written >= state.target {
                    return "Run \(state.run): saved \(state.written)"
                }
                return "Run \(state.run): \(state.written)/\(state.target)"
            }
        }
    #endif

    /// Dumps raw LiveViewObjects — header **and** JPEG, byte for byte as the camera sent them —
    /// so peaking can be developed against real frames instead of synthetic blur.
    ///
    /// Why the whole object and not just the JPEG: the header carries the AF boxes, the focus
    /// result and the delivered size/compression grade, so one blob re-parses offline into
    /// everything `PTPLiveViewObject.frame(from:)` produces. It also settles, from real bytes,
    /// whether the focus result at header offset 42 is populated in manual focus — no fixture in
    /// the repo covers that today, and it is the mode peaking is actually used in.
    ///
    /// Why one frame a second: capture while racking focus slowly end to end and the result is a
    /// sweep of a single static scene — same lens, same exposure, same compression, only focus
    /// varying. That makes the sharpest frame an objective in-focus reference and the extremes
    /// objective defocused ones, which is exactly what synthetic blur cannot provide and what the
    /// day's regressions slipped through for want of.
    ///
    /// Retrieve with Xcode → Window → Devices and Simulators → the app → Download Container, or
    /// `xcrun devicectl device copy from`. Debug-only; the Release build compiles to a no-op.
    static func captureLiveViewObject(_ data: Data) {
        #if DEBUG
            let index: Int? = captureState.withLock { state in
                let now = Date()
                guard let beginsAt = state.beginsAt, now >= beginsAt,
                    state.written < state.target,
                    now.timeIntervalSince(state.lastWrite) >= captureInterval
                else { return nil }
                state.lastWrite = now
                state.written += 1
                return state.written - 1
            }
            guard let index else { return }
            let (limit, run) = captureState.withLock { ($0.target, $0.run) }
            guard let directory = captureDirectory else { return }
            let url = directory.appendingPathComponent(
                String(format: "liveview-r%02d-%02d.bin", run, index))
            do {
                try data.write(to: url)
                print(
                    "[capture] run \(run) frame \(index + 1)/\(limit) → \(url.lastPathComponent)"
                        + " (\(data.count) bytes)")
            } catch {
                print("[capture] frame \(index) failed: \(error)")
            }
        #endif
    }
}

#if DEBUG
    extension DemoHarness {
        /// The DISP mode a capture is aimed at: the Edit view's mode when one is named, else the
        /// mode the run launches into.
        static func demoDispMode(_ env: [String: String]) -> MonitorDisplayMode? {
            if let raw = env["ZC_DEMO_CHROME_EDIT"], let mode = MonitorDisplayMode(rawValue: raw) {
                return mode
            }
            return env["ZC_DEMO_DISP"].flatMap(MonitorDisplayMode.init(rawValue:))
        }

        /// The existing hooks a review screen means: the demo session for the monitor screens, with
        /// the EV meter on as every app's review shows it (the camera's reading in sixths when the
        /// review names one). The cameras page and the staged clips have none;
        /// `applyLaunchEnvironment` stages them.
        private static func hooks(for review: ReviewLaunch) -> [String: String] {
            var session = [
                "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_ASSIST_ON": "EV",
            ]
            session["ZC_DEMO_EV"] = review.meteredEV.map { String(Int(($0 * 6).rounded())) }
            switch review.screen {
            case .cameras: return [:]
            case .pair: return ["ZC_DEMO_WIZARD_STEP": "0"]
            case .live: return session
            case .settings:
                // The tab hook takes the case name ("storage").
                let tab = review.settingsTab.map { String(describing: $0) } ?? "link"
                return session.merging(["ZC_DEMO_PANEL": "settings", "ZC_DEMO_PANEL_TAB": tab]) {
                    $1
                }
            case .chromeEdit: return session.merging(["ZC_DEMO_CHROME_EDIT": "live"]) { $1 }
            case .media, .playback:
                let open = ["ZC_DEMO_OPEN_MEDIA": review.screen == .playback ? "play" : "1"]
                return review.connected ? session.merging(open) { $1 } : open
            }
        }

        /// Stages the model from the launch environment (`SIMCTL_CHILD_ZC_DEMO_*` via
        /// `simctl launch`). No effect in normal launches.
        @MainActor static func applyLaunchEnvironment(to model: NativeAppModel) async {
            let env = environment
            if let review, review.screen == .media || review.screen == .playback {
                // The clips exist before anything below lists them.
                await stageReviewMedia(review, in: model)
            }
            // Load the numbered feed before checking AUTOSTART so a later ⌘O entry can use it. A
            // normal Xcode Run gets the checkout fallback; simctl may override it with
            // ZC_DEMO_FEED_DIR. The personal stills are read locally and never enter the app bundle.
            #if targetEnvironment(simulator)
                let localDemoFallback = DemoFeedImageDiscovery.localCheckoutFeedPath
            #else
                let localDemoFallback: String? = nil
            #endif
            model.demoFeedImagePaths = DemoFeedImageDiscovery.launchImagePaths(
                environment: env, fallbackDirectoryPath: localDemoFallback)
            if env["ZC_DEMO_AUTOSTART"] == "1" {
                model.startDemoSession()
                if focusRackFixture != nil, env["ZC_DEMO_FOCUS_RACK_AUTOOPEN"] != "0" {
                    model.openFocusRack()
                }
                if env["ZC_DEMO_GRAPHICAL_REVIEW"] == "1" {
                    model.seedGraphicalReviewTimecode()
                }
                if env["ZC_DEMO_QUICK_SETTINGS"] == "1" {
                    model.seedQuickDemoCamera()
                }
                if env["ZC_DEMO_BLUETOOTH_SHUTTER"] == "1" {
                    // Physical-device diagnostic: enter an immediately recordable monitor with the
                    // opt-in active, so a real HID shutter can be tested without a Nikon session.
                    model.preferences.bluetoothShutterEnabled = true
                }
                // Seed a face + eye AF box pair (mirroring a real ZR subject-detection frame, in the
                // header's 6048×3400 space) so the focus overlay — and the selected eye box — is
                // visible in the demo. Tapping the feed moves it. ZC_DEMO_FOCUSBOX overrides.
                model.demoSeedFocusPair()
                if model.liveFrameImage == nil {
                    model.demoSelectFeedImage(1)
                }
                if let raw = env["ZC_DEMO_FEED_ROTATION"].flatMap(UInt8.init),
                    let rotation = PTPLiveViewRotation(rawValue: raw)
                {
                    // Vertical-mode capture: stage the body-rotation byte (1 grip up, 2 grip
                    // down, 3 upside down) so the rotated feed layout can be screenshot
                    // without a camera. The demo still is landscape, so its content reads
                    // sideways — exactly what a vertically held body sends before rotation.
                    model.liveFeedRotation = rotation
                }
                if env["ZC_DEMO_CODEC_DESCRIPTOR"] == "1" {
                    // Demo/screenshot affordance: stage a Z6III-shaped `MovFileType` descriptor
                    // (H.264 8-bit, plus H.265 at BOTH depths) and put the body on H.265 10-bit,
                    // so the CODEC picker's advertised rows — and the bit-depth pair the
                    // two-variant family earns — can be captured without a camera.
                    model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
                        fromEnum: [0x0000_0801, 0x0001_0800, 0x0001_0A00, 0x0031_0A03])
                    model.applyDemoProperty(
                        .movieFileType,
                        data: PTPCameraPropertyWrite.fileType(raw: 0x0001_0A00).data)
                    // SIMULATED tone descriptor: H.265 offers SDR, HLG and N-Log; on N-Log.
                    model.cameraMovieTones[.movieH265ToneMode] = [.sdr, .hlg, .nLog]
                    model.applyDemoProperty(.movieH265ToneMode, data: Data([1]))
                }
                if let raw = env["ZC_DEMO_PICKER"], let picker = CameraPicker(rawValue: raw) {
                    // ZC_DEMO_PICKER_MODE opens the picker on a specific mode tab (e.g. WB Tint).
                    model.showPicker(
                        picker, mode: env["ZC_DEMO_PICKER_MODE"].flatMap(Int.init) ?? 0)
                }
                if let raw = env["ZC_DEMO_ASSIST_OPTIONS"],
                    let tool = MonitorAssistTool(rawValue: raw)
                {
                    // Opens a view-assist options popup (falseColor/zebra/…) for headless
                    // popup-layout captures.
                    model.presentAssistOptions(tool)
                }
                if let raw = env["ZC_DEMO_DISP"], let mode = MonitorDisplayMode(rawValue: raw) {
                    // Demo/screenshot affordance: launch straight into a DISP mode (live/clean/
                    // command) for headless mode-state captures.
                    model.operatorSession.declare(modes: model.displayModes)
                    model.operatorSession.select(mode)
                }
                if let raw = env["ZC_DEMO_RELAY_END_AFTER"], let seconds = Int(raw) {
                    // Verification affordance: a deliberate operator disconnect on a timer, so
                    // the broadcast-ended path (watchers kicked to the camera list) can be
                    // proven from a second simulator without tapping this one.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                        model.disconnect()
                    }
                }
                if let holder = env["ZC_DEMO_RELAY_HOLDER"], !holder.isEmpty {
                    // Demo/screenshot affordance: stage the surrendered-control broadcast state
                    // (a watcher holds the token) so the dimmed strip + REVOKE pill are
                    // capturable without a second device.
                    model.isRelayBroadcasting = true
                    model.relayControlHeldBy = holder
                }
                if env["ZC_DEMO_RECORDING"] == "1" {
                    // Demo/screenshot affordance: stage the recording state (REC chip, tally
                    // border, stop-square record button) without tapping the record control.
                    model.isRecording = true
                    model.cameraState = model.cameraState.updating(recordState: .recording)
                }
                if env["ZC_DEMO_PHOTO"] == "1" {
                    // Stage photography chrome (compact stills strip + rail shutter, no assist).
                    model.demoTogglePhotographyMode()
                }
                if let raw = env["ZC_DEMO_SHOTS"], let shots = UInt32(raw) {
                    // Demo/screenshot affordance: a long remaining-shots count (the photo header
                    // readout against the Dynamic Island).
                    model.applyDemoProperty(
                        .exposureRemaining, data: Data(ByteCoding.uint32LE(shots)))
                }
                if let label = env["ZC_DEMO_PHOTO_AREA"],
                    let area = StillImageArea.area(forLabel: label)
                {
                    // Demo/screenshot affordance: stage a photo image area ("FX"/"DX"/"1:1"/
                    // "16:9") so aspect-dependent chrome states capture headlessly.
                    model.setStillImageArea(area)
                }
                if let raw = env["ZC_DEMO_EV"], let sixths = Int8(raw) {
                    // Demo/screenshot affordance: light the EV meter with a fixed needle.
                    model.applyDemoProperty(
                        .exposureIndicateStatus, data: Data([UInt8(bitPattern: sixths)]))
                    model.applyDemoProperty(.exposureIndicateLightup, data: Data([0]))
                    model.setAssist(.evMeter, visible: true)
                }
                if let raw = env["ZC_DEMO_APP_TIMER"], Int(raw) != nil {
                    // Demo/screenshot affordance: arm the app self-timer so the countdown
                    // (beeper + tally border pulse) captures headlessly.
                    model.setPhotoTimer(label: "\(raw)s")
                }
                if let raw = env["ZC_DEMO_INSTANT_REVIEW"] {
                    // Arms the REVIEW tool and fires one demo release so the post-capture
                    // review overlay captures headlessly; "hold" pins it up (∞ duration);
                    // "lowres" pins the blurred stand-in + spinner phase instead.
                    if raw == "hold" || raw == "lowres" {
                        model.assistConfiguration.instantReviewSeconds = 0
                    }
                    model.setAssist(.instantReview, visible: true)
                    if raw == "lowres" {
                        if let image = model.liveFrameImage ?? UIImage(named: "MockFeed") {
                            model.presentInstantReview(image, isFullResolution: false)
                        }
                    } else {
                        model.captureStill()
                    }
                }
                if env["ZC_DEMO_WATCHER"] == "1" {
                    // Watcher-chrome screenshot hook: the demo feed keeps pumping frames, but the
                    // chrome derives from availability — `.relay` source WITHOUT camera control
                    // (the demo session normally counts as control, so suppress it) unmounts
                    // record/capture and arms the freed-band zone refinement, exactly as on a
                    // real joined watcher.
                    model.videoSource = .relay
                    model.demoSuppressesCameraControl = true
                }
                if env["ZC_DEMO_RELAY_HOST"] == "1" {
                    // Verification affordance: broadcast the demo still through the real relay
                    // path so a second simulator can join and prove the whole chain. Demo-only, so
                    // the ticker deliberately runs for the app's lifetime.
                    if let code = env["ZC_DEMO_RELAY_PASSCODE"] {
                        // Before the broadcast starts, so the listener comes up already gated.
                        model.setRelayWatcherPasscode(code)
                    }
                    model.setRelayBroadcasting(true)
                    if env["ZC_DEMO_RELAY_GRANT"] == "1" {
                        // Auto-answer the first request so the grant path runs without a tap.
                        Task { @MainActor in
                            for _ in 0..<200 {
                                if model.relayPendingControlRequest != nil {
                                    model.grantRelayControl()
                                    return
                                }
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                        }
                    }
                    Task { @MainActor in
                        while !Task.isCancelled {
                            model.demoBroadcastRelayFrame()
                            try? await Task.sleep(for: .milliseconds(33))
                        }
                    }
                }
                if let raw = env["ZC_DEMO_HDMI_SOURCE"] {
                    // Stages the HDMI picture source. The simulator has no UVC device to attach,
                    // so the mock feed stands in for the captured picture and only the resulting
                    // state is staged. `hybrid` keeps the simulated camera behind it (control
                    // chrome stays, header-fed overlays go); anything else is the capture-only
                    // monitor, where every camera affordance has to disappear.
                    model.videoSource = .hdmiCapture
                    model.hdmiCaptureState = .streaming(
                        deviceName: "Capture Device", format: "1920×1080 @30")
                    model.demoSuppressesCameraControl = raw != "hybrid"
                    if raw != "hybrid" { model.cameraState = .blank }
                }
                if let raw = env["ZC_DEMO_LUT"] {
                    // Demo/screenshot affordance: seed a LUT and switch the tool on. `custom:<file>`
                    // selects a stored custom cube; otherwise the value names a built-in look.
                    if raw.hasPrefix("custom:") {
                        model.assistConfiguration.selectedLUT = .stored(
                            category: .custom, fileName: String(raw.dropFirst("custom:".count)))
                        model.setAssist(.lut, visible: true)
                    } else if let look = MonitorLUT(rawValue: raw) {
                        model.assistConfiguration.selectedLUT = .builtIn(look)
                        model.setAssist(.lut, visible: true)
                    }
                }
                if let raw = env["ZC_DEMO_SPLIT"] {
                    // Demo/screenshot affordance: stage the 50/50 Log-vs-LUT comparison.
                    // `vertical` / `horizontal`; anything else switches it off.
                    let orientation: SplitComparisonOrientation? =
                        switch raw {
                        case "vertical": .vertical
                        case "horizontal": .horizontal
                        default: nil
                        }
                    model.assist.splitComparison = orientation != nil
                    if let orientation {
                        model.assist.splitVertical = orientation == .vertical
                    }
                }
                if let path = env["ZC_DEMO_RED_ZIP"] {
                    Task { await model.importRedZip(from: URL(fileURLWithPath: path)) }
                }
                if let path = env["ZC_DEMO_FEED_IMAGE"], let still = UIImage(contentsOfFile: path) {
                    // Demo/screenshot affordance: show an arbitrary still (e.g. a real camera
                    // frame for marketing captures) instead of the MockFeed asset. Set before the
                    // assist seeding below so scopes meter this image, not the mock.
                    model.liveFrameImage = still
                }
                if env["ZC_DEMO_WATCH_FEED"] == "1" {
                    // Demo/screenshot affordance: stream the demo still to a paired Apple Watch
                    // the way the live loop would (the relay only ingests from the camera frame
                    // loop, which never runs in demo mode). Re-ingests on a slow tick so the
                    // frame survives the watch becoming reachable after launch. Demo-only, so
                    // the task deliberately runs for the app's lifetime.
                    Task { @MainActor in
                        while !Task.isCancelled {
                            if let image = model.liveFrameImage {
                                model.publishWatchState()
                                model.watchRelay.ingestFrame(
                                    image: image,
                                    applying: model.liveImageEffects,
                                    timecode: model.liveTimecode,
                                    isRecording: model.isRecording)
                            }
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                }
                if let raw = env["ZC_DEMO_ASSIST"], let tool = MonitorAssistTool(rawValue: raw) {
                    // Demo/screenshot affordance: open a tool's options panel on launch.
                    model.showAssist(tool)
                }
                if let raw = env["ZC_DEMO_FEED_ASPECT"],
                    let aspect = PortraitFeedAspect(rawValue: raw)
                {
                    // Demo/screenshot affordance: stage the portrait feed aspect (fit16x9/fill).
                    // Applied BEFORE the scope seeding below so that seeding >2 scopes in fill isn't
                    // refused by the portrait-fit 2-scope cap (which keys on `.fit16x9`); the cap is
                    // inactive in fill, so all requested scopes activate and persist their order.
                    model.preferences.portraitFeedAspect = aspect
                }
                if let raw = env["ZC_DEMO_PARADE_MODE"],
                    let mode = MonitorParadeMode(rawValue: raw.uppercased())
                {
                    // Demo/screenshot affordance: seed the parade lane mode (rgb/yrgb) so the GPU
                    // and CPU parade scopes can be captured in YRGB without a manual toggle.
                    model.scopePanels.parade.options.mode = mode
                }
                if let raw = env["ZC_DEMO_WAVE_MODE"],
                    let mode = MonitorWaveformMode(
                        rawValue: raw.capitalized == "Rgb" ? "RGB" : raw.capitalized)
                {
                    // Demo/screenshot affordance: seed the waveform trace mode (luma/rgb).
                    model.scopePanels.waveform.options.mode = mode
                }
                if let raw = env["ZC_DEMO_WAVE_BRIGHTNESS"], let percent = Int(raw) {
                    // Demo/screenshot affordance: waveform trace brightness percent (0 to 200).
                    model.scopePanels.waveform.options.brightness =
                        MonitorWaveformOptions.clampedBrightness(percent)
                }
                if let raw = env["ZC_DEMO_VECTOR_ZOOM"],
                    let zoom = MonitorVectorscopeZoom(rawValue: raw.lowercased())
                {
                    model.scopePanels.vectorscope.options.zoom = zoom
                }
                if let raw = env["ZC_DEMO_VECTOR_BRIGHTNESS"], let percent = Int(raw) {
                    model.scopePanels.vectorscope.options.brightness =
                        MonitorVectorscopeOptions.clampedBrightness(percent)
                }
                if let raw = env["ZC_DEMO_VECTOR_SCALE"], let scale = Double(raw) {
                    model.scopePanels.vectorscope.setScale(scale)
                }
                if env["ZC_DEMO_GUIDES_MASK"] == "1" {
                    // Demo/screenshot affordance: darken outside the selected guide frames.
                    model.assist.guideMask = true
                }
                if env["ZC_DEMO_UI_MODE"] == "1" {
                    // Demo/screenshot affordance: start in demo UI mode (same as pressing ⌘D).
                    model.demoUIMode = true
                }
                if let raw = env["ZC_DEMO_FALSE_SCALE"],
                    let scale = FalseColorScale(rawValue: raw)
                {
                    // Demo/screenshot affordance: stage the Stops, IRE, or Limits false-colour ruler.
                    model.assist.falseColorScale =
                        switch scale {
                        case .stops: .sceneStops
                        case .video: .stops
                        case .ire: .ire
                        case .limits: .limits
                        }
                }
                if let raw = env["ZC_DEMO_PANEL_POS"] {
                    // Demo/screenshot affordance: place floating assist panels at normalized
                    // viewport positions, e.g. "wave:0.25,0.30;traffic-lights:0.08,0.58".
                    for entry in raw.split(separator: ";") {
                        let parts = entry.split(separator: ":")
                        guard parts.count == 2 else { continue }
                        let coords = parts[1].split(separator: ",").compactMap { Double($0) }
                        guard coords.count == 2 else { continue }
                        let center = CGPoint(x: coords[0], y: coords[1])
                        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                        if let tool = NikonScopePanels.legacyPanelIDs[String(parts[0])] {
                            // The unit square counts as landscape, the slot the demo stages.
                            model.scopePanels.slot(for: tool).store(center: center, in: unit)
                        } else {
                            model.movablePanelPositions[String(parts[0])] =
                                MovablePanelStoredCenter(center: center, in: unit)
                        }
                    }
                }
                if let raw = env["ZC_DEMO_CLEAN_PIN"] {
                    // Demo/screenshot affordance: pin assist tools to clean view (comma-separated
                    // raw values, e.g. "WAVE,GUIDES") so DISP 2 can be captured both bare and
                    // with exactly one tool kept.
                    for value in raw.split(separator: ",") {
                        if let tool = MonitorAssistTool(rawValue: String(value)) {
                            model.assist.cleanViewPinnedTools.insert(tool.selection)
                        }
                    }
                }
                if let raw = env["ZC_DEMO_CHROME_HIDE"] {
                    // Demo/screenshot affordance: hide monitor-chrome sections (comma-separated
                    // `MonitorDisplayChrome.Section` raw values or the retired Nikon names, e.g.
                    // "lockButton,railMedia,focusBox") so each hidden state can be captured
                    // headlessly — simctl cannot drive the Settings switches. Applies to the DISP
                    // mode named by `ZC_DEMO_CHROME_EDIT`/`ZC_DEMO_DISP`, else the current one,
                    // in the shared per-DISP chrome.
                    let target = Self.demoDispMode(env) ?? model.displayMode
                    for value in raw.split(separator: ",") {
                        // The short names the earlier hooks used, the retired Nikon section names,
                        // then the shared section raw values.
                        let sections: [MonitorDisplayChrome.Section] =
                            switch value {
                            case "lock", "lockButton": [.lockButton]
                            case "battery", "batteryIndicators": [.batteries]
                            case "topbar": [.statusBar]
                            case "toolbar", "assistToolbar": [.toolBar]
                            case "values": [.cameraValues]
                            case "timecodeReadout": [.timecode]
                            case "resolutionReadout": [.format]
                            case "codecReadout": [.codec]
                            case "mediaReadout": [.storage]
                            case "fpsReadout": [.fps]
                            // "rail" is the retired whole-rail blob: the rail controls.
                            case "rail": [.railRecord, .railMedia, .railSettings]
                            default:
                                MonitorDisplayChrome.Section(rawValue: String(value)).map { [$0] }
                                    ?? []
                            }
                        for section in sections
                        where model.operatorSession.chrome(for: target).isVisible(section) {
                            model.operatorSession.toggle(section, in: target)
                        }
                    }
                }
                if let mode = Self.demoDispMode(env), env["ZC_DEMO_CHROME_EDIT"] != nil {
                    // Demo/screenshot affordance: open the Edit view on one DISP mode
                    // (ZC_DEMO_CHROME_EDIT=live|clean|command). simctl cannot tap the Settings
                    // button, and the eye badges only exist while the editor is up.
                    model.beginChromeEditing(mode)
                }
                if let raw = env["ZC_DEMO_ASSIST_ON"] {
                    // Demo/screenshot affordance: switch one or more assist tools on (comma-separated
                    // raw values, e.g. "FALSE,PEAK,WAVE") so the live monitor tools can be captured.
                    for value in raw.split(separator: ",") {
                        if let tool = MonitorAssistTool(rawValue: String(value)) {
                            model.setAssist(tool, visible: true)
                            if tool == .desqueeze {
                                model.assist.desqueezeFactor = 2
                                model.assist.desqueezeCustom = false
                            }
                        }
                    }
                    if model.assist.liveTools.contains(.audioMeters) {
                        model.demoSeedAudioMonitor()
                    }
                    // The demo has no live stream, so seed the scopes from the demo frame once.
                    // Keyed on the switched-on set, not the mode-filtered render set, so a clean-
                    // view capture with a pinned scope still gets samples (hence every scope).
                    let scopesOn = MonitorAssistTool.scopeTools.contains {
                        model.assist.liveTools.contains($0)
                    }
                    if scopesOn,
                        let mock = model.liveFrameImage ?? UIImage(named: "MockFeed")
                    {
                        Task { await model.refreshScopes(from: mock, full: true) }
                    }
                }
                if env["ZC_DEMO_SCOPE_SAMPLES"] == "1",
                    let mock = model.liveFrameImage ?? UIImage(named: "MockFeed")
                {
                    // Demo/screenshot affordance: seed the scope plots from the mock feed so
                    // waveform / parade / histogram traces render without a live stream (the demo
                    // session never runs the live-view loop). Unlike the ZC_DEMO_ASSIST_ON seed
                    // above, this is unconditional and samples full data, so scope surfaces that
                    // aren't live-view assist tools (the portrait scopes frame) get traces too.
                    Task { await model.refreshScopes(from: mock, full: true) }
                }
                if let raw = env["ZC_DEMO_POPOVER"], let picker = CameraPicker(rawValue: raw),
                    picker.isTopBar
                {
                    model.showPicker(picker)
                }
                if env["ZC_DEMO_CHARGING"] == "1" {
                    model.cameraBatteryCharging = true
                }
                if let raw = env["ZC_DEMO_PLAYBACK_ASSIST_ON"] {
                    // Demo/screenshot affordance: seed playback view-assist tools (comma-separated
                    // raw values, e.g. "WAVE,PARADE") so clip-player scopes can be captured headless.
                    model.assist.playbackVisibleTools.formUnion(
                        raw.split(separator: ",").compactMap {
                            MonitorAssistTool(rawValue: String($0))?.selection
                        })
                }
                if env["ZC_DEMO_OPEN_MEDIA"] != nil {
                    // Demo/screenshot affordance: open the Media browser on launch (any value). Pair
                    // with a clip pushed into Documents/media/<bucket>/ via simctl to capture the
                    // populated grid. Value `play` additionally opens the player (see MediaBrowserView).
                    // Sets both entry points so the browser opens whether or not a camera session
                    // is active (`activePanel` only renders through the monitor; the standalone
                    // cover is what a disconnected/fresh-install demo actually reaches).
                    model.refreshMediaClips()
                    model.activePanel = .media
                    model.isStandaloneMediaLibraryPresented = true
                }
                // Demo/screenshot affordances: engage the interface lock, lock the focus point, or
                // show the recording tally.
                if env["ZC_DEMO_LOCK"] == "1" { model.interfaceLocked = true }
                if env["ZC_DEMO_SCOPE_TOAST"] == "1" {
                    // Demo/screenshot affordance: fire the scope-cap toast shortly after launch (once
                    // the shell is mounted) so the self-dissolving capsule can be captured headlessly.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.5))
                        model.showMonitorNotice(model.scopeCapNoticeText)
                    }
                }
                if env["ZC_DEMO_FOCUSLOCK"] == "1" { model.focusPointLocked = true }
                if env["ZC_DEMO_LEVELGAUGE"] == "1" {
                    model.assistConfiguration.level.style = .gauge
                }
                if let raw = env["ZC_DEMO_LEVEL"] {
                    // Demo/screenshot affordance: seed the camera virtual-horizon angles
                    // ("roll,pitch" in degrees) so the off-level gauge visuals can be captured
                    // without a live body.
                    let parts = raw.split(separator: ",").compactMap { Double($0) }
                    if let roll = parts.first { model.cameraLevelRoll = roll }
                    if parts.count > 1 { model.cameraLevelPitch = parts[1] }
                }
                if env["ZC_DEMO_REC"] == "1" {
                    model.cameraState = model.cameraState.updating(recordState: .recording)
                }
                if let raw = env["ZC_DEMO_SESSION_LOST"] {
                    // Demo/screenshot affordance: stage the dropped-session recovery affordance
                    // over the held frame (`retrying` mid-loop, `storm` = drop-storm pause,
                    // anything else = budget spent), so the #253/#254 recovery UI can be
                    // captured without unplugging a real camera.
                    model.connectionProgressDeviceName = "Nikon ZR"
                    let staged: SessionRecoveryState =
                        switch raw {
                        case "retrying": .retrying(attempt: 2, maxAttempts: 8)
                        case "storm": .pausedAfterRepeatedDrops(drops: 3)
                        default: .waitingForOperator(attemptsMade: 8)
                        }
                    model.forceSessionRecoveryState(staged)
                }
                if let raw = env["ZC_DEMO_DISP"], let mode = MonitorDisplayMode(rawValue: raw) {
                    // Demo/screenshot affordance: start in a specific display mode (live/clean/command).
                    model.operatorSession.declare(modes: model.displayModes)
                    model.operatorSession.select(mode)
                }
                if env["ZC_DEMO_PANEL"] == "settings" {
                    // Demo/screenshot affordance: open Operator Setup on launch (tab via
                    // ZC_DEMO_PANEL_TAB).
                    model.operatorSettingsTab = MonitorSettingsTab.demoLaunchTab
                    model.activePanel = .settings
                }
                if env["ZC_DEMO_FOCUSBOX"] == "1" {
                    // Synthetic face-tracking boxes so the overlay is visible without a live camera.
                    model.liveViewFocus = PTPLiveViewFocusInfo(
                        coordinateWidth: 1000,
                        coordinateHeight: 562,
                        focusResult: .unknown,  // idle box 0 next to green faces, not all-green
                        subjectDetectionActive: true,
                        selectedBoxIndex: 0,
                        boxes: [
                            PTPLiveViewAFBox(centerX: 420, centerY: 250, width: 180, height: 200),
                            PTPLiveViewAFBox(centerX: 730, centerY: 300, width: 130, height: 150),
                        ]
                    )
                }
            }
            if superResolutionStage == "input" {
                FeedUpscaleSwitch.shared.presentsSuperResolutionInput = true
            }
            if let strength = liveDenoiseStrength {
                LiveDenoiseSwitch.shared.strength = strength
                LiveDenoiseSwitch.shared.enabled = strength > 0
            }
            if let upscaler = forcedFeedUpscaler {
                // Outside the AUTOSTART block: the settings row that shows this is reachable
                // without a demo session, and a real camera session is the point of the A/B.
                // Through `supported(or:)` like every other entry — naming an upscaler this device
                // does not have must land somewhere real, not on a setting that reads as active.
                FeedUpscaleSwitch.shared.upscaler = .supported(or: upscaler)
            }
            if env["ZC_DEMO_OPEN_RED"] != nil {
                // Demo/screenshot affordance: open the RED download cover on launch (pair with
                // ZC_DEMO_RED_BLOCKED to stage its blocked gateway).
                model.isRedDownloadPresented = true
            }
            if env["ZC_DEMO_OPEN_SETTINGS"] != nil {
                // Demo/screenshot affordance: open the standalone Operator Setup as the startup
                // home's Settings button would, optionally selecting ZC_DEMO_PANEL_TAB.
                model.openStandaloneSettings()
                if let rawTab = env["ZC_DEMO_PANEL_TAB"] {
                    model.operatorSettingsTab = MonitorSettingsTab.demoLaunchTab(rawTab)
                }
            }
            if openBugReport {
                // The form lives above standalone Operator Setup. Selecting System keeps the
                // normal presentation path visible beneath it if a screenshot closes the form.
                model.openStandaloneSettings()
                model.operatorSettingsTab = .system
            }
            if let destination = SettingsInternetDestination.demoValue(internetHandoffProgress) {
                model.beginInternetDestinationPreparation(destination.title)
            }
            if let raw = env["ZC_DEMO_ORIENTATION"] {
                // Demo/screenshot affordance: force the interface orientation so headless
                // verification can reach BOTH layouts — simctl has no rotation API and scripted
                // Simulator keystrokes need an Accessibility grant. "landscape" or "portrait".
                let scenes = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                let mask: UIInterfaceOrientationMask =
                    switch raw {
                    // "landscape" keeps its historical meaning (interface LandscapeRight, notch
                    // left) so existing capture scripts stay valid; the explicit names reach each
                    // side now that Info.plist allows both.
                    case "landscape", "landscapeRight": .landscapeRight
                    case "landscapeLeft": .landscapeLeft
                    default: .portrait
                    }
                scenes.first?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
            if let raw = env["ZC_DEMO_FEED_ASPECT"], env["ZC_DEMO_AUTOSTART"] != "1",
                let aspect = PortraitFeedAspect(rawValue: raw)
            {
                // Demo/screenshot affordance: stage the portrait feed aspect (fit16x9/fill). Under
                // AUTOSTART this is applied earlier (before scope seeding) — see above; this branch
                // covers the non-autostart launch path.
                model.preferences.portraitFeedAspect = aspect
            }
            if let endpoint = env["ZC_DEMO_RELAY_JOIN_HOST"],
                let colon = endpoint.lastIndex(of: ":"),
                let port = UInt16(endpoint[endpoint.index(after: colon)...])
            {
                // Direct-endpoint join (host:port), bypassing Bonjour — cross-platform wire
                // verification through adb forward, where mDNS cannot cross network segments.
                let host = String(endpoint[..<colon])
                model.joinRelay(
                    MonitorRelayDiscovery(
                        id: "direct", name: "Direct",
                        endpoint: .hostPort(
                            host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port) ?? 15_750)))
            }
            if env["ZC_DEMO_RELAY_JOIN"] == "1" {
                // Verification affordance: browse for a broadcasting device and join the first one
                // that appears, so the viewer half needs no taps to reach.
                if let code = env["ZC_DEMO_RELAY_JOIN_PASSCODE"] {
                    // Stands in for the code the operator typed on a previous join.
                    model.demoRelayJoinPasscode = code
                }
                Task { @MainActor in
                    model.startRelayBrowsing()
                    for _ in 0..<120 {
                        if let host = model.discoveredRelayHosts.first {
                            model.joinRelay(host)
                            // Verification affordance: also exercise the control handshake, so a
                            // two-simulator run proves request -> grant -> drive end to end.
                            if env["ZC_DEMO_RELAY_CONTROL"] == "1" {
                                try? await Task.sleep(for: .milliseconds(1200))
                                model.requestRelayControl()
                            }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            if let raw = env["ZC_DEMO_WIZARD_TRANSPORT"],
                let method = NativeAppModel.FirstPairTransportMethod(rawValue: raw)
            {
                // Demo/screenshot affordance: stage the wizard's transport choice
                // ("cameraAccessPoint" / "phoneHotspot" / "usbC") so a jumped-to step renders
                // the state a real flow would have (step count, per-transport buttons/copy).
                model.firstPairTransportMethod = method
            }
            if let raw = env["ZC_DEMO_WIZARD_STEP"], let value = Int(raw),
                let step = NativeAppModel.FirstPairWizardStep(rawValue: value)
            {
                // Demo/screenshot affordance: jump the first-pair wizard to a step (raw 0-4).
                // Steps past permissions are otherwise unreachable headless (they need taps).
                // Pair with ZC_DEMO_WIZARD_TRANSPORT for steps whose content is per-transport.
                // The pairing flag makes the wizard show even when saved cameras exist
                // (`shouldShowFirstPairWizard` is the pairing flag only).
                model.isPairingNewCamera = true
                model.firstPairWizardStep = step
            }
            if env["ZC_DEMO_FRESH_INSTALL"] == "1" {
                // SIMULATED fresh install: no saved camera and no camera-list choice yet. Only
                // this simulator's demo records are forgotten; nothing is dialled.
                for record in NativeCameraConnectionStore.shared.savedCameras() {
                    NativeCameraConnectionStore.shared.forgetPairing(host: record.host)
                }
                model.savedCameras = NativeCameraConnectionStore.shared.savedCameras()
                model.showsCameraListWithoutSavedCameras = false
                model.cameras.reloadSaved()
            }
            if env["ZC_DEMO_CAMERA_LIST"] == "1" {
                // Demo/screenshot affordance: land on the camera-list home even with zero saved
                // cameras — the watcher's destination behind the wizard's "Open the camera list"
                // row, otherwise unreachable headless (it needs that tap).
                model.showSavedCameras()
            }
            if env["ZC_DEMO_SAVED_PATHS"] == "1" {
                // Stages the multi-path camera list: the SAME body saved via hotspot, router
                // and cable (one serial, three records) beside a second single-path body.
                // Seeds the real store — simulator-only residue, cleared by uninstall.
                let store = NativeCameraConnectionStore.shared
                store.upsertSavedCamera(
                    host: "172.20.10.2", displayName: "ZR_6002199", transport: "Wi-Fi",
                    onCameraAccessPoint: false, serialNumber: "6002199")
                store.upsertSavedCamera(
                    host: "10.99.0.20", displayName: "ZR_6002199", transport: "Wi-Fi",
                    onCameraAccessPoint: false, serialNumber: "6002199")
                // A SECOND router on another subnet — the two-router state is only reachable
                // headless from here, and it is the one the chip qualifier exists for.
                store.upsertSavedCamera(
                    host: "192.168.129.66", displayName: "ZR_6002199", transport: "Wi-Fi",
                    onCameraAccessPoint: false, serialNumber: "6002199")
                store.upsertSavedCamera(
                    host: "usb:demo-zr", displayName: "ZR_6002199", transport: "USB-C",
                    serialNumber: "6002199")
                // A ZR-shaped name so the access-point SSID derives, which is what makes this an
                // access-point setup you can actually JOIN — and the only way the tab's
                // ready-to-join ring is reachable headless. A name that derives no SSID is a real
                // state too, but it renders as the plain dark dot.
                store.upsertSavedCamera(
                    host: "192.168.1.1", displayName: "ZR_7005555", transport: "Wi-Fi",
                    onCameraAccessPoint: true, serialNumber: "7005555")
                model.showSavedCameras()
            }
            if env["ZC_DEMO_NEARBY"] == "1" {
                // A camera on this network that is not saved, and one another device holds.
                model.nikonPort.demoSightings = [
                    DiscoveredCamera(ip: "192.168.1.44", name: "Z8_4005555", source: .bonjour),
                    DiscoveredCamera(
                        ip: "192.168.1.45", name: "Z6_3001234", source: .heldByAnotherDevice,
                        heldByDeviceName: "Director's iPad"),
                ]
                model.nikonPort.found(model.discoveredCameras)
            }
            if let outcome = env["ZC_DEMO_CARD"] {
                // Stages the shared card on the first saved camera without dialling anything:
                // "connecting" holds it on its steps, "failed" fails it with the funnel's copy.
                model.nikonPort.demoOutcome = outcome
                if let camera = model.cameras.saved.first { model.cameras.connect(camera) }
            }
            if let mode = env["ZC_DEMO_CONNECT_PREPARING"] {
                // SIMULATED post-handshake state with shared or app-owned progress: an
                // established session still waiting for its first frame. No session, network
                // command or first frame is created by this fixture. (`.connected` also ends the
                // discovery loop, which would otherwise overwrite a staged state.)
                // "neverStarted": live view did not start, so the progress sheet is gone.
                model.connection = .connected
                model.isConnectionProgressPresented = mode != "neverStarted"
                model.connectionProgressDeviceName = "SIMULATED ZR"
                model.connectionPhase = .preparingLiveView
                model.connectionProgressUsesCard = mode != "standalone" && mode != "neverStarted"
                model.connectionMessage =
                    mode == "neverStarted"
                    ? "SIMULATED live view did not start." : "Reading camera settings…"
            }
            if let entry = env["ZC_DEMO_CONNECT_CONSENT"] {
                // SIMULATED consent on actual model paths; the test only cancels, and the integration port is staged.
                let held = DiscoveredCamera(
                    ip: "192.0.2.45", name: "SIMULATED camera", source: .heldByAnotherDevice,
                    heldByDeviceName: "SIMULATED other phone")
                model.nikonPort.demoOutcome = "connecting"
                if entry == "direct" {
                    model.connectToCamera(held)
                } else {
                    _ = model.cameras
                    model.nikonPort.demoSightings = [held]
                    model.nikonPort.found([])
                    for _ in 0..<100
                    where !model.cameras.nearby.contains(where: { $0.id == held.id }) {
                        await Task.yield()
                    }
                    if let sighting = model.cameras.nearby.first(where: { $0.id == held.id }) {
                        model.cameras.connect(sighting)
                    }
                }
            }
            if let raw = env["ZC_DEMO_HOTSPOT_CARD"] {
                // Stages the hotspot-recovery strip on the camera list ("active" / "needed") —
                // the real prompt derives from saved records plus live hotspot state, so
                // neither state is reachable headless.
                let camera = PTPIPSavedCameraRecord(
                    host: "172.20.10.2", displayName: "ZR_6002199", transport: "Wi-Fi",
                    lastSeenAt: nil)
                model.demoRecoveryPromptOverride =
                    raw == "needed"
                    ? .enableIPhoneHotspot(camera) : .waitForIPhoneHotspotCamera(camera)
                model.showSavedCameras()
            }
            if let raw = env["ZC_DEMO_JOIN_POPUP"] {
                // Demo/screenshot affordance: stage the scanned-credentials join popup over the
                // startup screen — the scanner itself needs a physical camera screen to point at.
                // The value picks the staged phase: "joining"/"failed", anything else ⇒ ready.
                // "scan" stages it keyless — the "+ Add setup → Camera AP" shape, where the
                // card's own button has to open the scanner over this sheet.
                if raw == "scan" {
                    model.applyManualCameraWiFi(ssid: "NIKON_ZR_01234", key: "")
                } else {
                    model.applyScannedCameraWiFi(ssid: "NIKON_ZR_01234", key: "a1b2c3d4")
                }
                if raw == "joining" {
                    model.connectionPhase = .joiningWiFi
                } else if raw == "confirm" {
                    model.connectionPhase = .confirmOnCamera
                } else if raw == "failed" {
                    model.connectionPhase = .failed
                    model.connectionMessage =
                        "Couldn't reach the camera Wi‑Fi network. Make sure the camera is on and nearby, then try again."
                }
            }
            if cameraWiFiScannerMode != nil {
                // Demo/screenshot affordance: the real scanner is normally entered from the
                // camera-connection flow and needs a physical camera screen to exercise.
                model.isCameraWiFiScannerPresented = true
            }
            if let count = env["ZC_DEMO_MULTICAM"].flatMap(Int.init) {
                stageMulticam(count: count, env: env, model: model)
            }
            switch review?.screen {
            case .cameras?:
                stageReviewCamera(model)
            case .media?, .playback?:
                if review?.connected == true {
                    // The demo session has no card to list, so the Media panel it opened begins
                    // on the staged index, as a finished listing pass would. Its SIMULATED card (the
                    // shared ReviewCard over the staged handles) removes what a deletion names.
                    let card = ReviewCard(
                        clips: (0..<(review?.mediaCount ?? 0)).map {
                            MediaObjectHandle(storageID: 65_537, handle: UInt32($0 + 1))
                        })
                    model.reviewCameraDelete = { @MainActor location in
                        card.delete { $0 == location }
                    }
                    model.mediaLibrary?.begin()
                } else {
                    // The startup screen's Media: everything cached on this phone.
                    model.openCachedMediaLibrary()
                }
            default:
                break
            }
        }

        /// `ReviewLaunch` media: `mediaCount` copies of one generated playable movie in the bucket
        /// the browser lists, indexed with card handles when they stand for a camera's card. A
        /// review starts from exactly these clips.
        @MainActor private static func stageReviewMedia(
            _ review: ReviewLaunch, in model: NativeAppModel
        ) async {
            let store = model.mediaClipStore
            let bucket = model.mediaBucketID
            let files = FileManager.default
            try? files.removeItem(at: store.root)
            do {
                let directory = store.directory(for: bucket)
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                let names = (1...review.mediaCount).map { String(format: "REVIEW_%04d.MOV", $0) }
                let first = directory.appendingPathComponent(names[0])
                try await ReviewClip.write(to: first)
                for name in names.dropFirst() {
                    try files.copyItem(at: first, to: directory.appendingPathComponent(name))
                }
                let size = UInt64(try first.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let card = review.source == .camera
                // A minute apart: card clips a second apart would read as one burst series.
                let clips = names.enumerated().map { index, name in
                    MediaClip(
                        cameraID: bucket, filename: name, handle: card ? UInt32(index + 1) : nil,
                        storageID: card ? 65_537 : nil, sizeBytes: size,
                        captureDate: String(
                            format: "20261011T%02d%02d00", 8 + index / 60, index % 60))
                }
                store.upsertBatch(clips, cameraID: bucket)
            } catch {
                assertionFailure("The review clips could not be staged: \(error)")
            }
            model.mediaBrowserSource = review.source == .camera ? .camera : .iPhone
            model.mediaBrowserLayout = review.layout
        }

        /// `ReviewLaunch` cameras page: the shared kit's single saved setup, "Travel camera" on
        /// its own Wi-Fi.
        @MainActor private static func stageReviewCamera(_ model: NativeAppModel) {
            let store = NativeCameraConnectionStore.shared
            for camera in store.savedCameras() { store.forgetKnownPairing(host: camera.host) }
            store.upsertSavedCamera(
                host: "192.168.1.1", displayName: "Travel camera", transport: "Wi-Fi",
                onCameraAccessPoint: true, serialNumber: "REVIEW-TRAVEL",
                path: .cameraAccessPoint(ssid: nil))
            model.showSavedCameras()
        }

        /// Demo/screenshot affordance: `ZC_DEMO_MULTICAM=<1-4>` opens the multicam stage with that
        /// many scripted bodies (`DemoMulticamLink`) running the real pumps, plans and member
        /// queues. `ZC_DEMO_MULTICAM_LAYOUT=grid` picks Grid; `ZC_DEMO_MULTICAM_REC=1` rolls A.
        @MainActor private static func stageMulticam(
            count: Int, env: [String: String], model: NativeAppModel
        ) {
            model.beginMulticam()
            let isos: [UInt32] = [800, 400, 1600, 6400]
            let batteries: [UInt8] = [87, 60, 35, 15]
            model.multicam.connect = { record in
                let index = Int(record.serialNumber?.suffix(1) ?? "") ?? 0
                return DemoMulticamLink(
                    serialNumber: record.serialNumber ?? "", iso: isos[index % 4],
                    battery: batteries[index % 4])
            }
            if env["ZC_DEMO_MULTICAM_LAYOUT"] == "grid" { model.multicam.arrangement = .grid }
            let paths: [CameraPath] = [
                .usbC, .infrastructure(networkName: "Set"), .phoneHotspot,
                .infrastructure(networkName: "Set"),
            ]
            for index in 0..<min(4, max(0, count)) {
                let name = ["Wide", "Close", "High", "Roam"][index]
                model.multicam.add(
                    PTPIPSavedCameraRecord(
                        host: index == 0 ? "usb:demo-zr" : "10.0.0.\(20 + index)",
                        displayName: "ZR_300012\(index)",
                        transport: paths[index].legacyTransportLabel, lastSeenAt: nil,
                        presentation: PTPIPSavedCameraPresentation(customName: name),
                        serialNumber: "300012\(index)", path: paths[index]),
                    reachable: true)
            }
            if env["ZC_DEMO_MULTICAM_REC"] == "1" {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard let first = model.multicam.member(atSlot: 0) else { return }
                    await model.multicam.run(model.multicam.plan(for: first.id))
                }
            }
        }
    }

    /// Resolves numbered demo stills from the configured local-only feed directory.
    enum DemoFeedImageDiscovery {
        private static let supportedExtensions = Set(["jpg", "jpeg", "png"])

        #if targetEnvironment(simulator)
            /// Local checkout fallback for a normal Xcode Run, whose process does not inherit
            /// variables supplied to a separate `simctl launch`. The stills remain local and
            /// outside the app bundle.
            static var localCheckoutFeedPath: String {
                URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()  // Runner
                    .deletingLastPathComponent()  // ios
                    .deletingLastPathComponent()  // repository root
                    .appendingPathComponent(".local/demo/feeds", isDirectory: true)
                    .path
            }
        #endif

        /// Resolves launch-time stills, preferring an explicit environment path and then a local
        /// simulator-development fallback. Empty or stale configured directories do not mask
        /// fallback.
        static func launchImagePaths(
            environment: [String: String],
            fallbackDirectoryPath: String? = nil,
            fileManager: FileManager = .default
        ) -> [String] {
            let candidates = [environment["ZC_DEMO_FEED_DIR"], fallbackDirectoryPath].compactMap {
                $0
            }
            for directory in candidates {
                let paths = imagePaths(in: directory, fileManager: fileManager)
                if !paths.isEmpty { return paths }
            }
            return []
        }

        static func imagePaths(
            in directoryPath: String,
            fileManager: FileManager = .default
        ) -> [String] {
            let scanRoot = URL(fileURLWithPath: directoryPath, isDirectory: true)
            guard
                let enumerator = fileManager.enumerator(
                    at: scanRoot,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [
                        .skipsHiddenFiles, .skipsPackageDescendants,
                        .skipsSubdirectoryDescendants,
                    ])
            else { return [] }

            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL,
                    supportedExtensions.contains(url.pathExtension.lowercased()),
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            }
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .map(\.path)
        }
    }

    /// Demo-harness keyboard shortcuts (simulator hardware keyboard): ⌘O enters the interactive
    /// demo from a startup/connection screen, number keys select the matching marketing still, 8
    /// toggles the eye box, and ⌘D toggles interactive AF boxes (see `NativeAppModel.demoUIMode`).
    /// A zero-size first-responder UIKit view. Printable digits arrive through `UIKeyInput`;
    /// command-key chords use `UIKeyCommand`. SwiftUI's `keyboardShortcut` on hidden buttons is
    /// unreliable on iOS.
    struct DemoKeyCommands: UIViewRepresentable {
        let model: NativeAppModel

        func makeUIView(context: Context) -> DemoKeyCatcherView {
            let view = DemoKeyCatcherView()
            view.onKey = { [weak model] input, hasCommand in
                model?.handleDemoKey(input: input, hasCommand: hasCommand)
            }
            return view
        }

        func updateUIView(_ uiView: DemoKeyCatcherView, context: Context) {}
    }

    final class DemoKeyCatcherView: UIView, UIKeyInput {
        var onKey: ((String, Bool) -> Void)?
        private var observesWindowActivation = false

        override var canBecomeFirstResponder: Bool { true }

        /// A `UIKeyInput` first responder summons the software keyboard on simulators without a
        /// connected hardware keyboard, covering half the monitor. An empty input view suppresses
        /// it; hardware key events still reach the responder.
        override var inputView: UIView? { UIView(frame: .zero) }

        override var keyCommands: [UIKeyCommand]? {
            let commands = [
                UIKeyCommand(input: "d", modifierFlags: .command, action: #selector(handleKey(_:))),
                UIKeyCommand(input: "o", modifierFlags: .command, action: #selector(handleKey(_:))),
            ]
            // Fire even when the system would otherwise claim the command chord.
            for command in commands { command.wantsPriorityOverSystemBehavior = true }
            return commands
        }

        /// `UIKeyInput` is the UIKit path for printable hardware-key text. Bare number keys do not
        /// reliably dispatch `UIKeyCommand` actions in Simulator, even when the view is first
        /// responder.
        var hasText: Bool { false }

        func insertText(_ text: String) {
            for character in text where character.isNumber {
                onKey?(String(character), false)
            }
        }

        func deleteBackward() {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            reassertFirstResponder()
            // SwiftUI can reclaim first responder after layout passes; re-assert when the window
            // becomes key so the demo shortcuts keep working across panel presentations. Deferring
            // one pass is essential: `didMoveToWindow` can run before that window is eligible to
            // own the responder, and the old one-shot call silently failed in that state.
            if !observesWindowActivation {
                observesWindowActivation = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(reassertFirstResponder),
                    name: UIWindow.didBecomeKeyNotification, object: nil)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(reassertFirstResponder),
                    name: UIApplication.didBecomeActiveNotification, object: nil)
            }
            DispatchQueue.main.async { [weak self] in self?.reassertFirstResponder() }
        }

        /// The invisible command carrier must remain interaction-enabled to qualify as first
        /// responder, but it must never consume a feed or control touch.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        @objc private func reassertFirstResponder() {
            if window != nil, !isFirstResponder { becomeFirstResponder() }
        }

        @objc private func handleKey(_ command: UIKeyCommand) {
            onKey?(command.input ?? "", command.modifierFlags.contains(.command))
        }
    }
#endif

#if DEBUG
    /// App-owned values and exact typed callback receipts over the real shared controls.
    @MainActor
    private struct StabilizationReview: View {
        @State private var visible = false
        @State private var enabled = true
        @State private var sourceCurrent = true
        @State private var vrOptions: [String]?
        @State private var currentVR: String?
        @State private var currentEVR: String?
        private let codec: String
        @State private var requests: [String] = []
        @State private var refusals = 0
        @State private var reason: String?

        init(mode: String) {
            _vrOptions = State(initialValue: mode == "unknown" ? [] : nil)
            _currentVR = State(initialValue: mode == "unknown" ? nil : "OFF")
            _currentEVR = State(initialValue: mode == "unknown" ? nil : "OFF")
            codec = mode == "raw" ? "N-RAW" : "H.265"
        }

        var body: some View {
            VStack(spacing: 10) {
                HStack(spacing: 16) {
                    Text("SIMULATED independent stabilization")
                        .accessibilityIdentifier("simulated.stabilization.label")
                    if visible {
                        Button("Close stabilization") { visible = false }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("simulated.stabilization.close")
                    } else {
                        Button("Open stabilization") { visible = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("simulated.stabilization.open")
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    Group {
                        if visible {
                            MonitorIndependentSettingsPanel(
                                rows: NikonStabilizationSettings.rows(
                                    vrOptions: vrOptions, currentVR: currentVR,
                                    currentEVR: currentEVR, codec: codec),
                                interactionEnabled: enabled, currentSource: { sourceCurrent },
                                onSelect: { request, option in
                                    requests.append("\(request.rawValue):\(option)")
                                },
                                onUnavailable: { _, explanation in
                                    refusals += 1
                                    reason = explanation
                                })
                        } else {
                            Text("Panel closed")
                        }
                    }
                    .frame(width: 308)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(enabled ? "Lock controls" : "Unlock controls") {
                                enabled.toggle()
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("simulated.stabilization.lock")
                            Button("Retire source") { sourceCurrent = false }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("simulated.stabilization.retireSource")
                        }
                        HStack {
                            Button("Observe ON") { currentVR = "ON" }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("simulated.stabilization.observeOutside")
                            Button("Offer movie choices") {
                                vrOptions = ["OFF", "ON", "SPORT"]
                                currentVR = "unlisted observation"
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("simulated.stabilization.offerMovie")
                        }
                        receipt(
                            "Requests", key: "requests",
                            value: requests.isEmpty ? "none" : requests.joined(separator: "|"))
                        receipt("Refusals", key: "refusals", value: String(refusals))
                        receipt("Reason", key: "reason", value: reason ?? "none")
                        receipt(
                            "Source", key: "source", value: sourceCurrent ? "current" : "retired")
                        receipt(
                            "Observations", key: "observations",
                            value: "\(currentVR ?? "nil")|\(currentEVR ?? "nil")")
                    }
                    .frame(width: 330, alignment: .leading)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .buttonStyle(.bordered)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(Color.black.ignoresSafeArea())
        }

        private func receipt(_ title: String, key: String, value: String) -> some View {
            Text("\(title): \(value)")
                .accessibilityLabel(title)
                .accessibilityValue(value)
                .accessibilityIdentifier("simulated.stabilization." + key)
        }
    }

    /// SIMULATED driver retains the production Nikon adapter without any camera transport.
    @MainActor final class NikonQuickDemoDriver: NikonControlDriver {
        private weak var model: NativeAppModel?
        weak var session: NikonCameraSession?
        init(model: NativeAppModel) { self.model = model }
        var nikonControlFacts: NikonControlFacts {
            guard let model else { return .init(connection: .disconnected(.requested)) }
            var facts = model.nikonControlFacts
            facts.recording = false
            if model.isDemoSession,
                ProcessInfo.processInfo.environment["ZC_DEMO_GRAPHICAL_REVIEW"] == "1"
            {
                facts.timecode = model.liveTimecode.running
            }
            return facts
        }
        func queueSettingWrites(
            _ label: String, for setting: NikonControlSetting,
            operation: OperationID?
        ) -> Int {
            guard let model else { return 0 }
            let writes = PTPCameraPropertyWrite.requests(
                control: setting.cameraControl,
                label: label, snapshot: model.operatorQuickReportedProperties)
            for write in writes {
                model.applyBootstrapObservation(.property(write.property, write.data))
            }
            Task { @MainActor [weak self] in
                guard let session = self?.session else { return }
                if let operation {
                    session.operationSent(operation)
                    for write in writes {
                        session.writeLanded(operation, write: write, readback: write.data)
                    }
                }
                _ = session.refresh()
            }
            return writes.count
        }
        func queueRecord(start: Bool, operation: OperationID) {}
    }
#endif

#if DEBUG
    /// SIMULATED consent over the actual public screens; empty integrations cannot dial.
    @MainActor
    private struct ConnectConsentReview: View {
        let mode: String
        @State private var cameras = CamerasModel(
            integrations: [],
            store: SavedCamerasStore(document: StoredData(read: { nil }, write: { _ in })))
        @State private var parentCameras = CamerasModel(
            integrations: [],
            store: SavedCamerasStore(document: StoredData(read: { nil }, write: { _ in })))
        @State private var answers = 0
        @State private var cancellations = 0
        @State private var showsChild = true

        var body: some View {
            VStack {
                HStack {
                    Button("Show decision") { present(on: cameras.consent) }
                    Button("Hide child") { showsChild = false }
                    Button("Show parent decision") { present(on: parentCameras.consent) }
                    Text("Answers: \(answers), cancels: \(cancellations)")
                }
                if mode.hasPrefix("nested") {
                    AppShell(
                        model: ShellModel(cameras: mode == "nestedSame" ? cameras : parentCameras),
                        brand: ShellBrand(name: "SIMULATED"),
                        actions: ShellActions(diagnostics: {}, reportProblem: {}),
                        prePage: { _ in AnyView(child) },
                        monitor: { _ in EmptyView() }, page: { _ in EmptyView() })
                } else {
                    child
                }
            }
        }

        @ViewBuilder private var child: some View {
            if showsChild {
                if mode == "pair" {
                    PairScreen(model: cameras, onDone: {}, onDiagnostics: {}, onReportProblem: {})
                } else {
                    CamerasScreen(
                        model: cameras, brandName: "SIMULATED", onPair: {}, onMedia: {},
                        onSettings: {})
                }
            } else {
                Text("Child removed")
            }
        }

        private func present(on owner: OperatorConsent) {
            owner.present(
                OperatorConsentRequest(
                    title: "SIMULATED decision", message: "No camera commands are connected.",
                    confirmTitle: "Continue", onConfirm: { answers += 1 },
                    onCancel: { cancellations += 1 }), source: "review")
        }
    }
#endif
