import Foundation
import MonitorPresentation
import Observation
import OpenZCineCore
import UIKit
import os

#if DEBUG
    /// Serial background file I/O; cancellation follows the diagnostic task across the actor hop.
    private actor FocusRackDiagnosticWriter {
        static let shared = FocusRackDiagnosticWriter()

        func write(_ trace: FocusRackDiagnostics, to url: URL) throws {
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(trace)
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
        }
    }
#endif

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
    private(set) var state: FocusRackState?
    private(set) var templates: [FocusRackTemplate] = []
    private(set) var notice: String?
    private(set) var stopPending = false
    private(set) var capturingMark: String?
    var isExpanded = true
    var panelPosition: MonitorScopePoint?
    private(set) var isActive = true
    @ObservationIgnored private weak var model: NativeAppModel?
    @ObservationIgnored private var controller: FocusRackController?
    @ObservationIgnored private var authority = FocusRackAuthority()
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var observations:
        AsyncStream<FocusRackObservationDelivery>.Continuation?
    @ObservationIgnored private var pendingCapture: FocusRackPendingCapture?
    @ObservationIgnored private var presentationRevision: UInt64 = 0
    @ObservationIgnored private var storesTemplates = true
    private var thumbnails: [String: Thumbnail] = [:]
    #if DEBUG
        /// Driver-free fixture evidence; real sessions never populate this list.
        private(set) var simulatedNudgeIntents: [FocusRackIntent] = []
    #endif

    private struct Thumbnail {
        let revision: Int64
        let image: UIImage
    }

    var allowsAutofocus: Bool { !isActive || (state?.capabilities.canAutofocus ?? true) }

    init(model: NativeAppModel) {
        self.model = model
        do { templates = try FocusRackTemplateStore.load() } catch {
            notice = error.localizedDescription
        }
    }

    #if DEBUG
        /// SIMULATED UI-only state. It has no camera driver and can never move a lens.
        init(fixture: FocusRackState) {
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
            profile: .tenBy160Experiment)
        self.controller = controller
        stateTask = Task { [weak self] in
            let states = await controller.states()
            for await state in states {
                guard let self, self.controller === controller, !Task.isCancelled else { return }
                #if DEBUG
                    self.present(state) { [weak self] in
                        let trace = await controller.diagnostics()
                        guard let self, self.controller === controller, !Task.isCancelled else {
                            return
                        }
                        if let directory = FileManager.default.urls(
                            for: .documentDirectory, in: .userDomainMask
                        ).first {
                            try? await FocusRackDiagnosticWriter.shared.write(
                                trace,
                                to: directory.appendingPathComponent("focus-rack-production.json"))
                        }
                    }
                #else
                    self.present(state)
                #endif
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

    /// Publishes controls immediately; diagnostic export cannot hold or replace UI state.
    func present(
        _ state: FocusRackState, exportDiagnostics: (@MainActor () async -> Void)? = nil
    ) {
        let shouldExport =
            !state.busy
            && (self.state?.busy == true || self.state?.transition != state.transition)
        self.state = state
        if !state.busy { stopPending = false }
        attachPendingCapture(to: state)
        thumbnails = thumbnails.filter { id, thumbnail in
            state.captures.contains { $0.markID == id && $0.revision == thumbnail.revision }
        }
        if shouldExport, let exportDiagnostics {
            diagnosticTask?.cancel()
            diagnosticTask = Task { await exportDiagnostics() }
        }
    }

    func open() {
        isActive = true
        isExpanded = true
        startObserving()
        publishObservation()
    }

    func closePanel() {
        retirePresentation()
        authority.update(false)
        controller?.invalidate(reason: "Focus Rack closed. Reset marks before moving focus.")
        isActive = false
        thumbnails.removeAll()
        publishObservation()
        send(.discardMarks)
    }

    /// Every accepted real frame supplies raw evidence in source order, without retaining pixels.
    func acceptedFrame() {
        guard isActive else { return }
        publishObservation()
    }

    private func publishObservation() {
        guard let model else { return }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        var observation = model.focusRackObservation()
        observation.foregroundOwner = observation.foregroundOwner && isActive
        authority.update(
            observation.connected && observation.foregroundOwner && observation.externalFocusIdle)
        observations?.yield(.init(observation: observation, receivedAt: receivedAt))
    }

    func sessionChanged() {
        retirePresentation()
        authority.update(false)
        let previous = controller
        controller = nil
        stateTask?.cancel()
        diagnosticTask?.cancel()
        diagnosticTask = nil
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
        retirePresentation()
        authority.update(false)
        if state?.busy == true { stopPending = true }
        controller?.invalidate(reason: reason)
    }

    func recordingWillStop() { stop() }
    func stop() {
        retirePresentation()
        guard controller != nil || state?.busy == true else { return }
        stopPending = true
        controller?.requestStop()
    }
    func externalFocusAction() {
        retirePresentation()
        authority.update(false)
        if state?.busy == true { stopPending = true }
        controller?.requestStop()
        send(.externalFocusAction)
    }
    func nudge(near: Bool, steps: Int = 1) {
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
        guard pendingCapture == nil, let controller, let model,
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
