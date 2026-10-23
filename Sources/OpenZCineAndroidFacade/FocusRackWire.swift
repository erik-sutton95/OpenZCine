import Foundation
import OpenCineNikonAndroid
import OpenZCineCore

/// Owner-keyed production controllers. JNI callers submit intents and read state; Swift drives.
public final class FocusRackWire: @unchecked Sendable {
    /// Process-local registry. Marks and armed state are never persisted.
    public static let shared = FocusRackWire()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Creates an inert controller bound to the current native session owner, if present.
    public func create(connectionOwner: Int64, templatesJSON: String) -> String? {
        guard templatesJSON.utf8.count <= 65_536 else { return nil }
        let authority = Authority()
        let access = NikonAndroidFocusRackAccess.capture(
            connectionOwner: connectionOwner, cadence: .fastExperimental,
            isAdmitted: { authority.admitted || authority.settingsReadAdmitted })
        let driver: any FocusRackDriver
        if let access { driver = access } else { driver = UnavailableDriver() }
        return register(
            driver: driver, authority: authority, templatesJSON: templatesJSON,
            profile: .calibratedFineExperiment)
    }

    // A fake driver exercises the actual wire and runner in host tests without a camera or JNI.
    func create(
        driver: any FocusRackDriver, templatesJSON: String = "[]",
        clock: FocusRackClock = .monotonic
    ) -> String? {
        guard templatesJSON.utf8.count <= 65_536 else { return nil }
        return register(
            driver: driver, authority: Authority(), templatesJSON: templatesJSON, clock: clock)
    }

    private func register(
        driver: any FocusRackDriver, authority: Authority,
        templatesJSON: String, clock: FocusRackClock = .monotonic,
        profile: FocusRackProfile = .adaptive
    ) -> String {
        let controller = FocusRackController(driver: driver, clock: clock, profile: profile)
        let entry = Entry(controller: controller, driver: driver, authority: authority)
        entry.loadTemplates(templatesJSON)
        let owner = UUID().uuidString
        lock.withLock { entries[owner] = entry }
        entry.start()
        return owner
    }

    /// Queues semantic intents in arrival order. Stop and authority loss also signal synchronously.
    public func step(owner: String, requestJSON: String) -> String? {
        guard requestJSON.utf8.count <= 16_384, let data = requestJSON.data(using: .utf8),
            let request = try? JSONDecoder().decode(Request.self, from: data),
            let entry = lock.withLock({ entries[owner] })
        else { return nil }
        if request.kind == "afSettingsAdmission" { return entry.admissionReply(request) }
        entry.submit(request)
        return entry.reply()
    }

    /// Revokes native activation before waiting for the controller's in-flight work to retire.
    public func close(owner: String) {
        lock.withLock { entries.removeValue(forKey: owner) }?.close()
    }

    private struct Request: Decodable, Sendable {
        let kind: String
        let observation: FocusRackObservation?
        let markID: String?
        let direction: FocusRackDirection?
        let expectedFrameSequence: Int64?
        let towardNear: Bool?
        let steps: Int?
        let transition: FocusRackTransition?
        let timingUpdate: FocusRackTimingUpdate?
        let template: FocusRackTemplate?
        let name: String?
        let calibrationJSON: String?
        let focusMode: FocusControlMode?
        let movieFocusMode: String?
        let photography: Bool?
        let afSettings: SettingsInput?
        let afProperty: FocusAFProperty?
        let afChange: FocusAFSettingChange?
        let afFailure: String?
    }

    private struct SettingsInput: Decodable, Equatable, Sendable {
        let sessionID: String?
        var values: FocusAFSettingsValues
        let recording: Bool?
        let recordingPending: Bool
        let movie: Bool
        var foreground: Bool
        let focusIdle: Bool
        let restorationFocusSettled: Bool
        let commandsIdle: Bool
        let frameSequence: Int64?
        let focusAfterSequence: Int64?

        private var postActionFocusIdle: Bool {
            guard focusIdle else { return false }
            guard let focusAfterSequence else { return true }
            return frameSequence.map { $0 > focusAfterSequence } == true
        }

        // New headers may arrive during readiness I/O; only changed safety facts revoke it.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sessionID == rhs.sessionID && lhs.values == rhs.values
                && lhs.recording == rhs.recording && lhs.recordingPending == rhs.recordingPending
                && lhs.movie == rhs.movie && lhs.foreground == rhs.foreground
                && lhs.postActionFocusIdle == rhs.postActionFocusIdle
                && lhs.restorationFocusSettled == rhs.restorationFocusSettled
                && lhs.commandsIdle == rhs.commandsIdle
        }

        func observation(rack: FocusRackState?, ready: Bool) -> FocusAFSettingsObservation {
            .init(
                sessionID: sessionID, values: values, recording: recording,
                recordingPending: recordingPending, movie: movie, foreground: foreground,
                focusIdle: postActionFocusIdle && ready,
                restorationFocusSettled: restorationFocusSettled,
                commandsIdle: commandsIdle, rack: rack)
        }
    }

    private final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = false
        private var revision = 0
        var admitted: Bool { lock.withLock { allowed } }
        var generation: Int { lock.withLock { revision } }
        private var safetyAllowed = false
        var settingsReadAdmitted: Bool { lock.withLock { safetyAllowed } }
        func setSettingsRead(_ value: Bool) { lock.withLock { safetyAllowed = value } }
        func cancelPending() { lock.withLock { revision += 1 } }
        @discardableResult func set(_ value: Bool) -> Bool {
            lock.withLock {
                let previous = allowed
                if allowed && !value { revision += 1 }
                allowed = value
                return previous
            }
        }
    }

    private final class Entry: @unchecked Sendable {
        let controller: FocusRackController
        let driver: any FocusRackDriver
        let authority: Authority
        private let lock = NSLock()
        private var state: FocusRackState?
        private var error: String?
        private var traceJSON: String?
        private var calibrationJSON: String?
        private var templates: [FocusRackTemplate] = []
        private var tail: Task<Void, Never>?
        private var observer: Task<Void, Never>?
        private var closed = false
        private var wasRecording = false
        private var focusMode = FocusControlMode.timedRack
        private var movieFocusMode: String?
        private var photography = false
        private var externalFocusIdle = true
        private var modeSwitchPending = false
        private var afLease = FocusAFSettingsLease()
        private var afInput: SettingsInput?
        private var afRevision = 0
        private var afEffectReady = false
        private var afEffectOffered = false
        private var afSuspended = false
        private var afFailure: String?
        private var afSetupReady = false
        private var afSetupRequested = false
        private var afManualBeforeCapture: Set<FocusAFProperty> = []
        private var panelOpen = false

        init(controller: FocusRackController, driver: any FocusRackDriver, authority: Authority) {
            self.controller = controller
            self.driver = driver
            self.authority = authority
        }

        func loadTemplates(_ json: String) {
            do {
                let decoded = try FocusRackTemplateCodec.decode(Data(json.utf8))
                lock.withLock { templates = decoded }
            } catch { lock.withLock { self.error = "Saved timing templates could not be loaded." } }
        }

        func start() {
            observer = Task { [weak self, controller] in
                var previousCalibration: FocusRackCalibration?
                for await state in await controller.states() {
                    guard let self, !Task.isCancelled else { return }
                    var saved: String?
                    if !state.busy, let checkpoint = await controller.calibrationCheckpoint(),
                        checkpoint != previousCalibration
                    {
                        saved = (try? FocusRackCalibrationCodec.encode(checkpoint))
                            .flatMap { String(data: $0, encoding: .utf8) }
                        if saved != nil { previousCalibration = checkpoint }
                    }
                    self.lock.withLock {
                        self.state = state
                        if let saved { self.calibrationJSON = saved }
                    }
                }
            }
        }

        func submit(_ request: Request) {
            let receivedAt = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                guard !closed else { return }
                acceptSettingsInput(request.afSettings)
                if request.kind == "manualAFSetting", let property = request.afProperty {
                    if afSetupRequested { afManualBeforeCapture.insert(property) }
                    afLease.manualChange(property)
                    afRevision += 1
                    afEffectReady = false
                    authority.setSettingsRead(false)
                }
                if let observation = request.observation {
                    externalFocusIdle = observation.externalFocusIdle
                    movieFocusMode = observation.connected ? request.movieFocusMode : nil
                    photography = request.photography ?? false
                    let admitted =
                        observation.connected && observation.foregroundOwner
                        && focusMode == .timedRack && !modeSwitchPending
                        && (!panelOpen || afSetupReady) && !afLease.needsService
                    let wasAdmitted = authority.set(admitted)
                    if wasRecording && !observation.recording {
                        authority.cancelPending()
                        controller.requestStop()
                    }
                    wasRecording = observation.recording
                    if wasAdmitted && !admitted {
                        controller.suspend()
                    }
                }
                if request.kind == "resumeAFSettings" { afSuspended = false }
                if request.kind == "interrupt" {
                    afSuspended = true
                    afInput?.foreground = false
                    afRevision += 1
                    afEffectReady = false
                    authority.setSettingsRead(false)
                }
                if request.kind == "openPanel" {
                    afSetupRequested = true
                    afManualBeforeCapture.removeAll()
                    afSuspended = false
                    panelOpen = true
                    afSetupReady = false
                    authority.cancelPending()
                    authority.set(false)
                    controller.suspend()
                }
                if request.kind == "selectFocusMode" {
                    guard request.focusMode != nil else { return }
                    guard !modeSwitchPending, afLease.pending == nil,
                        FocusControlModePolicy.canChange(
                            rack: state, externalFocusIdle: externalFocusIdle)
                    else {
                        error = FocusRackError.movementPending.localizedDescription
                        return
                    }
                    afSetupRequested = true
                    afManualBeforeCapture.removeAll()
                    afSuspended = false
                    modeSwitchPending = true
                    afSetupReady = false
                    afEffectReady = false
                    afRevision += 1
                    authority.setSettingsRead(false)
                    error = nil
                    authority.cancelPending()
                    authority.set(false)
                }
                if request.kind == "stop" || request.kind == "externalFocus" {
                    authority.cancelPending()
                    controller.requestStop()
                }
                if request.kind == "closePanel" {
                    afSetupRequested = false
                    afManualBeforeCapture.removeAll()
                    panelOpen = false
                    afSetupReady = false
                    afEffectReady = false
                    afFailure = nil
                    afLease.requestRestore()
                    authority.setSettingsRead(false)
                }
                if request.kind == "interrupt" || request.kind == "closePanel" {
                    authority.set(false)
                    authority.cancelPending()
                    controller.suspend()
                }
                let generation = authority.generation
                let ticket = controller.makeIntentTicket()
                let previous = tail
                tail = Task { [weak self] in
                    await previous?.value
                    guard let self, !self.lock.withLock({ self.closed }),
                        [
                            "selectFocusMode", "openPanel", "closePanel", "manualAFSetting",
                            "afSettingsComplete", "afSettingsDeferred", "resumeAFSettings",
                            "observe", "poll",
                        ].contains(request.kind)
                            || generation == self.authority.generation
                    else { return }
                    do {
                        try await self.apply(request, receivedAt: receivedAt, ticket: ticket)
                        await self.serviceSettings()
                        if request.kind != "observe" && request.kind != "poll" {
                            self.lock.withLock {
                                if !self.closed && generation == self.authority.generation {
                                    self.error = nil
                                }
                            }
                        }
                    } catch {
                        self.lock.withLock {
                            if request.kind == "selectFocusMode" { self.modeSwitchPending = false }
                            if !self.closed && generation == self.authority.generation {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }

        private func apply(_ request: Request, receivedAt: Double, ticket: FocusRackIntentTicket)
            async throws
        {
            var observation = request.observation
            if observation != nil {
                observation?.frameAgeSeconds += max(
                    0, ProcessInfo.processInfo.systemUptime - receivedAt)
            }
            if request.kind == "selectFocusMode" {
                guard let selected = request.focusMode else {
                    throw FocusRackError.invalidConfiguration
                }
                let current = await controller.snapshot()
                lock.withLock { state = current }
                guard
                    FocusControlModePolicy.canChange(
                        rack: current, externalFocusIdle: lock.withLock { externalFocusIdle })
                else { throw FocusRackError.movementPending }
                lock.withLock {
                    focusMode = selected
                    modeSwitchPending = true
                    error = nil
                    authority.cancelPending()
                    authority.set(false)
                }
                controller.suspend()
                if var admitted = observation {
                    admitted.foregroundOwner = false
                    await controller.observe(admitted)
                } else {
                    // A synthetic inactive observation applies the control fence without restoring authority.
                    await controller.observe(
                        .init(
                            sessionID: "unavailable", connected: false, foregroundOwner: false,
                            recording: false, frameSequence: nil, focus: nil))
                }
                // Subscribe after suspension was applied. Cached idle state cannot acknowledge cleanup.
                for await fresh in await controller.states() {
                    if (!fresh.busy && !fresh.capabilities.canStop)
                        || fresh.phase == .stopUnconfirmed
                    {
                        lock.withLock {
                            state = fresh
                            modeSwitchPending = false
                        }
                        break
                    }
                }
                try lock.withLock { try requestSettings(selected) }
                return
            }
            if request.kind == "openPanel" {
                try lock.withLock { try requestSettings(focusMode) }
                controller.suspend()
                if var observation {
                    observation.foregroundOwner = false
                    await controller.observe(observation)
                } else {
                    await controller.observe(
                        .init(
                            sessionID: "unavailable", connected: false,
                            foregroundOwner: false, recording: false,
                            frameSequence: nil, focus: nil))
                }
                for await fresh in await controller.states() {
                    if (!fresh.busy && !fresh.capabilities.canStop)
                        || fresh.phase == .stopUnconfirmed
                    {
                        break
                    }
                }
                return
            }
            if request.kind == "manualAFSetting" || request.kind == "resumeAFSettings" { return }
            if request.kind == "afSettingsDeferred", let change = request.afChange {
                lock.withLock {
                    afLease.deferChange(change)
                    afEffectReady = false
                }
                return
            }
            if request.kind == "afSettingsComplete", let change = request.afChange {
                lock.withLock {
                    if let message = request.afFailure {
                        afLease.fail(change, message: message)
                    } else if let input = afInput, let sessionID = input.sessionID {
                        afLease.confirm(change, sessionID: sessionID, values: input.values)
                    }
                    afEffectReady = false
                }
                return
            }
            let timedIntent = ![
                "poll", "observe", "diagnostics", "loadCalibration", "stop", "interrupt",
                "closePanel", "externalFocus",
            ].contains(request.kind)
            if timedIntent
                && lock.withLock({
                    focusMode != .timedRack || afLease.needsService || (panelOpen && !afSetupReady)
                })
            {
                throw FocusRackError.referenceUnavailable
            }
            if observation != nil
                && lock.withLock({
                    focusMode == .nativeAF || afLease.needsService || (panelOpen && !afSetupReady)
                })
            {
                observation?.foregroundOwner = false
            }
            let intent: FocusRackIntent
            switch request.kind {
            case "loadCalibration":
                guard let json = request.calibrationJSON else {
                    throw FocusRackError.invalidConfiguration
                }
                try await controller.loadCalibration(
                    FocusRackCalibrationCodec.decode(Data(json.utf8)))
                return
            case "diagnostics":
                let data = try JSONEncoder().encode(await controller.diagnostics())
                lock.withLock { traceJSON = String(data: data, encoding: .utf8) }
                return
            case "poll", "observe":
                if let observation { await controller.observe(observation) }
                return
            case "capture":
                guard let id = request.markID, let sequence = request.expectedFrameSequence else {
                    throw FocusRackError.invalidConfiguration
                }
                intent = .capture(markID: id, expectedFrameSequence: sequence)
            case "nudge":
                intent = .nudge(towardNear: request.towardNear ?? false, steps: request.steps ?? 1)
            case "goTo": intent = .goTo(markID: request.markID ?? "")
            case "calibrate": intent = .calibrate
            case "run":
                guard let direction = request.direction else {
                    throw FocusRackError.invalidConfiguration
                }
                intent = .run(direction: direction)
            case "updateTiming":
                guard let update = request.timingUpdate else {
                    throw FocusRackError.invalidConfiguration
                }
                intent = .updateTiming(update)
            case "timing":
                guard let transition = request.transition else {
                    throw FocusRackError.invalidConfiguration
                }
                intent = .setTransition(transition)
            case "primary": intent = .performPrimary
            case "start": intent = .start
            case "pause": intent = .pause
            case "resume": intent = .resume
            case "stop": return  // Already published synchronously at request receipt.
            case "reset": intent = .reset
            case "externalFocus": intent = .externalFocusAction
            case "interrupt": return
            case "closePanel":
                lock.withLock {
                    panelOpen = false
                    afSetupReady = false
                    afFailure = nil
                    afLease.requestRestore()
                }
                intent = .discardMarks
            case "loadTemplate":
                guard let template = request.template else {
                    throw FocusRackError.invalidConfiguration
                }
                intent = .applyTemplate(template)
            case "saveTemplate":
                let state = await controller.snapshot()
                let template = try FocusRackTemplateCodec.validate(
                    FocusRackTemplate(name: request.name ?? "", transition: state.transition))
                let candidate = lock.withLock {
                    templates.filter { $0.name != template.name } + [template]
                }
                _ = try FocusRackTemplateCodec.encode(candidate)
                lock.withLock { templates = candidate }
                return
            case "deleteTemplate":
                lock.withLock { templates.removeAll { $0.name == request.name } }
                return
            default: throw FocusRackError.invalidConfiguration
            }
            try await controller.handle(intent, observation: observation, ticket: ticket)
        }

        // All ownership mutation and comparisons share the entry lock; I/O stays outside it.
        private func acceptSettingsInput(_ input: SettingsInput?) {
            guard let input else { return }
            if afInput?.sessionID != input.sessionID {
                afSetupRequested = false
                afManualBeforeCapture.removeAll()
            }
            if input != afInput {
                afRevision += 1
                afEffectReady = false
                if !afEffectOffered, let change = afLease.pending { afLease.deferChange(change) }
                authority.setSettingsRead(false)
            }
            if let owner = afLease.sessionID, input.sessionID != owner {
                afLease.abandon()
                afEffectReady = false
                afSetupReady = false
                afFailure = nil
            }
            afInput = input
            afLease.observe(input.values)
        }

        private func requestSettings(_ mode: FocusControlMode) throws {
            guard afSetupRequested else { return }
            defer {
                afSetupRequested = false
                afManualBeforeCapture.removeAll()
            }
            afSetupReady = false
            afFailure = nil
            afEffectReady = false
            guard let input = afInput, let sessionID = input.sessionID else {
                afFailure = FocusAFSettingsError.unavailable.localizedDescription
                throw FocusAFSettingsError.unavailable
            }
            do {
                try afLease.requestMode(mode, sessionID: sessionID, values: input.values)
                for property in afManualBeforeCapture { afLease.manualChange(property) }
            } catch {
                afFailure = error.localizedDescription
                throw error
            }
            authority.set(false)
        }

        private func serviceSettings() async {
            let current = await controller.snapshot()
            let start: (SettingsInput, Int)? = lock.withLock {
                state = current
                guard !closed, !afSuspended, !afSetupRequested, !modeSwitchPending,
                    afLease.needsService, afLease.pending == nil,
                    afFailure == nil, let input = afInput
                else { return nil }
                _ = afLease.nextChange(input.observation(rack: current, ready: false))
                if !afLease.needsService {
                    if panelOpen { afSetupReady = true }
                    return nil
                }
                guard
                    input.observation(rack: current, ready: true).permitsWrite(
                        restoring: afLease.restoring)
                else { return nil }
                authority.set(false)
                authority.setSettingsRead(true)
                return (input, afRevision)
            }
            guard let (input, revision) = start else { return }
            do {
                let safety = try await driver.refreshSafety()
                let change: FocusAFSettingChange? = lock.withLock {
                    authority.setSettingsRead(false)
                    guard !closed, revision == afRevision, afInput == input else { return nil }
                    let values = FocusAFSettingsValues(
                        mode: safety.focusMode, area: safety.focusArea,
                        subject: safety.focusSubject)
                    guard safety.movieMode, values == input.values else {
                        afLease.observe(values)
                        return nil
                    }
                    let change = afLease.nextChange(input.observation(rack: current, ready: true))
                    afEffectOffered = false
                    if !afLease.needsService && panelOpen { afSetupReady = true }
                    return change
                }
                guard let change else { return }
                // A real configuration write can activate AF. Invalidate the relative rack first.
                try await controller.handle(.externalFocusAction)
                let invalidated = await controller.snapshot()
                lock.withLock {
                    state = invalidated
                    guard let latest = afInput,
                        afLease.allows(
                            change, observation: latest.observation(rack: invalidated, ready: true))
                    else {
                        afLease.deferChange(change)
                        return
                    }
                    afEffectReady = true
                }
            } catch {
                lock.withLock {
                    authority.setSettingsRead(false)
                    guard !closed, revision == afRevision else { return }
                    afLease.failPreparation(message: error.localizedDescription)
                }
            }
        }

        func admissionReply(_ request: Request) -> String? {
            lock.withLock {
                acceptSettingsInput(request.afSettings)
                let allowed =
                    request.afChange.map { change in
                        afEffectReady && !afSuspended
                            && afInput.map {
                                afLease.allows(
                                    change, observation: $0.observation(rack: state, ready: true))
                            } == true
                    } ?? false
                return "{\"allowed\":\(allowed)}"
            }
        }

        func reply() -> String? {
            lock.withLock {
                struct Reply: Encodable {
                    let state: FocusRackState?
                    let error: String?
                    let templates: [FocusRackTemplate]
                    let templatesJSON: String
                    let traceJSON: String?
                    let calibrationJSON: String?
                    let focusMode: FocusControlMode
                    let focusModeSwitchPending: Bool
                    let canChangeFocusMode: Bool
                    let nativeAFConfigured: Bool
                    let canNativeAutofocus: Bool
                    let afSettingsChange: FocusAFSettingChange?
                    let afSettingsExpectedValues: FocusAFSettingsValues?
                    let afSettingsPending: Bool
                    let afSettingsRestoring: Bool
                    let afSettingsReady: Bool
                    let afSettingsFailure: String?
                }
                var projectedState = state
                let settingsBlocked = afLease.needsService || (panelOpen && !afSetupReady)
                if modeSwitchPending || settingsBlocked {
                    projectedState?.capabilities.canAutofocus = false
                    projectedState?.capabilities.canNudge = false
                    projectedState?.capabilities.canCaptureA = false
                    projectedState?.capabilities.canCaptureB = false
                    projectedState?.capabilities.canGoToA = false
                    projectedState?.capabilities.canGoToB = false
                    projectedState?.primary.enabled = false
                    projectedState?.pullAToB?.enabled = false
                    projectedState?.pullBToA?.enabled = false
                    projectedState?.calibration?.enabled = false
                }
                guard let saved = try? FocusRackTemplateCodec.encode(templates),
                    let json = String(data: saved, encoding: .utf8),
                    let data = try? JSONEncoder().encode(
                        Reply(
                            state: projectedState, error: error,
                            templates: templates, templatesJSON: json, traceJSON: traceJSON,
                            calibrationJSON: calibrationJSON, focusMode: focusMode,
                            focusModeSwitchPending: modeSwitchPending,
                            canChangeFocusMode: !modeSwitchPending && afLease.pending == nil
                                && FocusControlModePolicy.canChange(
                                    rack: state, externalFocusIdle: externalFocusIdle),
                            nativeAFConfigured: FocusControlModePolicy.nativeAFConfigured(
                                movieFocusMode: movieFocusMode, photography: photography),
                            canNativeAutofocus: !modeSwitchPending && !settingsBlocked
                                && FocusControlModePolicy.allowsNativeAutofocus(
                                    mode: focusMode, rack: state)
                                && FocusControlModePolicy.nativeAFConfigured(
                                    movieFocusMode: movieFocusMode, photography: photography),
                            afSettingsChange: afEffectReady ? afLease.pending : nil,
                            afSettingsExpectedValues: afEffectReady ? afInput?.values : nil,
                            afSettingsPending: afLease.needsService,
                            afSettingsRestoring: afLease.restoring,
                            afSettingsReady: afSetupReady,
                            afSettingsFailure: afFailure ?? afLease.failure
                        ))
                else { return nil }
                if afEffectReady && afLease.pending != nil { afEffectOffered = true }
                traceJSON = nil
                return String(data: data, encoding: .utf8)
            }
        }

        func close() {
            let previous: Task<Void, Never>? = lock.withLock {
                closed = true
                afSetupRequested = false
                afManualBeforeCapture.removeAll()
                afLease.abandon()
                authority.setSettingsRead(false)
                authority.set(false)
                authority.cancelPending()
                controller.invalidate(reason: "Camera owner retired.")
                observer?.cancel()
                return tail
            }
            Task { [controller] in
                await previous?.value
                await controller.close()
            }
        }
    }

    private struct UnavailableDriver: FocusRackDriver {
        let isCurrent: @Sendable () -> Bool = { false }
        let prepareRun: @Sendable (Int64) -> Bool = { _ in false }
        let requestStop: @Sendable (Int64) -> Void = { _ in }
        let driveChunk: @Sendable (Int64, Bool, UInt32) async -> NikonFocusRackDriveOutcome = {
            _, _, _ in .cancelledBeforeActivation
        }
        let refreshSafety: @Sendable () async throws -> NikonFocusRackSafetySnapshot = {
            throw FocusRackError.referenceUnavailable
        }
    }
}
