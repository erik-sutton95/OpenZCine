import SwiftUI
import UIKit

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

    /// `ZC_DEMO_LOG_FEED=1` marks the mock feed as log-encoded so peaking de-logs it.
    static let logFeed = flag("ZC_DEMO_LOG_FEED")
    /// `ZC_DEMO_OPEN_MEDIA` opens the Media browser on launch; the value `play` also starts the
    /// first downloaded clip (read in `MediaBrowserView`).
    static let openMediaAction = value("ZC_DEMO_OPEN_MEDIA")
    /// `ZC_DEMO_MEDIA_LUT=1` switches the LUT tool on when playback starts.
    static let mediaLUT = flag("ZC_DEMO_MEDIA_LUT")
    /// `ZC_DEMO_PANEL_TAB` picks the Operator Setup rail tab (link/assist/controls/…).
    static let panelTab = value("ZC_DEMO_PANEL_TAB")
    /// `ZC_DEMO_LIVE_GUIDE_STEP=camera|assist|system` opens a deterministic guide card.
    static let liveGuideStep = value("ZC_DEMO_LIVE_GUIDE_STEP")
    /// `ZC_DEMO_RED_BLOCKED=ap|off` forces the RED download blocked state for screenshots.
    static let forcedRedAvailability = value("ZC_DEMO_RED_BLOCKED")
    /// `ZC_DEMO_OPEN_BUG_REPORT=1` opens the anonymous bug-report form for screenshot checks.
    static let openBugReport = flag("ZC_DEMO_OPEN_BUG_REPORT")
    /// `ZC_METAL_FEED=1` opts into the experimental GPU-native feed renderer.
    static let metalFeed = flag("ZC_METAL_FEED")
    /// `ZC_DEMO_CANVAS_SCOPES=1` forces the Canvas reference plots over the Metal trace
    /// rasterizer — the baseline for pixel-diff look-regression checks.
    static let canvasScopes = flag("ZC_DEMO_CANVAS_SCOPES")

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
}

#if DEBUG
    extension DemoHarness {
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
                if let raw = env["ZC_DEMO_PICKER"], let picker = CameraPicker(rawValue: raw) {
                    // ZC_DEMO_PICKER_MODE opens the picker on a specific mode tab (e.g. WB Tint).
                    model.showPicker(
                        picker, mode: env["ZC_DEMO_PICKER_MODE"].flatMap(Int.init) ?? 0)
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
                    if model.scopesActive,
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
