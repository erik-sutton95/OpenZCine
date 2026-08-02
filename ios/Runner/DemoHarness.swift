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
    // MARK: Hook registry — every env toggle, one place.

    /// `ZC_DEMO_OPEN_MEDIA` opens the Media browser on launch; the value `play` also starts the
    /// first downloaded clip (read in `MediaBrowserView`).
    static let openMediaAction = value("ZC_DEMO_OPEN_MEDIA")
    /// `ZC_DEMO_SPLIT=vertical|horizontal` stages the 50/50 Log-vs-LUT comparison.
    static let splitComparison = value("ZC_DEMO_SPLIT")
    /// `ZC_DEMO_MEDIA_LUT=1` switches the LUT tool on when playback starts.
    static let mediaLUT = flag("ZC_DEMO_MEDIA_LUT")
    /// `ZC_DEMO_PANEL_TAB` picks the Operator Setup rail tab (link/assist/controls/…).
    static let panelTab = value("ZC_DEMO_PANEL_TAB")
    /// `ZC_DEMO_WIZARD_EXPANDED=1` seeds the wizard transport card's nested options open —
    /// expansion is a tap, unreachable headless, and the expanded overflow is what screenshots
    /// must check.
    static let wizardExpanded = flag("ZC_DEMO_WIZARD_EXPANDED")
    /// `ZC_DEMO_LIVE_GUIDE_STEP=camera|assist|system` opens a deterministic guide card.
    static let liveGuideStep = value("ZC_DEMO_LIVE_GUIDE_STEP")
    /// `ZC_DEMO_RED_BLOCKED=ap|off` forces the RED download blocked state for screenshots.
    static let forcedRedAvailability = value("ZC_DEMO_RED_BLOCKED")
    /// `ZC_DEMO_OPEN_BUG_REPORT=1` opens the bug-report route chooser for screenshot checks.
    static let openBugReport = flag("ZC_DEMO_OPEN_BUG_REPORT")
    /// `ZC_DEMO_INTERNET_CONFIRM=support|report|feature` stages the camera-AP confirmation alert.
    static let internetHandoffConfirmation = value("ZC_DEMO_INTERNET_CONFIRM")
    /// `ZC_DEMO_INTERNET_PROGRESS=support|report|feature` stages the route-waiting overlay.
    static let internetHandoffProgress = value("ZC_DEMO_INTERNET_PROGRESS")
    /// `ZC_DEMO_CPU_FEED=1` forces the old `UIImageView` feed path back, for an A/B against the
    /// default GPU-native renderer. See `FeedRenderMode`.
    static let forceCPUFeed = flag("ZC_DEMO_CPU_FEED")
    /// `ZC_DEMO_CANVAS_SCOPES=1` forces the Canvas reference plots over the Metal trace
    /// rasterizer — the baseline for pixel-diff look-regression checks.
    static let canvasScopes = flag("ZC_DEMO_CANVAS_SCOPES")
    /// `ZC_DEMO_WIFI_SCANNER=scan|manual` opens the Wi-Fi credential scanner for screenshots.
    static let cameraWiFiScannerMode = value("ZC_DEMO_WIFI_SCANNER")
    /// `ZC_DEMO_PLAYBACK_CLEAN_VIEW=1` opens the clip player with its chrome already hidden, so
    /// the clean view and its "tap to show controls" hint can be captured headlessly. Synthetic
    /// taps do not reach this app, so the state is otherwise only reachable by hand.
    static let playbackCleanView = flag("ZC_DEMO_PLAYBACK_CLEAN_VIEW")
    /// `ZC_DEMO_MAGNIFY=1` starts the live view punched in, so the punch-in and the focus box it is
    /// anchored to can be captured together. Synthetic taps do not reach this app, so the state is
    /// otherwise only reachable by pressing the key by hand.
    static let magnificationActive = flag("ZC_DEMO_MAGNIFY")
    /// `ZC_DEMO_RATING_SHADE=handle|open` mounts the star-rating shade in the clip player without a
    /// camera session, closed or already open. Both states need capturing: the rating is read from
    /// the card, so neither is reachable headlessly, and synthetic taps do not reach this app —
    /// which is how an empty shade shipped unnoticed.
    static let ratingShade = value("ZC_DEMO_RATING_SHADE")
    /// `ZC_DEMO_CAPTURE_FRAMES=N` dumps the next N live-view frames to disk — see
    /// ``captureLiveViewObject(_:)``.
    static let captureLiveViewFrameCount = value("ZC_DEMO_CAPTURE_FRAMES").flatMap(Int.init)

    // MARK: Environment access — Debug reads the process env; Release is hardwired inert.

    #if DEBUG
        private static let environment = ProcessInfo.processInfo.environment
        private static func flag(_ name: String) -> Bool { environment[name] == "1" }
        private static func value(_ name: String) -> String? { environment[name] }
    #else
        private static func flag(_ name: String) -> Bool { false }
        private static func value(_ name: String) -> String? { nil }
    #endif

    #if !DEBUG
        /// Release stub — the launch harness does not exist outside Debug builds.
        @MainActor static func applyLaunchEnvironment(to model: NativeAppModel) {}
    #endif

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
        static func demoDispMode(_ env: [String: String]) -> DispMode? {
            if let raw = env["ZC_DEMO_CHROME_EDIT"], let mode = DispMode(rawValue: raw) {
                return mode
            }
            return env["ZC_DEMO_DISP"].flatMap(DispMode.init(rawValue:))
        }

        /// Stages the model from the launch environment (`SIMCTL_CHILD_ZC_DEMO_*` via
        /// `simctl launch`). No effect in normal launches.
        @MainActor static func applyLaunchEnvironment(to model: NativeAppModel) {
            let env = environment
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
                if let raw = env["ZC_DEMO_DISP"], let mode = DispMode(rawValue: raw) {
                    // Demo/screenshot affordance: launch straight into a DISP mode (live/clean/
                    // command) for headless mode-state captures.
                    model.displayMode = mode
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
                    model.preferences.splitComparisonEnabled = orientation != nil
                    if let orientation {
                        model.preferences.splitComparisonOrientation = orientation
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
                    let mode = AssistConfiguration.Scopes.ParadeMode(rawValue: raw.uppercased())
                {
                    // Demo/screenshot affordance: seed the parade lane mode (rgb/yrgb) so the GPU
                    // and CPU parade scopes can be captured in YRGB without a manual toggle.
                    model.assistConfiguration.scopes.paradeMode = mode
                }
                if let raw = env["ZC_DEMO_WAVE_MODE"],
                    let mode = AssistConfiguration.Scopes.WaveformMode(
                        rawValue: raw.capitalized == "Rgb" ? "RGB" : raw.capitalized)
                {
                    // Demo/screenshot affordance: seed the waveform trace mode (luma/rgb).
                    model.assistConfiguration.scopes.waveformMode = mode
                }
                if let raw = env["ZC_DEMO_WAVE_BRIGHTNESS"], let percent = Int(raw) {
                    // Demo/screenshot affordance: waveform trace brightness percent (0–200).
                    model.assistConfiguration.scopes.waveformBrightness =
                        AssistConfiguration.Scopes.clampedBrightness(percent)
                }
                if let raw = env["ZC_DEMO_VECTOR_ZOOM"],
                    let zoom = AssistConfiguration.Scopes.VectorscopeZoom(
                        rawValue: raw.lowercased())
                {
                    model.assistConfiguration.scopes.vectorscopeZoom = zoom
                }
                if let raw = env["ZC_DEMO_VECTOR_BRIGHTNESS"], let percent = Int(raw) {
                    model.assistConfiguration.scopes.vectorscopeBrightness =
                        AssistConfiguration.Scopes.clampedBrightness(percent)
                }
                if let raw = env["ZC_DEMO_VECTOR_SCALE"], let scale = Double(raw) {
                    model.assistConfiguration.scopes.vectorscopeScale =
                        AssistConfiguration.Scopes.clampedScale(scale)
                }
                if env["ZC_DEMO_GUIDES_MASK"] == "1" {
                    // Demo/screenshot affordance: darken outside the selected guide frames.
                    model.assistConfiguration.guides.maskEnabled = true
                }
                if env["ZC_DEMO_UI_MODE"] == "1" {
                    // Demo/screenshot affordance: start in demo UI mode (same as pressing ⌘D).
                    model.demoUIMode = true
                }
                if let raw = env["ZC_DEMO_FALSE_SCALE"],
                    let scale = FalseColorScale(rawValue: raw)
                {
                    // Demo/screenshot affordance: stage the Stops, IRE, or Limits false-colour ruler.
                    model.assistConfiguration.falseColorScale = scale
                }
                if let raw = env["ZC_DEMO_PANEL_POS"] {
                    // Demo/screenshot affordance: place floating assist panels at normalized
                    // viewport positions, e.g. "wave:0.25,0.30;traffic-lights:0.08,0.58".
                    for entry in raw.split(separator: ";") {
                        let parts = entry.split(separator: ":")
                        guard parts.count == 2 else { continue }
                        let coords = parts[1].split(separator: ",").compactMap { Double($0) }
                        guard coords.count == 2 else { continue }
                        model.movablePanelPositions[String(parts[0])] = MovablePanelStoredCenter(
                            center: CGPoint(x: coords[0], y: coords[1]),
                            in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                }
                if let raw = env["ZC_DEMO_CLEAN_PIN"] {
                    // Demo/screenshot affordance: pin assist tools to clean view (comma-separated
                    // raw values, e.g. "WAVE,GUIDES") so DISP 2 can be captured both bare and
                    // with exactly one tool kept.
                    for value in raw.split(separator: ",") {
                        if let tool = MonitorAssistTool(rawValue: String(value)) {
                            model.preferences.cleanViewPinnedTools.insert(tool)
                        }
                    }
                }
                if let raw = env["ZC_DEMO_CHROME_HIDE"] {
                    // Demo/screenshot affordance: hide monitor-chrome sections (comma-separated
                    // `DisplayChromeVisibility.Section` raw values, e.g.
                    // "lockButton,railMedia,focusBox") so each hidden state can be captured
                    // headlessly — simctl cannot drive the Settings switches. Applies to the DISP
                    // mode named by `ZC_DEMO_CHROME_EDIT`/`ZC_DEMO_DISP`, else the current one,
                    // on the capture side the body reports.
                    let target = Self.demoDispMode(env) ?? model.displayMode
                    let capture = model.captureLayoutMode
                    var chrome = model.preferences.chrome(for: target, capture: capture)
                    for value in raw.split(separator: ",") {
                        // The short names the earlier hooks used, then the section raw values.
                        let section: DisplayChromeVisibility.Section? =
                            switch value {
                            case "lock": .lockButton
                            case "battery": .batteryIndicators
                            case "topbar": .statusBar
                            case "toolbar": .assistToolbar
                            case "values": .cameraValues
                            default: DisplayChromeVisibility.Section(rawValue: String(value))
                            }
                        if let section, chrome.isVisible(section) { chrome.toggle(section) }
                        // "rail" is the retired whole-rail blob — expand it to the four controls.
                        if value == "rail" {
                            for control in DisplayChromeVisibility.Section.railControls
                            where chrome.isVisible(control) {
                                chrome.toggle(control)
                            }
                        }
                    }
                    model.preferences.setChrome(chrome, for: target, capture: capture)
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
                            // Level and de-squeeze also gate on their own enable flag.
                            if tool == .level { model.assistConfiguration.level.enabled = true }
                            if tool == .desqueeze {
                                model.assistConfiguration.desqueeze.enabled = true
                                model.assistConfiguration.desqueeze.ratio = .x2
                            }
                        }
                    }
                    if model.preferences.visibleAssistTools(for: .liveView).contains(.audioMeters) {
                        model.demoSeedAudioMonitor()
                    }
                    // The demo has no live stream, so seed the scopes from the demo frame once.
                    // Keyed on the switched-on set, not the mode-filtered render set, so a clean-
                    // view capture with a pinned scope still gets samples.
                    let scopesOn = MonitorAssistTool.scopeTools.contains {
                        model.preferences.visibleAssistTools(for: .liveView).contains($0)
                    }
                    if scopesOn,
                        let mock = model.liveFrameImage ?? UIImage(named: "MockFeed")
                    {
                        Task { await model.refreshScopes(from: mock) }
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
                    model.preferences.playbackVisibleAssistTools.formUnion(
                        raw.split(separator: ",").compactMap {
                            MonitorAssistTool(rawValue: String($0))
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
                        model.scopeCapNotice += 1
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
                    // over the held frame (`retrying` mid-loop, anything else = budget spent), so
                    // the #253/#254 recovery UI can be captured without unplugging a real camera.
                    model.connectionProgressDeviceName = "Nikon ZR"
                    model.forceSessionRecoveryState(
                        raw == "retrying"
                            ? .retrying(attempt: 2, maxAttempts: 8)
                            : .waitingForOperator(attemptsMade: 8))
                }
                if let raw = env["ZC_DEMO_DISP"], let mode = DispMode(rawValue: raw) {
                    // Demo/screenshot affordance: start in a specific display mode (live/clean/command).
                    model.displayMode = mode
                }
                if env["ZC_DEMO_PANEL"] == "settings" {
                    // Demo/screenshot affordance: open Operator Setup on launch (tab via
                    // ZC_DEMO_PANEL_TAB).
                    model.operatorSettingsTab = OperatorSettingsTab.demoLaunchTab
                    model.activePanel = .settings
                }
                if let step = LiveViewGuideStep.demoValue(liveGuideStep) {
                    model.forceLiveViewGuide(step)
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
                    model.operatorSettingsTab = OperatorSettingsTab.demoLaunchTab(rawTab)
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
                    // The app supports interface LandscapeRight only (see Info.plist) — requesting
                    // the unsupported side would silently no-op.
                    raw == "landscape" ? .landscapeRight : .portrait
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
                // Demo/screenshot affordance: jump the first-pair wizard to a step (raw 0-4) —
                // steps past permissions are otherwise unreachable headless (they need taps).
                // Pair with ZC_DEMO_WIZARD_TRANSPORT for steps whose content is per-transport.
                // The pairing flag makes the wizard show even when saved cameras exist
                // (`shouldShowFirstPairWizard` is pairing-or-empty).
                model.isPairingNewCamera = true
                model.firstPairWizardStep = step
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
                store.upsertSavedCamera(
                    host: "usb:demo-zr", displayName: "ZR_6002199", transport: "USB-C",
                    serialNumber: "6002199")
                store.upsertSavedCamera(
                    host: "192.168.1.1", displayName: "Z6_7005555", transport: "Wi-Fi",
                    onCameraAccessPoint: true, serialNumber: "7005555")
                model.showSavedCameras()
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
                model.applyScannedCameraWiFi(ssid: "NIKON_ZR_01234", key: "a1b2c3d4")
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
