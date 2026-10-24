import Foundation
import MonitorPresentation
import Observation
import OpenZCineCore
import UIKit
import os

/// Revocable OS ownership checked by the native driver without crossing the main actor.
final class FocusRackAuthority: Sendable {
    private let admitted = OSAllocatedUnfairLock(initialState: false)
    var isAdmitted: Bool { admitted.withLock { $0 } }
    func update(_ value: Bool) { admitted.withLock { $0 = value } }
}

/// A real accepted raster and its session-local observation sequence.
struct FocusRackAcceptedFrame {
    let revision: UInt64
    let timestamp: Double
    let image: UIImage
}

/// Preserves the original frame age while an OS delivery waits for the controller.
struct FocusRackObservationDelivery: Sendable {
    var observation: FocusRackObservation
    let receivedAt: Double

    func aged(at now: Double) -> FocusRackObservation {
        var result = observation
        result.frameAgeSeconds += max(0, now - receivedAt)
        return result
    }
}

/// One bounded raster awaiting the authoritative accepted capture identity.
struct FocusRackPendingCapture {
    let id = UUID()
    let markID: String
    let sessionID: String
    let frameSequence: Int64
    let baselineRevision: Int64
    let image: UIImage
    var acceptedRevision: Int64?

    func matches(_ capture: FocusRackCaptureIdentity) -> Bool {
        capture.markID == markID && capture.sessionID == sessionID
            && capture.frameSequence == frameSequence && capture.revision > baselineRevision
            && (acceptedRevision == nil || capture.revision == acceptedRevision)
    }
}

/// Root-owned UI/OS adapter. The portable controller owns execution and operator rules.
@MainActor @Observable final class FocusRackModel {
    var nudgeTowardNear = true
    private(set) var state: FocusRackState?
    private(set) var templates: [FocusRackTemplate] = []
    private(set) var notice: String?
    private(set) var stopPending = false
    private(set) var capturingMark: String?
    private(set) var mode: FocusControlMode = .timedRack
    private(set) var modeSwitchPending = false
    private(set) var afSettings = FocusAFSettingsLease()
    private(set) var afSetupRequested = false
    private(set) var afSetupFailure: String?
    private(set) var nativeRack = NativeAFRack()
    private(set) var nativeDelayRemaining = 0.0
    @ObservationIgnored private var nativeDelayTask: Task<Void, Never>?
    @ObservationIgnored private var nativeWriteAuthority: FocusRackAuthority?
    @ObservationIgnored private var afWriteAuthority: FocusRackAuthority?
    @ObservationIgnored private var afReadinessPolls = 0
    @ObservationIgnored private var afSetupManualChanges: Set<FocusAFProperty> = []
    var isExpanded = true
    /// Preserves an attention request while compact and expanded views are exchanged.
    var revealAdmission = false
    var panelPosition: MonitorScopePoint?
    private(set) var isActive = true
    @ObservationIgnored private weak var model: NativeAppModel?
    @ObservationIgnored private var controller: FocusRackController?
    @ObservationIgnored private var authority = FocusRackAuthority()
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var modeSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var observations:
        AsyncStream<FocusRackObservationDelivery>.Continuation?
    @ObservationIgnored private var pendingCapture: FocusRackPendingCapture?
    @ObservationIgnored private var presentationRevision: UInt64 = 0
    @ObservationIgnored private var storesTemplates = true
    @ObservationIgnored private var persistedCalibration: FocusRackCalibration?
    private var thumbnails: [String: Thumbnail] = [:]
    #if DEBUG
        /// Driver-free fixture evidence; real sessions never populate this list.
        private(set) var simulatedNudgeIntents: [FocusRackIntent] = []
    #endif

    private struct Thumbnail {
        let revision: Int64
        let image: UIImage
    }

    var afSettingsPending: Bool { afSetupRequested || afSettings.needsService }
    var afSettingsFailure: String? {
        afSetupFailure ?? (afSetupRequested ? nil : afSettings.failure)
    }
    var afSettingsStatus: String? {
        if let afSettingsFailure { return afSettingsFailure }
        if afSettingsPending {
            return afSettings.restoring
                ? "Waiting to restore AF settings…"
                : "Setting up camera AF…"
        }
        return nil
    }

    var canChangeMode: Bool {
        capturingMark == nil && !afSettingsPending && nativeRack.dispatchedRequest == nil
            && FocusControlModePolicy.canChange(
                rack: state, stopPending: stopPending || modeSwitchPending,
                externalFocusIdle: model?.focusControlExternalFocusIdle ?? true)
    }

    var nativeAFConfigured: Bool {
        !storesTemplates || model?.nativeAFConfigured == true
    }

    /// The same reason gates picture taps, saved targets, and their readiness text.
    var nativeAFBlocker: String? {
        guard isActive else { return "Open Focus Rack before selecting a target." }
        if let model { return model.nativeAFAdmission.disabledReason }
        return NativeAFAdmission(
            connected: !storesTemplates, foreground: true, interfaceLocked: false,
            focusPointLocked: false, liveViewFresh: !storesTemplates,
            commandIdle: !stopPending && state?.busy != true && state?.capabilities.canStop != true,
            settingsPending: afSettingsPending || modeSwitchPending,
            settingsFailure: state?.phase == .stopUnconfirmed
                ? "Reconnect the camera before moving focus." : afSettingsFailure,
            configured: nativeAFConfigured, movieMode: true
        ).disabledReason
    }

    var nativeAFBusy: Bool {
        nativeRack.pendingRequest != nil || nativeRack.dispatchedRequest != nil
    }

    var nativeIsRecording: Bool { model?.isRecording ?? false }

    var nativeFocusPointLocked: Bool { model?.focusPointLocked == true }

    var canUnlockNativeFocusPoint: Bool {
        isActive && mode == .nativeAF && model?.interfaceLocked != true && !nativeAFBusy
    }

    /// Releases only the app's point lock. Target selection still needs a separate action.
    func unlockNativeFocusPoint() {
        guard canUnlockNativeFocusPoint else { return }
        model?.focusPointLocked = false
        notice = nil
    }

    var nativeAFInstruction: String {
        if let reason = nativeAFBlocker { return reason }
        if let notice { return notice }
        if let mark = nativeRack.selectingMark {
            return "Tap subject \(mark.rawValue) in the picture."
        }
        if let request = nativeRack.pendingRequest {
            return
                "Target \(request.mark.rawValue) in \(nativeDelayRemaining.formatted(.number.precision(.fractionLength(1)))) s…"
        }
        if let request = nativeRack.dispatchedRequest {
            return "Selecting target \(request.mark.rawValue)…"
        }
        if let mark = nativeRack.lastSelectedMark { return "Target \(mark.rawValue) selected." }
        if nativeRack.target(for: .a) != nil && nativeRack.target(for: .b) != nil {
            return "Choose a target or run an A/B transition."
        }
        return "Set A and B in the picture."
    }

    var allowsAutofocus: Bool {
        guard !afSettingsPending, !modeSwitchPending else { return false }
        guard isActive else { return true }
        guard afSettingsFailure == nil else { return false }
        if mode == .nativeAF {
            return nativeAFBlocker == nil && nativeRack.dispatchedRequest == nil
        }
        return state?.capabilities.canAutofocus ?? true
    }

    var autofocusDisabledReason: String {
        if let afSettingsStatus { return afSettingsStatus }
        return mode == .nativeAF
            ? nativeAFInstruction : "Use the rack dial, or reset marks before autofocus."
    }

    func armNativeTarget(_ mark: NativeAFMark) {
        guard mode == .nativeAF, nativeAFBlocker == nil, !nativeAFBusy else { return }
        do {
            try nativeRack.arm(mark)
            notice = nil
            isExpanded = false
        } catch { notice = error.localizedDescription }
    }

    /// Receives coordinates after the monitor has undone its presentation transforms.
    @discardableResult
    func captureNativeTarget(_ point: NativeAFPoint) -> Bool {
        guard mode == .nativeAF, nativeRack.selectingMark != nil else { return false }
        guard nativeAFBlocker == nil, !nativeAFBusy else { return true }
        do {
            _ = try nativeRack.capture(point, now: ProcessInfo.processInfo.systemUptime)
            isExpanded = true
            serviceNativeTarget()
        } catch { notice = error.localizedDescription }
        return true
    }

    func selectNativeTarget(_ mark: NativeAFMark, delayed: Bool) {
        guard mode == .nativeAF, nativeAFBlocker == nil, !nativeAFBusy else { return }
        do {
            _ = try nativeRack.request(
                mark, now: ProcessInfo.processInfo.systemUptime, delayed: delayed)
            notice = nil
            serviceNativeTarget()
        } catch { notice = error.localizedDescription }
    }

    func setNativeDelay(_ text: String) {
        guard !nativeAFBusy else { return }
        do {
            let value: Double
            do { value = try Double(text, format: .number) } catch {
                throw InputError.invalidSeconds
            }
            try nativeRack.setStartDelay(value)
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    func cancelNativeTarget() {
        nativeDelayTask?.cancel()
        nativeDelayTask = nil
        nativeDelayRemaining = 0
        nativeRack.cancel()
    }

    private func serviceNativeTarget() {
        nativeDelayTask?.cancel()
        nativeDelayTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        nativeDelayRemaining = nativeRack.remainingDelay(at: now)
        guard let due = nativeRack.dueRequest(at: now) else {
            guard nativeRack.pendingRequest != nil else { return }
            nativeDelayTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.serviceNativeTarget()
            }
            return
        }
        if let reason = nativeAFBlocker {
            cancelNativeTarget()
            notice = reason
            return
        }
        do {
            let request = try nativeRack.beginDispatch(id: due.id, at: now)
            if let model {
                if !model.queueNativeAFTarget(request) {
                    nativeTargetFailed(
                        request.id,
                        message: model.nativeAFTargetDisabledReason
                            ?? "The camera cannot accept a focus target.")
                }
            } else if !storesTemplates {
                _ = nativeRack.complete(id: request.id)
            }
        } catch { notice = error.localizedDescription }
    }

    func nativeTargetCompleted(_ id: UInt64) {
        guard nativeRack.dispatchedRequest?.id == id else { return }
        guard nativeWriteAuthority?.isAdmitted == true else {
            _ = nativeRack.fail(id: id)
            nativeWriteAuthority = nil
            return
        }
        if nativeRack.complete(id: id) {
            nativeWriteAuthority = nil
            notice = nil
        }
    }

    func nativeTargetFailed(_ id: UInt64, message: String) {
        if nativeRack.fail(id: id) {
            nativeWriteAuthority = nil
            notice = message
        }
    }

    func nativeRecordingChanged() {
        guard mode == .nativeAF else { return }
        if !nativeIsRecording {
            cancelNativeTarget()
            revokeNativeTargetAuthority()
        }
    }

    func admitNativeTarget(_ id: UInt64) -> FocusRackAuthority? {
        guard mode == .nativeAF, nativeRack.dispatchedRequest?.id == id,
            nativeAFBlocker == nil
        else { return nil }
        let authority = FocusRackAuthority()
        authority.update(true)
        nativeWriteAuthority = authority
        return authority
    }

    func selectMode(_ selected: FocusControlMode) {
        guard canChangeMode else { return }
        let enteringNative = mode == .timedRack && selected == .nativeAF
        cancelNativeTarget()
        afSetupManualChanges.removeAll()
        retirePresentation()
        authority.update(false)
        controller?.suspend()
        mode = selected
        if enteringNative, nativeFocusPointLocked, model?.interfaceLocked != true {
            unlockNativeFocusPoint()
        }
        notice = nil
        waitForFocusStop(setupAfterStop: true)
        publishObservation()
    }

    /// Dismissal and mode changes both wait for a fresh acknowledgement of native cleanup.
    private func waitForFocusStop(setupAfterStop: Bool) {
        guard let controller, let model else {
            if setupAfterStop { requestAFSetup() }
            return
        }
        modeSwitchTask?.cancel()
        modeSwitchPending = true
        let receivedAt = ProcessInfo.processInfo.systemUptime
        var observation = model.focusRackObservation()
        observation.foregroundOwner = false
        let delivery = FocusRackObservationDelivery(
            observation: observation, receivedAt: receivedAt)
        modeSwitchTask = Task { [weak self] in
            await controller.observe(delivery.aged(at: ProcessInfo.processInfo.systemUptime))
            // Subscribe after the stop gate is consumed. An older displayed idle snapshot cannot
            // acknowledge cancellation of a chunk that has already entered the native driver.
            for await state in await controller.states() {
                guard let self, self.controller === controller, !Task.isCancelled else { return }
                guard !state.busy, !state.capabilities.canStop, state.phase != .stopUnconfirmed
                else { continue }
                self.modeSwitchPending = false
                if setupAfterStop, self.isActive { self.requestAFSetup() }
                self.publishObservation()
                return
            }
        }
    }

    init(model: NativeAppModel) {
        self.model = model
        do { templates = try FocusRackTemplateStore.load() } catch {
            notice = error.localizedDescription
        }
    }

    #if DEBUG
        /// Injects a SIMULATED held driver without starting a camera observer.
        func debugBindController(_ controller: FocusRackController) { self.controller = controller }

        /// SIMULATED UI-only state. It has no camera driver and can never move a lens.
        init(fixture: FocusRackState, model: NativeAppModel? = nil) {
            self.model = model
            state = fixture
            storesTemplates = false
            templates = [.init(name: "Slow reveal", transition: .init(duration: 8))]
            for capture in fixture.captures {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image {
                    context in
                    UIColor.darkGray.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
                    ("SIMULATED " + capture.markID).draw(
                        at: CGPoint(x: 24, y: 35),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.white,
                        ])
                }
                thumbnails[capture.markID] = .init(revision: capture.revision, image: image)
            }
        }
    #endif

    func startObserving() {
        guard controller == nil, let model,
            let access = model.focusRackAccess(authority: authority)
        else { return }
        let controller = FocusRackController(
            driver: access, transition: state?.transition ?? .init(),
            profile: .calibratedFineExperiment)
        self.controller = controller
        let savedCalibration: FocusRackCalibration?
        do { savedCalibration = try FocusRackCalibrationStore.load() } catch {
            savedCalibration = nil
            notice = "Saved focus timing measurements could not be loaded."
        }
        persistedCalibration = savedCalibration
        stateTask = Task { [weak self] in
            if let savedCalibration { try? await controller.loadCalibration(savedCalibration) }
            let states = await controller.states()
            for await state in states {
                guard let self, self.controller === controller, !Task.isCancelled else { return }
                self.present(state)
                if !state.busy, let checkpoint = await controller.calibrationCheckpoint() {
                    guard self.controller === controller, !Task.isCancelled else { return }
                    if checkpoint != self.persistedCalibration {
                        do {
                            try FocusRackCalibrationStore.save(checkpoint)
                            self.persistedCalibration = checkpoint
                        } catch {
                            self.notice = "Focus timing measurements could not be saved."
                        }
                    }
                }
            }
        }
        let channel = AsyncStream<FocusRackObservationDelivery>.makeStream(
            bufferingPolicy: .unbounded)
        observations = channel.continuation
        observationTask = Task { [weak self] in
            for await delivery in channel.stream {
                guard let self, self.controller === controller, !Task.isCancelled else { return }
                await controller.observe(delivery.aged(at: ProcessInfo.processInfo.systemUptime))
            }
        }
        contextTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.controller === controller else { return }
                self.publishObservation()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Publishes the controller state and reconciles accepted mark thumbnails.
    func present(_ state: FocusRackState) {
        self.state = state
        if !state.busy { stopPending = false }
        attachPendingCapture(to: state)
        thumbnails = thumbnails.filter { id, thumbnail in
            state.captures.contains { $0.markID == id && $0.revision == thumbnail.revision }
        }
    }

    func open() {
        isActive = true
        isExpanded = true
        afSetupManualChanges.removeAll()
        requestAFSetup()
        authority.update(false)
        controller?.suspend()
        startObserving()
        waitForFocusStop(setupAfterStop: true)
        publishObservation()
    }

    func closePanel() {
        guard !modeSwitchPending else { return }
        cancelNativeTarget()
        retirePresentation()
        authority.update(false)
        controller?.invalidate(reason: "Focus Rack closed. Reset marks before moving focus.")
        isActive = false
        afSetupRequested = false
        afSetupManualChanges.removeAll()
        afSetupFailure = nil
        revokeAFWrite()
        afSettings.requestRestore()
        if afSettings.needsService {
            model?.showFocusAFNotice(
                "AF settings will be restored after recording and focus movement stop.")
        }
        thumbnails.removeAll()
        waitForFocusStop(setupAfterStop: false)
        publishObservation()
        send(.discardMarks)
    }

    /// Every accepted real frame supplies raw evidence in source order, without retaining pixels.
    func acceptedFrame() {
        guard isActive else { return }
        publishObservation()
    }

    private func publishObservation(suspended: Bool = false) {
        guard let model else { return }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        var observation = model.focusRackObservation()
        observation.foregroundOwner =
            observation.foregroundOwner && isActive && !suspended
            && mode == .timedRack && !modeSwitchPending && !afSettingsPending
            && afSettingsFailure == nil
        authority.update(
            observation.connected && observation.foregroundOwner && observation.externalFocusIdle)
        observations?.yield(.init(observation: observation, receivedAt: receivedAt))
    }

    func sessionChanged() {
        cancelNativeTarget()
        revokeAFWrite()
        if let request = nativeRack.dispatchedRequest { _ = nativeRack.fail(id: request.id) }
        nativeWriteAuthority = nil
        afSettings.abandon()
        afSetupManualChanges.removeAll()
        afSetupRequested = isActive && storesTemplates
        afSetupFailure = nil
        afReadinessPolls = 0
        modeSwitchTask?.cancel()
        modeSwitchTask = nil
        modeSwitchPending = false
        retirePresentation()
        authority.update(false)
        let previous = controller
        controller = nil
        stateTask?.cancel()
        observations?.finish()
        observations = nil
        observationTask?.cancel()
        contextTask?.cancel()
        state = nil
        stopPending = false
        notice = nil
        thumbnails.removeAll()
        authority = FocusRackAuthority()
        if let previous { Task { await previous.close() } }
        startObserving()
    }

    func interrupt(_ reason: String) {
        cancelNativeTarget()
        revokeAFWrite()
        retirePresentation()
        authority.update(false)
        if state?.busy == true { stopPending = true }
        controller?.suspend()
        publishObservation(suspended: true)
    }

    func recordingWillStop() {
        cancelNativeTarget()
        revokeNativeTargetAuthority()
        stop()
    }
    func stop() {
        retirePresentation()
        guard controller != nil || state?.busy == true else { return }
        stopPending = true
        controller?.requestStop()
    }
    func externalFocusAction() {
        cancelNativeTarget()
        retirePresentation()
        authority.update(false)
        if state?.busy == true { stopPending = true }
        controller?.requestStop()
        send(.externalFocusAction)
    }
    func nudge(near: Bool, steps: Int = 1) {
        guard mode == .timedRack, !modeSwitchPending, !afSettingsPending, afSettingsFailure == nil
        else { return }
        let intent = FocusRackIntent.nudge(towardNear: near, steps: steps)
        #if DEBUG
            if !storesTemplates {
                simulatedNudgeIntents.append(intent)
                return
            }
        #endif
        send(intent)
    }
    func openFocusSettings() { model?.showPicker(.focus) }
    func goTo(_ mark: String) { send(.goTo(markID: mark)) }
    func calibrate() { send(.calibrate) }
    func reset() {
        clearPendingCapture()
        send(.reset)
    }
    func performPrimary() { send(.primary) }
    func run(_ direction: FocusRackDirection) { send(.run(direction: direction)) }
    func setDirection(_ direction: FocusRackDirection) { send(.setDirection(direction)) }
    func setTransition(_ transition: FocusRackTransition) {
        #if DEBUG
            // Driver-free presentation fixtures only; movement always remains in the controller.
            if controller == nil, !storesTemplates, var fixture = state {
                fixture.transition = transition
                fixture.direction = transition.fromMark == "A" ? .aToB : .bToA
                fixture.primary.detail = transition.playbackDetail
                fixture.updateTimedActions(
                    recording: fixture.primary.kind == "run", ready: fixture.referenceValid)
                state = fixture
                return
            }
        #endif
        send(.setTransition(transition))
    }
    func updateTiming(_ update: FocusRackTimingUpdate) {
        #if DEBUG
            if controller == nil, !storesTemplates, var fixture = state {
                do {
                    fixture.transition = try fixture.transition.applying(update)
                    fixture.direction = fixture.transition.fromMark == "A" ? .aToB : .bToA
                    fixture.primary.detail = fixture.transition.playbackDetail
                    fixture.updateTimedActions(
                        recording: fixture.primary.kind == "run", ready: fixture.referenceValid)
                    state = fixture
                    notice = nil
                } catch { notice = error.localizedDescription }
                return
            }
        #endif
        send(.updateTiming(update))
    }
    func loadTemplate(_ template: FocusRackTemplate) {
        clearPendingCapture()
        send(.applyTemplate(template))
    }

    func setTimingText(_ text: String, isDelay: Bool) {
        guard state != nil else { return }
        do {
            let seconds: Double
            do { seconds = try Double(text, format: .number) } catch {
                throw InputError.invalidSeconds
            }
            updateTiming(isDelay ? .init(delay: seconds) : .init(duration: seconds))
        } catch { notice = error.localizedDescription }
    }

    private enum InputError: Error, LocalizedError {
        case invalidSeconds
        var errorDescription: String? { "Enter a number of seconds." }
    }

    func capture(_ mark: String) {
        guard mode == .timedRack, !modeSwitchPending, !afSettingsPending, afSettingsFailure == nil,
            pendingCapture == nil, let controller,
            let model,
            let frame = model.focusRackFrame()
        else { return }
        let ticket = controller.makeIntentTicket()
        let revision = presentationRevision
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let observation = model.focusRackObservation()
        let sequence = Int64(truncatingIfNeeded: frame.revision)
        let candidate = FocusRackPendingCapture(
            markID: mark, sessionID: observation.sessionID, frameSequence: sequence,
            baselineRevision: state?.captures.first(where: { $0.markID == mark })?.revision ?? 0,
            image: thumbnailImage(frame.image))
        pendingCapture = candidate
        capturingMark = mark
        let delivery = FocusRackObservationDelivery(
            observation: observation, receivedAt: receivedAt)
        Task { [weak self] in
            do {
                try await controller.handle(
                    .capture(markID: mark, expectedFrameSequence: sequence),
                    observation: delivery.aged(at: ProcessInfo.processInfo.systemUptime),
                    ticket: ticket)
                // This is only an acceptance receipt. The ordered stream alone owns UI state.
                let receipt = await controller.snapshot()
                guard let self, self.controller === controller,
                    self.pendingCapture?.id == candidate.id
                else { return }
                guard let capture = receipt.captures.first(where: candidate.matches) else {
                    self.clearPendingCapture()
                    return
                }
                self.pendingCapture?.acceptedRevision = capture.revision
                if let state = self.state { self.attachPendingCapture(to: state) }
                if self.presentationRevision == revision { self.notice = nil }
            } catch {
                guard let self, self.controller === controller,
                    self.pendingCapture?.id == candidate.id
                else { return }
                self.clearPendingCapture()
                if self.presentationRevision == revision {
                    self.notice = error.localizedDescription
                }
            }
        }
    }

    private func attachPendingCapture(to state: FocusRackState) {
        guard let candidate = pendingCapture else { return }
        guard state.referenceValid else {
            clearPendingCapture()
            return
        }
        guard let capture = state.captures.first(where: candidate.matches) else { return }
        thumbnails[candidate.markID] = .init(revision: capture.revision, image: candidate.image)
        notice = nil
        clearPendingCapture()
    }

    private func clearPendingCapture() {
        pendingCapture = nil
        capturingMark = nil
    }

    private func retirePresentation() {
        presentationRevision &+= 1
        clearPendingCapture()
    }

    func thumbnail(for mark: String) -> UIImage? {
        guard state?.referenceValid == true,
            let capture = state?.captures.first(where: { $0.markID == mark }),
            let thumbnail = thumbnails[mark], thumbnail.revision == capture.revision
        else { return nil }
        return thumbnail.image
    }

    func saveTemplate(named name: String) {
        guard let state, state.capabilities.canEditTiming else { return }
        do {
            let template = try FocusRackTemplateCodec.validate(
                .init(name: name, transition: state.transition))
            var updated = templates
            if let index = updated.firstIndex(where: { $0.name == template.name }) {
                updated[index] = template
            } else {
                updated.append(template)
            }
            persist(updated)
        } catch { notice = error.localizedDescription }
    }

    func deleteTemplate(at index: Int) {
        guard templates.indices.contains(index) else { return }
        var updated = templates
        updated.remove(at: index)
        persist(updated)
    }

    private func requestAFSetup() {
        guard storesTemplates else { return }
        revokeAFWrite()
        afSetupRequested = true
        afSetupFailure = nil
        afReadinessPolls = 0
    }

    /// Consumes only fresh same-session reads from the existing camera safe point.
    func nextAFChange(_ observation: FocusAFSettingsObservation) -> FocusAFSettingChange? {
        if afSetupRequested {
            do {
                guard let sessionID = observation.sessionID else { return nil }
                try afSettings.requestMode(mode, sessionID: sessionID, values: observation.values)
                // A fresh lease must retain picker intents received while its reads were pending.
                for property in afSetupManualChanges { afSettings.manualChange(property) }
                afSetupManualChanges.removeAll()
                afSetupRequested = false
            } catch {
                afSetupRequested = false
                afSetupFailure = error.localizedDescription
                return nil
            }
        }
        let wasRestoring = afSettings.restoring
        let change = afSettings.nextChange(observation)
        if wasRestoring, !afSettings.needsService, afSettings.failure == nil {
            model?.showFocusAFNotice("Previous AF settings restored. Manual changes were kept.")
        }
        return change
    }

    func observesAFSettings(_ values: FocusAFSettingsValues) {
        let previous = afSettings.pending
        afSettings.observe(values)
        if previous != nil, afSettings.pending != previous { revokeAFWrite() }
    }

    func manualAFChange(_ property: FocusAFProperty) {
        cancelNativeTarget()
        revokeAFWrite()
        if afSetupRequested || (isActive && modeSwitchPending) {
            afSetupManualChanges.insert(property)
        }
        afSettings.manualChange(property)
    }

    func revokeAFWrite() {
        revokeAFSettingsWrite()
        revokeNativeTargetAuthority()
    }

    func revokeAFSettingsWrite() { afWriteAuthority?.update(false) }

    func revokeNativeTargetAuthority() { nativeWriteAuthority?.update(false) }

    func admitAFChange(
        _ change: FocusAFSettingChange, observation: FocusAFSettingsObservation
    ) -> FocusRackAuthority? {
        guard !modeSwitchPending, afSettings.allows(change, observation: observation) else {
            return nil
        }
        let authority = FocusRackAuthority()
        authority.update(true)
        afWriteAuthority = authority
        return authority
    }

    func confirmsAFChange(
        _ change: FocusAFSettingChange, sessionID: String, values: FocusAFSettingsValues
    ) {
        afSettings.confirm(change, sessionID: sessionID, values: values)
        afWriteAuthority = nil
        afReadinessPolls = 0
        if let failure = afSettings.failure { model?.showFocusAFNotice(failure) }
        publishObservation()
    }

    func defersAFChange(_ change: FocusAFSettingChange) {
        revokeAFWrite()
        afWriteAuthority = nil
        afSettings.deferChange(change)
    }

    func failsAFChange(_ change: FocusAFSettingChange, message: String) {
        revokeAFWrite()
        afWriteAuthority = nil
        afSettings.fail(change, message: message)
        model?.showFocusAFNotice(message)
        publishObservation()
    }

    func failsAFPreparation(_ message: String) {
        revokeAFWrite()
        afSettings.failPreparation(message: message)
        afSetupRequested = false
        afSetupFailure = message
        model?.showFocusAFNotice(message)
    }

    /// Bounded readiness attempts never turn DeviceBusy or a failed read into permission.
    func observesAFReadiness(_ readiness: StillReleaseReadiness) -> Bool {
        switch readiness {
        case .complete:
            afReadinessPolls = 0
            return true
        case .inProgress, .openShutterInProgress:
            afReadinessPolls += 1
            if afReadinessPolls >= 8 {
                failsAFPreparation(
                    "Camera focus is still busy. Select the focus mode again when it stops.")
            }
        case .failed:
            failsAFPreparation("The camera could not confirm that focus movement stopped.")
        }
        return false
    }

    private func persist(_ updated: [FocusRackTemplate]) {
        do {
            if storesTemplates {
                try FocusRackTemplateStore.save(updated)
            } else {
                _ = try FocusRackTemplateCodec.encode(updated)
            }
            templates = updated
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    private func send(_ intent: FocusRackIntent) {
        if mode == .nativeAF || modeSwitchPending || afSettingsPending || afSettingsFailure != nil {
            switch intent {
            case .externalFocusAction, .discardMarks: break
            default: return
            }
        }
        guard let controller else { return }
        let ticket = controller.makeIntentTicket()
        let revision = presentationRevision
        Task { [weak self] in
            do {
                try await controller.handle(intent, ticket: ticket)
                guard let self, self.controller === controller,
                    self.presentationRevision == revision
                else { return }
                self.notice = nil
            } catch {
                guard let self, self.controller === controller,
                    self.presentationRevision == revision
                else { return }
                self.notice = error.localizedDescription
            }
        }
    }

    private func thumbnailImage(_ source: UIImage) -> UIImage {
        let width: CGFloat = 240
        let height = width * source.size.height / max(1, source.size.width)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
