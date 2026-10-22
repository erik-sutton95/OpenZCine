import Foundation
import OpenZCineCore
import Testing
import UIKit

@testable import Runner

@MainActor @Suite("Focus rack native adapters")
struct FocusRackAdapterTests {
    @Test("Setup forwards the same single and ten-step intents in both directions")
    func setupNudgeCountsArePreserved() {
        let adapter = FocusRackModel(fixture: .initial)
        adapter.nudge(near: true)
        adapter.nudge(near: false)
        adapter.nudge(near: true, steps: 10)
        adapter.nudge(near: false, steps: 10)
        let expected = [(true, 1), (false, 1), (true, 10), (false, 10)]
        #expect(adapter.simulatedNudgeIntents.count == expected.count)
        for (intent, (near, steps)) in zip(adapter.simulatedNudgeIntents, expected) {
            guard case .nudge(let actualNear, let actualSteps) = intent else {
                Issue.record("Expected a setup nudge")
                continue
            }
            #expect(actualNear == near)
            #expect(actualSteps == steps)
        }
    }

    @Test("Switching duration modes preserves timed values, direction and marks")
    func durationModePreservesTiming() throws {
        var fixture = FocusRackState.initial
        fixture.transition = .init(
            fromMark: "B", toMark: "A", duration: 20, delay: 2, easing: .linear)
        fixture.program.marks = [.init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 80)]
        let adapter = FocusRackModel(fixture: fixture)
        var transition = fixture.transition
        transition.durationMode = .fastest
        adapter.setTransition(transition)
        adapter.setTimingText("3", isDelay: true)
        let fastest = try #require(adapter.state)
        #expect(fastest.transition.durationMode == .fastest)
        #expect(fastest.transition.duration == 20)
        #expect(fastest.transition.delay == 3)
        #expect(fastest.transition.easing == .linear)
        #expect(fastest.direction == .bToA)
        #expect(fastest.program.marks == fixture.program.marks)
        transition = fastest.transition
        transition.durationMode = .timed
        adapter.setTransition(transition)
        #expect(adapter.state?.transition.duration == 20)
        #expect(adapter.state?.transition.delay == 3)
    }

    @Test("Delayed diagnostics cannot hold controls or restore an old session snapshot")
    func diagnosticsNeverOwnPresentedState() async throws {
        var busy = FocusRackState.initial
        busy.busy = true
        let adapter = FocusRackModel(fixture: busy)
        var idle = busy
        idle.busy = false
        var release: CheckedContinuation<Void, Never>?
        var exported = false
        adapter.present(idle) {
            await withCheckedContinuation { release = $0 }
            exported = true
        }
        #expect(adapter.state?.busy == false)
        for _ in 0..<100 where release == nil { await Task.yield() }
        let pending = try #require(release)
        idle.transition.duration = 1
        idle.updateTimedActions(recording: false, ready: true)
        adapter.present(idle)
        #expect(adapter.state?.transition.duration == 1)
        #expect(adapter.state?.pullAToB?.detail == "1 s pull")
        adapter.sessionChanged()
        pending.resume()
        for _ in 0..<100 where !exported { await Task.yield() }
        #expect(exported)
        #expect(adapter.state == nil)
    }

    @Test("Timing templates survive native storage without any lens state")
    func timingTemplatesRoundTrip() throws {
        let suite = "SIMULATED-focus-rack-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let templates = [
            FocusRackTemplate(
                name: "Slow reveal", transition: .init(duration: 8, delay: 2, easing: .linear))
        ]
        try FocusRackTemplateStore.save(templates, to: defaults)
        #expect(try FocusRackTemplateStore.load(from: defaults) == templates)
        let data = try #require(defaults.data(forKey: "focusRack.timingTemplates.v1"))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("stepPosition"))
        #expect(!json.contains("frameSequence"))
        #expect(!json.contains("thumbnail"))
        #expect(!json.contains("marks"))
    }

    @Test("Calibration survives storage without marks and rejects a corrupt replacement")
    func calibrationCheckpointRoundTrip() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("calibration.json")
        #expect(try FocusRackCalibrationStore.load(from: url) == nil)
        let saved = FocusRackCalibration(
            key: .init(
                cameraID: "synthetic-body", transport: "usb", lens: "synthetic lens",
                focalLength: "70", focusMode: "AF-S", focusArea: "Auto", focusSubject: "Off"),
            commandDurations: [64: 0.117, 128: 0.08])
        try FocusRackCalibrationStore.save(saved, to: url)
        #expect(try FocusRackCalibrationStore.load(from: url) == saved)
        let data = try Data(contentsOf: url)
        let json = String(decoding: data, as: UTF8.self)
        for field in ["marks", "stepPosition", "sessionID", "frameSequence", "safetyTimestamp"] {
            #expect(!json.contains(field))
        }
        let invalid = FocusRackCalibration(key: saved.key, commandDurations: [128: -1])
        #expect(throws: (any Error).self) {
            try FocusRackCalibrationStore.save(invalid, to: url)
        }
        #expect(try Data(contentsOf: url) == data)
        try Data("invalid".utf8).write(to: url)
        #expect(throws: (any Error).self) { try FocusRackCalibrationStore.load(from: url) }
    }

    @Test("Corrupt saved timing is surfaced instead of silently replacing it")
    func corruptTimingIsReported() throws {
        let suite = "SIMULATED-focus-rack-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "focusRack.timingTemplates.v1")
        #expect(throws: (any Error).self) { try FocusRackTemplateStore.load(from: defaults) }
        #expect(defaults.data(forKey: "focusRack.timingTemplates.v1") == Data("invalid".utf8))
    }

    @Test("Opening setup keeps the root-owned adapter and suppresses the legacy dial")
    func setupDoesNotOwnControllerLifetime() throws {
        let model = NativeAppModel()
        model.openFocusRack()
        let original = try #require(model.focusRack)
        original.isExpanded = false
        model.openFocusRack()
        #expect(model.focusRack === original)
        #expect(original.isExpanded)
        #expect(!model.showsMFDriveScrub)
        original.closePanel()
        #expect(!original.isActive)
        #expect(original.allowsAutofocus)
        model.openFocusRack()
        #expect(model.focusRack === original)
        #expect(original.isActive)
    }

    @Test("Actual session teardown removes stale enabled controls and thumbnails immediately")
    func sessionReplacementClearsDisplayedState() {
        var state = FocusRackState.initial
        state.busy = true
        state.capabilities.canCaptureA = true
        state.primary = .init(kind: "run", title: "Run A→B", enabled: true)
        let adapter = FocusRackModel(fixture: state)
        adapter.stop()
        #expect(adapter.stopPending)
        adapter.sessionChanged()
        #expect(adapter.state == nil)
        #expect(!adapter.stopPending)
        #expect(adapter.thumbnail(for: "A") == nil)
    }

    @Test("The shell obeys the shared autofocus capability")
    func focusAdmissionComesFromSharedState() {
        let model = NativeAppModel()
        model.isDemoSession = true
        model.demoSeedFocusPair()
        let before = model.liveViewFocus
        var state = FocusRackState.initial
        state.capabilities.canAutofocus = false
        model.focusRack = FocusRackModel(fixture: state)
        model.setFocusPoint(at: CGPoint(x: 10, y: 10), feedSize: CGSize(width: 100, height: 100))
        model.resetFocusPoint()
        #expect(model.liveViewFocus == before)

        state.capabilities.canAutofocus = true
        model.focusRack = FocusRackModel(fixture: state)
        model.setFocusPoint(at: CGPoint(x: 10, y: 10), feedSize: CGSize(width: 100, height: 100))
        #expect(model.liveViewFocus != before)
    }

    @Test("A typed focus-setting intent stops the rack and revises acquisition before queueing")
    func typedFocusSettingInvalidation() {
        let model = NativeAppModel()
        var state = FocusRackState.initial
        state.phase = .moving
        state.busy = true
        let adapter = FocusRackModel(fixture: state)
        model.focusRack = adapter
        let before = model.focusRackObservation().externalFocusRevision
        model.shell.control.onSettingQueued(.iso)
        #expect(model.focusRackObservation().externalFocusRevision == before)
        #expect(!adapter.stopPending)
        model.shell.control.onSettingQueued(.focusMode)
        #expect(model.focusRackObservation().externalFocusRevision == before + 1)
        #expect(adapter.stopPending)
    }

    @Test("Safety stays unsettled while either focus-setting queue still owns a write")
    func pendingFocusSettingBlocksFreshSafety() {
        let model = NativeAppModel()
        #expect(model.focusRackObservation().externalFocusIdle)
        model.shell.control.bind(NikonPictureLifetimeSession())
        model.shell.control.set(.focusMode(.single), label: "AF-S")
        #expect(!model.focusRackObservation().externalFocusIdle)
        model.shell.control.unbind()
        #expect(model.focusRackObservation().externalFocusIdle)
        model.debugEnqueueCameraWrite(.movieFocusMode, picker: .focus)
        #expect(!model.focusRackObservation().externalFocusIdle)
    }

    @Test("Queued frame delivery ages while it waits instead of becoming newly fresh")
    func queuedFrameAgeIsPreserved() {
        let observation = FocusRackObservation(
            sessionID: "SIMULATED", connected: true, foregroundOwner: true, recording: false,
            frameSequence: 1, focus: nil, frameAgeSeconds: 0.2)
        let delivery = FocusRackObservationDelivery(observation: observation, receivedAt: 10)
        #expect(abs(delivery.aged(at: 12).frameAgeSeconds - 2.2) < 0.000001)
    }

    @Test("A retake raster cannot attach to the prior capture of the same live frame")
    func pendingRasterRequiresNewAcceptedRevision() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { _ in }
        var candidate = FocusRackPendingCapture(
            markID: "A", sessionID: "SIMULATED", frameSequence: 4, baselineRevision: 1,
            image: image)
        #expect(
            !candidate.matches(
                .init(markID: "A", revision: 1, sessionID: "SIMULATED", frameSequence: 4)))
        #expect(
            candidate.matches(
                .init(markID: "A", revision: 2, sessionID: "SIMULATED", frameSequence: 4)))
        #expect(
            !candidate.matches(
                .init(markID: "A", revision: 2, sessionID: "OTHER", frameSequence: 4)))
        candidate.acceptedRevision = 3
        #expect(
            !candidate.matches(
                .init(markID: "A", revision: 2, sessionID: "SIMULATED", frameSequence: 4)))
        #expect(
            candidate.matches(
                .init(markID: "A", revision: 3, sessionID: "SIMULATED", frameSequence: 4)))
    }

    @Test("The record-stop receipt hook immediately stops the root-owned rack")
    func recordingStopIntentAcknowledgesImmediately() {
        let model = NativeAppModel()
        var state = FocusRackState.initial
        state.busy = true
        state.phase = .moving
        let adapter = FocusRackModel(fixture: state)
        model.focusRack = adapter
        model.shell.control.onRecordingStopRequested()
        #expect(adapter.stopPending)
        #expect(adapter.state?.phase == .moving)
    }

    @Test("Losing active scene ownership acknowledges cancellation before the next observation")
    func inactiveSceneStopsImmediately() {
        let model = NativeAppModel()
        var state = FocusRackState.initial
        state.phase = .moving
        state.busy = true
        state.stepPosition = 8
        let adapter = FocusRackModel(fixture: state)
        model.focusRack = adapter
        model.enterInactive()
        #expect(adapter.stopPending)
        #expect(adapter.state?.stepPosition == 8)
        #expect(adapter.state?.phase == .moving)
    }

    @Test("The shared display owner cancels movement before command or editor takeover")
    func sharedDisplayTakeoverStopsImmediately() {
        for editing in [false, true] {
            let model = NativeAppModel()
            var state = FocusRackState.initial
            state.phase = .moving
            state.busy = true
            let adapter = FocusRackModel(fixture: state)
            model.focusRack = adapter
            model.operatorSession.declare(modes: [.live, .clean, .command])
            #expect(!adapter.stopPending)
            if editing {
                model.operatorSession.beginEditing(.live)
            } else {
                model.operatorSession.select(.command)
            }
            #expect(adapter.stopPending)
        }
    }

    @Test("Stop acknowledges immediately without inventing a confirmed position")
    func stopFeedbackIsImmediate() {
        var state = FocusRackState.initial
        state.phase = .moving
        state.busy = true
        state.stepPosition = 8
        let adapter = FocusRackModel(fixture: state)
        adapter.stop()
        #expect(adapter.stopPending)
        #expect(adapter.state?.stepPosition == 8)
        #expect(adapter.state?.phase == .moving)
    }

    @Test("Invalid numeric entry stays local and does not change shared timing")
    func invalidTimingEntry() {
        let adapter = FocusRackModel(fixture: .initial)
        adapter.setTimingText("invalid", isDelay: false)
        #expect(adapter.notice == "Enter a number of seconds.")
        #expect(adapter.state?.transition.duration == 3)
    }

    @Test("A held image without its actual camera source cannot become a mark thumbnail")
    func heldDemoRasterIsNotAcceptedFrame() {
        let model = NativeAppModel()
        model.liveFrameImage = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            _ in
        }
        #expect(model.focusRackFrame() == nil)
    }

    @Test("The UI adapter keeps only validated timing values in its simulated template list")
    func savingTimingUsesSharedCodec() {
        var state = FocusRackState.initial
        state.capabilities.canEditTiming = true
        state.transition = .init(duration: 16, delay: 2, easing: .linear)
        let adapter = FocusRackModel(fixture: state)
        adapter.saveTemplate(named: "Custom reveal")
        #expect(
            adapter.templates.last == .init(name: "Custom reveal", transition: state.transition))
        let saved = adapter.templates
        adapter.saveTemplate(named: "")
        #expect(adapter.templates == saved)
        #expect(adapter.notice != nil)
    }
}
