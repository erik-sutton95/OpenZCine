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
            isAdmitted: { authority.admitted })
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
        let entry = Entry(controller: controller, authority: authority)
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
    }

    private final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = false
        private var revision = 0
        var admitted: Bool { lock.withLock { allowed } }
        var generation: Int { lock.withLock { revision } }
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

        init(controller: FocusRackController, authority: Authority) {
            self.controller = controller
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
                if let observation = request.observation {
                    externalFocusIdle = observation.externalFocusIdle
                    movieFocusMode = observation.connected ? request.movieFocusMode : nil
                    photography = request.photography ?? false
                    let admitted =
                        observation.connected && observation.foregroundOwner
                        && focusMode == .timedRack && !modeSwitchPending
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
                if request.kind == "selectFocusMode" {
                    guard let selected = request.focusMode else { return }
                    if selected == focusMode { return }
                    guard !modeSwitchPending,
                        FocusControlModePolicy.canChange(
                            rack: state, externalFocusIdle: externalFocusIdle)
                    else {
                        error = FocusRackError.movementPending.localizedDescription
                        return
                    }
                    modeSwitchPending = true
                    error = nil
                    authority.cancelPending()
                    authority.set(false)
                }
                if request.kind == "stop" || request.kind == "externalFocus" {
                    authority.cancelPending()
                    controller.requestStop()
                }
                if request.kind == "interrupt" || request.kind == "closePanel" {
                    authority.set(false)
                    authority.cancelPending()
                    controller.suspend()
                }
                let generation = authority.generation
                let ticket = controller.makeIntentTicket()
                let previous = tail
                tail = Task { [weak self, controller] in
                    await previous?.value
                    guard let self, !self.lock.withLock({ self.closed }),
                        request.kind == "selectFocusMode"
                            || generation == self.authority.generation
                    else { return }
                    do {
                        try await self.apply(request, receivedAt: receivedAt, ticket: ticket)
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
                if selected == lock.withLock({ focusMode }) { return }
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
                return
            }
            let timedIntent = ![
                "poll", "observe", "diagnostics", "loadCalibration", "stop", "interrupt",
                "closePanel", "externalFocus",
            ].contains(request.kind)
            if timedIntent && lock.withLock({ focusMode != .timedRack }) {
                throw FocusRackError.referenceUnavailable
            }
            if observation != nil && lock.withLock({ focusMode == .nativeAF }) {
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
            case "closePanel": intent = .discardMarks
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
                }
                var projectedState = state
                if modeSwitchPending { projectedState?.capabilities.canAutofocus = false }
                guard let saved = try? FocusRackTemplateCodec.encode(templates),
                    let json = String(data: saved, encoding: .utf8),
                    let data = try? JSONEncoder().encode(
                        Reply(
                            state: projectedState, error: error,
                            templates: templates, templatesJSON: json, traceJSON: traceJSON,
                            calibrationJSON: calibrationJSON, focusMode: focusMode,
                            focusModeSwitchPending: modeSwitchPending,
                            canChangeFocusMode: !modeSwitchPending
                                && FocusControlModePolicy.canChange(
                                    rack: state, externalFocusIdle: externalFocusIdle),
                            nativeAFConfigured: FocusControlModePolicy.nativeAFConfigured(
                                movieFocusMode: movieFocusMode, photography: photography),
                            canNativeAutofocus: !modeSwitchPending
                                && FocusControlModePolicy.allowsNativeAutofocus(
                                    mode: focusMode, rack: state)
                                && FocusControlModePolicy.nativeAFConfigured(
                                    movieFocusMode: movieFocusMode, photography: photography)
                        ))
                else { return nil }
                traceJSON = nil
                return String(data: data, encoding: .utf8)
            }
        }

        func close() {
            let previous: Task<Void, Never>? = lock.withLock {
                closed = true
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
