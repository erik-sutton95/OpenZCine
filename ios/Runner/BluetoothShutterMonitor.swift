import AVFoundation
import MediaPlayer
import OSLog
import UIKit

let bluetoothShutterLogger = Logger(subsystem: "OpenZCine", category: "bluetooth-shutter")

/// Generic Bluetooth-shutter path: turns a shutter remote's volume press into a record trigger.
///
/// Third-party shutter buttons pair as HID keyboards and send Consumer-Control volume presses
/// (some models up, some down) that iOS routes to the system volume — there is no key event to
/// catch. While active: documented KVO on `AVAudioSession.outputVolume` observes the change, an
/// `MPVolumeView` in the window suppresses the system volume HUD, and after every press the
/// volume is re-anchored mid-scale so presses in *either* direction register and the audible
/// volume never drifts. Re-anchoring through the volume view's slider is a best-effort
/// compatibility technique, not a documented interception API; a private volume-change
/// notification remains only as a best-effort rail fallback. The phone's own volume buttons
/// trigger too — inherent to the mechanism, and useful as a hardware record button.
///
/// This takes over the volume buttons, so it only runs while the operator has opted in and the
/// live monitor is up (see `NativeAppModel.updateBluetoothShutter()`); the pre-session volume is
/// restored on stop. This is the SOLE remote-shutter mechanism: an earlier
/// `AVCaptureEventInteraction` companion path was removed because its always-running
/// `AVCaptureSession` cost a camera permission prompt, the camera-in-use indicator, and real
/// thermal/RF load during live view (suspected in ZR hotspot connection drops), while every
/// supported trigger already arrives through this volume path.
@MainActor
final class BluetoothShutterMonitor {
    nonisolated enum TriggerDecision: String, Equatable {
        case trigger
        case atAnchor
        case debounced
        case selfInflicted
    }

    /// Called on each volume press (either direction), already debounced.
    var onTrigger: (() -> Void)?

    /// Mid-scale anchor the volume is pinned to between presses — a press in either direction
    /// always moves off it, and our own programmatic re-anchor lands exactly back on it.
    private nonisolated static let anchor: Float = 0.5
    /// Two HID reports for one physical press (down+repeat) arrive within ~0.3 s; a camera-body
    /// record toggle also needs breathing room, so presses inside this window are one trigger.
    nonisolated static let debounceInterval: TimeInterval = 0.6
    /// Ignore volume events this close to our own programmatic re-anchor — they are its echo.
    private nonisolated static let selfInflictedWindow: TimeInterval = 0.4

    /// Undocumented MediaPlayer notification used only as a best-effort supplement to the public
    /// `outputVolume` observer. Its name and userInfo contract can vary between iOS releases.
    private nonisolated static let volumeNotification = Notification.Name("SystemVolumeDidChange")

    private var volumeObservation: NSKeyValueObservation?
    private var volumeObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var sliderAcquisitionTask: Task<Void, Never>?
    private var sliderAcquisitionGeneration = 0
    private var volumeWriteTask: Task<Void, Never>?
    private var routeRecoveryTask: Task<Void, Never>?
    private var restoreVolumesByRoute: [String: Float] = [:]
    private var lastTriggerAt: TimeInterval = 0
    private var lastAnchorAt: TimeInterval = 0
    private var suppressVolumeEventsUntil: TimeInterval = 0
    private var outputRouteSignature = ""
    private var eventGeneration = 0
    private(set) var isActive = false

    /// The pure trigger decision, split out for testability: any move off the anchor (either
    /// direction — remotes differ) outside both the debounce and self-anchor windows is a press.
    nonisolated static func isTrigger(
        newVolume: Float, now: TimeInterval,
        lastTriggerAt: TimeInterval, lastAnchorAt: TimeInterval
    ) -> Bool {
        triggerDecision(
            newVolume: newVolume, now: now,
            lastTriggerAt: lastTriggerAt, lastAnchorAt: lastAnchorAt) == .trigger
    }

    nonisolated static func triggerDecision(
        newVolume: Float, now: TimeInterval,
        lastTriggerAt: TimeInterval, lastAnchorAt: TimeInterval
    ) -> TriggerDecision {
        if abs(newVolume - anchor) <= 0.001 { return .atAnchor }
        if now - lastTriggerAt < debounceInterval { return .debounced }
        if now - lastAnchorAt < selfInflictedWindow { return .selfInflicted }
        return .trigger
    }

    /// `liveViewFront` is false while a full-screen surface (Operator Setup, Media, Tool
    /// Library) covers the monitor: the rocker only means "record" when the operator is looking
    /// at the live view, and while disarmed the volume keys behave normally inside menus.
    nonisolated static func shouldRun(
        enabled: Bool, monitorPresented: Bool, liveViewFront: Bool, applicationIsActive: Bool,
        audioSessionAvailable: Bool
    ) -> Bool {
        enabled && monitorPresented && liveViewFront && applicationIsActive
            && audioSessionAvailable
    }

    @discardableResult
    func start() -> Bool {
        guard UIApplication.shared.applicationState == .active else {
            bluetoothShutterLogger.info("BT-SHUTTER start deferred: app is not active")
            return false
        }
        if isActive {
            guard activateAudioSession() else {
                stop()
                return false
            }
            installVolumeView()
            beginSliderAcquisition()
            bluetoothShutterLogger.info("BT-SHUTTER reactivated existing monitor")
            return true
        }
        guard activateAudioSession() else { return false }

        let session = AVAudioSession.sharedInstance()
        isActive = true
        eventGeneration += 1
        outputRouteSignature = Self.outputRouteSignature(for: session)
        restoreVolumesByRoute = [outputRouteSignature: session.outputVolume]
        installVolumeView()
        beginSliderAcquisition()
        // `outputVolume` KVO is Apple's documented observation path. It is the primary detector;
        // the notification below merely supplements it at the 0/1 rails. Both feed the same
        // debounce, so an OS that emits both still produces exactly one record toggle.
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) {
            [weak self] session, change in
            let newValue = change.newValue ?? session.outputVolume
            let oldText = change.oldValue.map { String($0) } ?? "nil"
            bluetoothShutterLogger.info(
                "BT-SHUTTER KVO old=\(oldText, privacy: .public) new=\(newValue, privacy: .public)"
            )
            Task { @MainActor [weak self] in
                self?.volumeChanged(to: newValue, source: "KVO")
            }
        }
        // Weak self crosses into the @Sendable observer block via an @unchecked Sendable box —
        // same load-bearing pattern as WatchRelay's reply handlers (Swift 6 dynamic isolation):
        // the block runs on the main queue, so assumeIsolated is sound.
        let box = ShutterSendableBox(value: { [weak self] name, keys, reason, volume in
            self?.handleVolumeNotification(
                name: name, keys: keys, reason: reason, volume: volume)
        })
        volumeObserver = NotificationCenter.default.addObserver(
            forName: Self.volumeNotification, object: nil, queue: .main
        ) { notification in
            let info = notification.userInfo ?? [:]
            let reason = info["Reason"] as? String
            let rawVolume = info["Volume"]
            let volume: Float?
            switch rawVolume {
            case let value as Float: volume = value
            case let value as Double: volume = Float(value)
            case let value as NSNumber: volume = value.floatValue
            default: volume = nil
            }
            let keys = info.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
            let name = notification.name.rawValue
            MainActor.assumeIsolated { box.value(name, keys, reason, volume) }
        }
        let routeBox = ShutterRouteSendableBox(value: { [weak self] in
            self?.audioRouteChanged()
        })
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { _ in
            MainActor.assumeIsolated { routeBox.value() }
        }
        bluetoothShutterLogger.info(
            "BT-SHUTTER started category=\(session.category.rawValue, privacy: .public) volume=\(session.outputVolume, privacy: .public)"
        )
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        eventGeneration += 1
        sliderAcquisitionGeneration += 1
        sliderAcquisitionTask?.cancel()
        sliderAcquisitionTask = nil
        volumeWriteTask?.cancel()
        volumeWriteTask = nil
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        if let volumeObserver { NotificationCenter.default.removeObserver(volumeObserver) }
        volumeObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        // The slider is already established at shutdown, so restore synchronously while this
        // monitor still owns an active audio session. Delayed writes can otherwise race a new
        // activation or deactivate the clip player's session after a rapid surface transition.
        let currentRouteSignature = Self.outputRouteSignature(
            for: AVAudioSession.sharedInstance())
        if let restoreVolume = restoreVolumesByRoute[currentRouteSignature], let volumeSlider {
            volumeSlider.setValue(restoreVolume, animated: false)
            bluetoothShutterLogger.info(
                "BT-SHUTTER restored volume=\(restoreVolume, privacy: .public)")
        }
        restoreVolumesByRoute.removeAll()
        outputRouteSignature = ""
        let view = volumeView
        volumeView = nil
        volumeSlider = nil
        view?.removeFromSuperview()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        } catch {
            bluetoothShutterLogger.error(
                "BT-SHUTTER deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
        bluetoothShutterLogger.info("BT-SHUTTER stopped")
    }

    private func volumeChanged(to newValue: Float, source: String) {
        // Route notifications originate on a secondary thread and KVO has independent delivery
        // ordering. Give both a short turn to settle, then also compare the live route signature
        // before interpreting a volume move as a shutter press.
        let generation = eventGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.1))
            guard !Task.isCancelled, let self, self.eventGeneration == generation else { return }
            self.adjudicateVolumeChange(newValue, source: source)
        }
    }

    private func adjudicateVolumeChange(_ newValue: Float, source: String) {
        // KVO reports every system-volume change, including Control Center adjustments while this
        // app is covered/inactive. Only a frontmost live monitor may turn one into a record command.
        guard isActive, UIApplication.shared.applicationState == .active else {
            bluetoothShutterLogger.info(
                "BT-SHUTTER ignored \(source, privacy: .public) event while inactive")
            return
        }
        let currentRouteSignature = Self.outputRouteSignature(for: .sharedInstance())
        if currentRouteSignature != outputRouteSignature {
            handleAudioRouteChange(signature: currentRouteSignature)
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now < suppressVolumeEventsUntil {
            bluetoothShutterLogger.info(
                "BT-SHUTTER ignored \(source, privacy: .public) event during audio-route change")
            if abs(newValue - Self.anchor) > 0.001 { setSystemVolume(Self.anchor) }
            return
        }
        let decision = Self.triggerDecision(
            newVolume: newValue, now: now,
            lastTriggerAt: lastTriggerAt, lastAnchorAt: lastAnchorAt)
        bluetoothShutterLogger.info(
            "BT-SHUTTER event source=\(source, privacy: .public) volume=\(newValue, privacy: .public) decision=\(decision.rawValue, privacy: .public)"
        )
        guard decision == .trigger else {
            // Debounced repeat or an echo drift: re-pin so the volume never walks to a rail.
            if abs(newValue - Self.anchor) > 0.001, now - lastAnchorAt >= Self.selfInflictedWindow {
                setSystemVolume(Self.anchor)
            }
            return
        }
        lastTriggerAt = now
        setSystemVolume(Self.anchor)
        bluetoothShutterLogger.info("BT-SHUTTER dispatching record toggle")
        onTrigger?()
    }

    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // A Bluetooth shutter changes the media output volume. `.playback` puts this app on
            // that route; mixing keeps other audio uninterrupted while the opt-in is active.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            bluetoothShutterLogger.error(
                "BT-SHUTTER activation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func handleVolumeNotification(
        name: String, keys: String, reason: String?, volume: Float?
    ) {
        bluetoothShutterLogger.info(
            "BT-SHUTTER notification name=\(name, privacy: .public) keys=\(keys, privacy: .public) reason=\(reason ?? "nil", privacy: .public) volume=\(volume.map { String($0) } ?? "nil", privacy: .public)"
        )
        guard reason == "ExplicitVolumeChange", let volume else { return }
        volumeChanged(to: volume, source: "notification")
    }

    private func audioRouteChanged() {
        handleAudioRouteChange(
            signature: Self.outputRouteSignature(for: AVAudioSession.sharedInstance()))
    }

    private func handleAudioRouteChange(signature: String) {
        // Each route remembers its own output volume. Connecting headphones or another Bluetooth
        // route can therefore move outputVolume without a shutter press; suppress that transition
        // and rebuild MPVolumeView because its internal slider may be replaced for the new route.
        guard isActive else { return }
        guard signature != outputRouteSignature else {
            suppressVolumeEventsUntil = CFAbsoluteTimeGetCurrent() + 0.8
            bluetoothShutterLogger.info(
                "BT-SHUTTER same audio route changed category; suppressing volume events")
            return
        }
        outputRouteSignature = signature
        suppressVolumeEventsUntil = CFAbsoluteTimeGetCurrent() + 0.8
        bluetoothShutterLogger.info("BT-SHUTTER audio route changed; suppressing volume events")
        volumeWriteTask?.cancel()
        volumeWriteTask = nil
        sliderAcquisitionGeneration += 1
        sliderAcquisitionTask?.cancel()
        sliderAcquisitionTask = nil
        volumeSlider = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        routeRecoveryTask?.cancel()
        routeRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.2))
            guard !Task.isCancelled, let self, self.isActive else { return }
            if self.restoreVolumesByRoute[signature] == nil {
                self.restoreVolumesByRoute[signature] =
                    AVAudioSession.sharedInstance().outputVolume
            }
            self.installVolumeView()
            self.beginSliderAcquisition()
            self.routeRecoveryTask = nil
        }
    }

    private static func outputRouteSignature(for session: AVAudioSession) -> String {
        session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.uid)" }
            .sorted()
            .joined(separator: "|")
    }

    /// An `MPVolumeView` in the window suppresses the system volume HUD. This implementation also
    /// uses its internal slider as a best-effort re-anchor; iOS does not expose a documented API
    /// for intercepting generic HID volume commands without first changing system volume. The view
    /// must be genuinely in the visible hierarchy for HUD suppression to hold on device, so it
    /// sits at 1×1 pt in a corner at near-zero alpha rather than offscreen.
    private func installVolumeView() {
        guard volumeView == nil else { return }
        guard
            let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else {
            bluetoothShutterLogger.error("BT-SHUTTER volume view has no key window")
            return
        }
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.02
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        volumeView = view
        bluetoothShutterLogger.info("BT-SHUTTER volume view installed")
    }

    /// `MPVolumeView` builds its slider subview asynchronously after joining the hierarchy —
    /// searching too early finds nothing (and silently broke anchoring in the first cut of this
    /// feature). Poll briefly until it appears, then take the initial anchor.
    private func beginSliderAcquisition() {
        guard isActive, volumeSlider == nil, sliderAcquisitionTask == nil else { return }
        sliderAcquisitionGeneration += 1
        let generation = sliderAcquisitionGeneration
        sliderAcquisitionTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.isActive, self.volumeSlider == nil,
                    self.sliderAcquisitionGeneration == generation
                else { return }
                // Scene activation and MPVolumeView's private hierarchy are both asynchronous.
                if self.volumeView == nil { self.installVolumeView() }
                if let volumeView = self.volumeView,
                    let slider = Self.firstSlider(in: volumeView)
                {
                    self.volumeSlider = slider
                    self.bluetoothSliderAcquired(slider, attempt: attempt)
                    self.sliderAcquisitionTask = nil
                    return
                }
                if attempt == 20 {
                    bluetoothShutterLogger.error(
                        "BT-SHUTTER slider acquisition delayed; continuing to retry")
                }
                attempt += 1
                try? await Task.sleep(for: attempt <= 20 ? .seconds(0.15) : .seconds(1))
            }
        }
    }

    private func bluetoothSliderAcquired(_ slider: UISlider, attempt: Int) {
        bluetoothShutterLogger.info(
            "BT-SHUTTER slider acquired class=\(NSStringFromClass(type(of: slider)), privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        setSystemVolume(Self.anchor)
    }

    private func setSystemVolume(_ value: Float) {
        lastAnchorAt = CFAbsoluteTimeGetCurrent()
        // Capture the current slider before the async delay; lifecycle or route teardown may clear
        // the monitor's property while this write is waiting.
        guard let slider = volumeSlider else {
            bluetoothShutterLogger.error(
                "BT-SHUTTER cannot set volume=\(value, privacy: .public): slider unavailable")
            return
        }
        bluetoothShutterLogger.info(
            "BT-SHUTTER setting volume=\(value, privacy: .public)")
        volumeWriteTask?.cancel()
        volumeWriteTask = Task { @MainActor [weak self, weak slider] in
            // The slider ignores writes for a beat after appearing; a short defer makes them stick.
            try? await Task.sleep(for: .seconds(0.05))
            guard !Task.isCancelled, let self, self.isActive, let slider else { return }
            slider.setValue(value, animated: false)
            try? await Task.sleep(for: .seconds(0.1))
            guard !Task.isCancelled, self.isActive else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            bluetoothShutterLogger.info(
                "BT-SHUTTER volume readback requested=\(value, privacy: .public) actual=\(actual, privacy: .public)"
            )
        }
    }

    static func firstSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = firstSlider(in: subview) { return slider }
        }
        return nil
    }
}

/// Minimal `@unchecked Sendable` box carrying the main-actor volume handler into the notification
/// observer's `@Sendable` block; invoked only on the main actor (the observer queue is `.main`).
private struct ShutterSendableBox: @unchecked Sendable {
    let value: @MainActor (String, String, String?, Float?) -> Void
}

private struct ShutterRouteSendableBox: @unchecked Sendable {
    let value: @MainActor () -> Void
}
