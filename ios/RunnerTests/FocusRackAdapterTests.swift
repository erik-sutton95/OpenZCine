import Foundation
import OpenZCineCore
import Testing
import UIKit

@testable import Runner

@MainActor @Suite("Focus rack native adapters")
struct FocusRackAdapterTests {
    @Test("Native AF selection preserves timing and marks without dispatching a timed intent")
    func nativeModeIsASeparatePresentation() {
        var state = FocusRackState.initial
        state.program.marks = [.init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 100)]
        state.transition = .init(duration: 6)
        let adapter = FocusRackModel(fixture: state)
        adapter.selectMode(.nativeAF)
        #expect(adapter.mode == .nativeAF)
        #expect(adapter.state?.program.marks == state.program.marks)
        #expect(adapter.state?.transition == state.transition)
        adapter.nudge(near: false, steps: 10)
        #expect(adapter.simulatedNudgeIntents.isEmpty)
        #expect(adapter.allowsAutofocus)
        state.referenceValid = false
        state.phase = .uncertain
        adapter.present(state)
        adapter.externalFocusAction()
        #expect(adapter.allowsAutofocus)
        adapter.selectMode(.timedRack)
        #expect(adapter.mode == .timedRack)
        #expect(!adapter.allowsAutofocus)
    }

    @Test("Opening setup leaves Clean display and preserves marks and timing")
    func openingSetupKeepsFocusState() {
        let model = NativeAppModel()
        var state = FocusRackState.initial
        state.program.marks = [.init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 150)]
        state.transition = .init(duration: 3, delay: 2)
        let adapter = FocusRackModel(fixture: state, model: model)
        for expanded in [true, false] {
            adapter.isExpanded = expanded
            model.setDisplayMode(.clean)
            adapter.setExpanded(true)
            #expect(model.displayMode == .live)
            #expect(adapter.isExpanded)
            #expect(adapter.state?.program == state.program)
            #expect(adapter.state?.transition == state.transition)
            #expect(adapter.simulatedNudgeIntents.isEmpty)
        }
        adapter.isExpanded = false
        model.setDisplayMode(.clean)
        model.interfaceLocked = true
        adapter.setExpanded(true)
        #expect(model.displayMode == .clean)
        #expect(!adapter.isExpanded)
        #expect(adapter.state?.program == state.program)
    }

    @Test("Active and unconfirmed timed movement retain exclusive focus ownership")
    func movementBlocksModeChanges() {
        var state = FocusRackState.initial
        state.busy = true
        let adapter = FocusRackModel(fixture: state)
        adapter.selectMode(.nativeAF)
        #expect(adapter.mode == .timedRack)
        state.busy = false
        state.phase = .stopUnconfirmed
        adapter.present(state)
        adapter.selectMode(.nativeAF)
        #expect(adapter.mode == .timedRack)
    }

    @Test("Native AF readiness uses reported movie mode, independent of stills reads")
    func nativeAFUsesMovieReadback() {
        let model = NativeAppModel()
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([1])))
        model.applyBootstrapObservation(.property(.movieFocusMode, Data([2])))
        model.openFocusRack()
        let adapter = model.focusRack
        adapter?.selectMode(.nativeAF)
        #expect(adapter?.allowsAutofocus == false)
        #expect(model.nativeAFConfigured)
        model.applyBootstrapObservation(.property(.stillFocusMode, Data([0])))
        #expect(model.nativeAFConfigured)
        model.applyBootstrapObservation(.property(.movieFocusMode, Data([0])))
        #expect(!model.nativeAFConfigured)
        model.applyBootstrapObservation(.property(.movieFocusMode, Data([2])))
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([0])))
        #expect(!model.nativeAFConfigured)
    }

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
        adapter.updateTiming(.init(durationMode: .fastest))
        adapter.setTimingText("3", isDelay: true)
        let fastest = try #require(adapter.state)
        #expect(fastest.transition.durationMode == .fastest)
        #expect(fastest.transition.duration == 20)
        #expect(fastest.transition.delay == 3)
        #expect(fastest.transition.easing == .linear)
        #expect(fastest.direction == .bToA)
        #expect(fastest.program.marks == fixture.program.marks)
        adapter.updateTiming(.init(durationMode: .timed))
        #expect(adapter.state?.transition.duration == 20)
        #expect(adapter.state?.transition.delay == 3)
    }

    @Test("Idle controls publish immediately and session retirement clears the displayed state")
    func controllerStateOwnsPresentation() {
        var busy = FocusRackState.initial
        busy.busy = true
        let adapter = FocusRackModel(fixture: busy)
        var idle = busy
        idle.busy = false
        adapter.present(idle)
        #expect(adapter.state?.busy == false)
        idle.transition.duration = 1
        idle.updateTimedActions(recording: false, ready: true)
        adapter.present(idle)
        #expect(adapter.state?.transition.duration == 1)
        #expect(adapter.state?.pullAToB?.detail == "1 s pull")
        adapter.sessionChanged()
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

    @Test("Native Set A captures the same camera coordinates as a picture tap")
    func nativeTargetUsesPictureCoordinatePath() throws {
        let (model, rack) = nativeFixture()
        let timedMarks = rack.state?.program.marks
        rack.armNativeTarget(.a)
        #expect(!rack.isExpanded)
        model.setFocusPoint(at: CGPoint(x: 250, y: 100), feedSize: CGSize(width: 1000, height: 500))
        let point = try #require(rack.nativeRack.target(for: .a))
        #expect(point.x == 0.25)
        #expect(point.y == 0.2)
        #expect(rack.isExpanded)
        #expect(rack.nativeRack.lastSelectedMark == .a)
        #expect(rack.nativeAFInstruction == "Target A selected.")
        #expect(rack.state?.program.marks == timedMarks)
        #expect(model.liveViewFocus?.boxes.first?.centerX == 250)
        #expect(model.liveViewFocus?.boxes.first?.centerY == 113)
    }

    @Test("Native delay cancellation sends no destination and leaves recording unchanged")
    func nativeDelayCancellationIsCameraFree() async throws {
        let (model, rack) = nativeFixture()
        for (mark, x) in [(NativeAFMark.a, 0.2), (.b, 0.8)] {
            rack.armNativeTarget(mark)
            #expect(rack.captureNativeTarget(try NativeAFPoint(x: x, y: 0.5)))
        }
        model.isRecording = true
        rack.setNativeDelay("0.2")
        rack.selectNativeTarget(.a, delayed: true)
        #expect(rack.nativeRack.pendingRequest?.mark == .a)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        rack.cancelNativeTarget()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rack.nativeRack.pendingRequest == nil)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        #expect(model.isRecording)
        rack.selectNativeTarget(.a, delayed: false)
        #expect(rack.nativeRack.lastSelectedMark == .a)
        #expect(model.isRecording)
        rack.selectNativeTarget(.b, delayed: true)
        model.setFocusPoint(at: .init(x: 500, y: 250), feedSize: .init(width: 1000, height: 500))
        #expect(rack.nativeRack.pendingRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rack.nativeRack.lastSelectedMark == nil)
        #expect(model.liveViewFocus?.boxes.first?.centerX == 500)
        rack.selectNativeTarget(.b, delayed: true)
        model.operatorSession.locked = true
        model.operatorSession.locked = false
        #expect(rack.nativeRack.pendingRequest == nil)
        rack.selectNativeTarget(.a, delayed: true)
        model.focusPointLocked = true
        model.focusPointLocked = false
        #expect(rack.nativeRack.pendingRequest == nil)
        rack.selectNativeTarget(.b, delayed: true)
        rack.manualAFChange(.area)
        #expect(rack.nativeRack.pendingRequest == nil)
    }

    @Test("Native readiness and actual picture tap share interface and focus lock blockers")
    func nativeLocksExplainTheRejectedTap() {
        let (model, rack) = nativeFixture()
        model.interfaceLocked = true
        #expect(!rack.allowsAutofocus)
        #expect(rack.nativeAFInstruction.contains("Unlock the interface"))
        rack.armNativeTarget(.a)
        #expect(rack.nativeRack.selectingMark == nil)
        model.interfaceLocked = false
        model.focusPointLocked = true
        #expect(!rack.allowsAutofocus)
        #expect(rack.nativeAFInstruction.contains("Unlock the focus point"))
        model.focusPointLocked = false
        #expect(rack.allowsAutofocus)
        rack.armNativeTarget(.a)
        model.focusPointLocked = true
        model.setFocusPoint(at: .init(x: 10, y: 10), feedSize: .init(width: 100, height: 100))
        #expect(rack.nativeRack.target(for: .a) == nil)
    }

    @Test("An unfocused Native AF scene remains retryable and modes retain separate marks")
    func nativeRetryAndMarksRemainIndependent() throws {
        let (model, rack) = nativeFixture()
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        #expect(rack.allowsAutofocus)
        rack.armNativeTarget(.a)
        #expect(rack.captureNativeTarget(try NativeAFPoint(x: 0.3, y: 0.5)))
        let saved = rack.nativeRack.target(for: .a)
        rack.selectMode(.timedRack)
        #expect(rack.state?.program.marks.count == 2)
        rack.selectMode(.nativeAF)
        #expect(rack.nativeRack.target(for: .a) == saved)
        rack.selectNativeTarget(.a, delayed: false)
        #expect(rack.nativeRack.lastSelectedMark == .a)
        rack.closePanel()
        #expect(rack.nativeRack.target(for: .a) == saved)
        rack.open()
        #expect(rack.nativeRack.target(for: .a) == saved)
        rack.setNativeDelay("1")
        rack.selectNativeTarget(.a, delayed: true)
        let beforeReconnect = try #require(rack.nativeRack.pendingRequest)
        rack.sessionChanged()
        #expect(rack.nativeRack.target(for: .a) == saved)
        #expect(rack.nativeRack.pendingRequest == nil)
        rack.selectNativeTarget(.a, delayed: true)
        #expect(try #require(rack.nativeRack.pendingRequest).id > beforeReconnect.id)
        rack.cancelNativeTarget()
    }

    @Test("Explicit Native selection releases only the point lock and does not select a target")
    func nativeModeReleasesThePointLock() {
        let (model, rack) = nativeFixture()
        rack.selectMode(.timedRack)
        model.focusPointLocked = true
        let revision = model.focusRackObservation().externalFocusRevision
        rack.selectMode(.nativeAF)
        #expect(!model.focusPointLocked)
        #expect(!model.interfaceLocked)
        #expect(rack.nativeRack.pendingRequest == nil)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        #expect(model.focusRackObservation().externalFocusRevision == revision)

        model.focusPointLocked = true
        rack.selectMode(.nativeAF)
        #expect(model.focusPointLocked)
        rack.unlockNativeFocusPoint()
        #expect(!model.focusPointLocked)

        rack.selectMode(.timedRack)
        model.focusPointLocked = true
        model.interfaceLocked = true
        rack.selectMode(.nativeAF)
        #expect(model.interfaceLocked && model.focusPointLocked)
    }

    @Test("Native point unlock works without AF boxes and never bypasses the interface lock")
    func nativePointUnlockNeedsNoCameraBox() {
        let (model, rack) = nativeFixture()
        model.liveViewFocus = nil
        model.focusPointLocked = true
        #expect(rack.nativeFocusPointLocked && rack.canUnlockNativeFocusPoint)
        model.interfaceLocked = true
        rack.unlockNativeFocusPoint()
        #expect(model.focusPointLocked)
        #expect(!rack.canUnlockNativeFocusPoint)
        model.interfaceLocked = false
        rack.unlockNativeFocusPoint()
        #expect(!model.focusPointLocked)
        #expect(model.liveViewFocus == nil)
        #expect(rack.nativeRack.target(for: .a) == nil)
        #expect(rack.nativeRack.target(for: .b) == nil)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
    }

    private func nativeFixture() -> (NativeAppModel, FocusRackModel) {
        let model = NativeAppModel()
        model.isDemoSession = true
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([1])))
        model.applyBootstrapObservation(.property(.movieFocusMode, Data([2])))
        var fixture = FocusRackState.initial
        fixture.program.marks = [
            .init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 100),
        ]
        let rack = FocusRackModel(fixture: fixture, model: model)
        model.focusRack = rack
        rack.selectMode(.nativeAF)
        return (model, rack)
    }
}

/// SIMULATED Nikon settings through the actual root safe point and property write/readback queue.
@MainActor @Suite("Automatic focus AF settings")
struct FocusAFSettingsAdapterTests {
    @Test("Native target dispatch rechecks fresh evidence after waiting for the safe point")
    func nativeTargetRejectsAStaleQueuedPicture() async throws {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack, result: .notFocused)
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        rack.armNativeTarget(.a)
        #expect(rack.captureNativeTarget(try NativeAFPoint(x: 0.2, y: 0.5)))
        try await Task.sleep(for: .milliseconds(650))
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands.isEmpty)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        rack.selectNativeTarget(.a, delayed: false)
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands.count == 1)
        #expect(rack.nativeRack.lastSelectedMark == .a)
    }

    @Test("A held Native response releases ownership without reclaiming a superseded target")
    func retiredNativeAcknowledgmentIsNotCurrentSelection() async throws {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack, result: .notFocused)
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        rack.armNativeTarget(.a)
        #expect(rack.captureNativeTarget(try NativeAFPoint(x: 0.2, y: 0.5)))
        await wire.holdNextTargetResponse()
        let service = Task { await model.debugServiceNativeFocusTarget() }
        for _ in 0..<1_000 {
            if await wire.targetHeld { break }
            await Task.yield()
        }
        #expect(await wire.targetHeld)
        model.operatorSession.locked = true
        await wire.releaseTargetResponse()
        #expect(await service.value)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
    }

    @Test("Native saved targets use the real safe-point slot and report command acknowledgment")
    func nativeTargetAcknowledgesSerializedCommand() async throws {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack, result: .notFocused)
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        #expect(rack.nativeAFBlocker == nil)
        rack.armNativeTarget(.a)
        model.setFocusPoint(at: .init(x: 250, y: 100), feedSize: .init(width: 1000, height: 500))
        #expect(rack.nativeRack.dispatchedRequest?.mark == .a)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        #expect(!rack.allowsAutofocus)
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands == [[250, 112]])
        #expect(rack.nativeRack.lastSelectedMark == .a)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeAFInstruction == "Target A selected.")
        #expect(model.isRecording == false)
        #expect(model.liveViewFocus?.focusResult == .notFocused)
        rack.armNativeTarget(.b)
        #expect(rack.captureNativeTarget(try NativeAFPoint(x: 0.8, y: 0.6)))
        for _ in 0..<3 { model.debugApplyNativeRecordingReadback(true) }
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands == [[250, 112], [800, 337]])
        #expect(rack.nativeRack.lastSelectedMark == .b)
        #expect(model.isRecording)
        model.debugSetNativeRecordPending(true)
        #expect(!rack.allowsAutofocus)
        rack.selectNativeTarget(.a, delayed: false)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        model.debugSetNativeRecordPending(false)
        #expect(rack.allowsAutofocus)
        rack.selectNativeTarget(.a, delayed: false)
        model.operatorSession.locked = true
        model.debugApplyNativeRecordingReadback(true)
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands.count == 2)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        #expect(rack.notice != nil)
        model.operatorSession.locked = false
        model.debugSeedFocusAF(recording: true, result: .notFocused)
        rack.selectNativeTarget(.a, delayed: false)
        rack.recordingWillStop()
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands.count == 2)
        #expect(rack.nativeRack.lastSelectedMark == nil)
        model.debugSeedFocusAF(recording: true, result: .notFocused)
        rack.selectNativeTarget(.a, delayed: false)
        model.debugApplyNativeRecordingReadback(false)
        #expect(await model.debugServiceNativeFocusTarget())
        #expect(await wire.targetCommands.count == 2)
        #expect(rack.nativeRack.dispatchedRequest == nil)
    }

    @Test(
        "Timed setup leaves continuous AF without requiring an acquired subject or known marks",
        arguments: [PTPLiveViewFocusInfo.FocusResult.unknown, .notFocused])
    func timedSetupFromUnacquiredContinuousAF(result: PTPLiveViewFocusInfo.FocusResult) async throws
    {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        var initial = FocusRackState.initial
        initial.referenceValid = false
        initial.stepPosition = nil
        rack.present(initial)
        model.debugSeedFocusAF(recording: false, result: result)
        rack.selectMode(.timedRack)
        #expect(rack.state?.referenceValid != true)
        #expect(await model.debugServiceFocusAFSettings())
        #expect(await wire.readinessPollCount == 1)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.values() == .target(.timedRack))
        #expect(await wire.writeCount == 1)
        model.debugSeedFocusAF(recording: false, result: result)
        _ = await model.debugServiceFocusAFSettings()
        #expect(!rack.afSettingsPending)
    }

    @Test(
        "Native setup may configure each AF property before the subject has been acquired",
        arguments: [PTPLiveViewFocusInfo.FocusResult.unknown, .notFocused])
    func nativeSetupFromUnacquiredSubject(result: PTPLiveViewFocusInfo.FocusResult) async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack, result: result)
        #expect(await wire.values() == .target(.nativeAF))
        #expect(await wire.writeCount == 3)
        #expect(rack.allowsAutofocus)
    }

    @Test("Unacquired setup still requires a new header and stopped recording at final admission")
    func unacquiredSetupKeepsFreshnessAndRecordingGates() async throws {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.debugSeedFocusAF(recording: false, result: .unknown)
        rack.selectMode(.timedRack)
        model.debugFenceFocusAFHeader()
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.readinessPollCount == 0)
        #expect(rack.autofocusDisabledReason == "Setting up camera AF…")
        model.debugSeedFocusAF(recording: true, result: .unknown)
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.readinessPollCount == 0)
        model.debugSeedFocusAF(recording: false, result: .unknown)
        #expect(await model.debugServiceFocusAFSettings())
        model.debugSeedFocusAF(recording: true, result: .unknown)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writeCount == 0)
        try await drain(model, rack: rack, result: .unknown)
        #expect(await wire.values() == .target(.timedRack))
        #expect(await wire.writeCount == 1)
    }

    @Test(
        "Automatic setup restores confirmed originals after recording stops and keeps manual edits")
    func setupRestoreAndManualArea() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .init(mode: "AF-F", area: "Auto", subject: "Off"))
        #expect(await wire.writeCount == 3)
        rack.manualAFChange(.area)
        await wire.set(.area, value: "Wide-L")
        model.applyBootstrapObservation(
            .property(.movieFocusMeteringMode, Data(ByteCoding.uint16LE(0x8019))))
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .target(.nativeAF))
        #expect(await wire.writeCount == 4)
        model.debugSeedFocusAF(recording: true)
        rack.closePanel()
        #expect(!rack.isActive && rack.afSettings.restoring)
        #expect(!rack.allowsAutofocus)
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.writeCount == 4)
        model.debugSeedFocusAF(recording: false)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .init(mode: "AF-S", area: "Wide-L", subject: "People"))
        #expect(!rack.afSettingsPending && rack.allowsAutofocus)
    }

    @Test(
        "Manual choices during the first setup read survive until another explicit selection",
        arguments: ["Wide-L", "Wide-S"])
    func manualChoiceBeforeLeaseCapture(area: String) async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        await wire.holdNextAFRead()
        let preparing = Task { await model.debugServiceFocusAFSettings() }
        for _ in 0..<2_000 {
            if await wire.readHeld { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await wire.readHeld)
        rack.manualAFChange(.area)
        await wire.set(.area, value: area)
        let write = try #require(FocusAFProperty.area.write(area))
        model.applyBootstrapObservation(.property(write.property, write.data))
        await wire.releaseRead()
        #expect(await preparing.value)
        try await drain(model, rack: rack, result: .notFocused)
        #expect(await wire.values() == .init(mode: "AF-F", area: area, subject: "Off"))
        #expect(await wire.writeCount == 2)
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .target(.nativeAF))
        rack.closePanel()
        try await drain(model, rack: rack)
        #expect(await wire.values() == .init(mode: "AF-S", area: area, subject: "People"))
    }

    @Test("A queued restore defers when recording starts before its first send")
    func recordStartRevokesQueuedRestore() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        // DeviceReady alone and a cached pre-tap focused frame cannot confirm AF-F completion.
        model.debugFenceFocusAFHeader()
        rack.closePanel()
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.writeCount == 3)
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.writeCount == 3)
        model.debugSeedFocusAF(recording: false)
        #expect(await model.debugServiceFocusAFSettings())
        #expect(model.debugPendingCameraWriteCount == 1)
        let before = await wire.writeCount
        model.debugSeedFocusAF(recording: true)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writeCount == before)
        #expect(rack.afSettings.restoring && rack.afSettings.pending == nil)
        model.debugSeedFocusAF(recording: false)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .init(mode: "AF-S", area: "Wide-S", subject: "People"))
    }

    @Test("A body change to another AF property revokes a queued automatic write")
    func crossPropertyBodyChangeRevokesReadiness() async throws {
        let (model, native, wire, rack) = try await fixture(
            values: .init(mode: "AF-S", area: "Wide-S", subject: "Off"))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        model.debugSeedFocusAF(recording: false)
        #expect(await model.debugServiceFocusAFSettings())
        #expect(rack.afSettings.pending?.property == .area)
        await wire.set(.mode, value: "AF-F")
        model.applyBootstrapObservation(.property(.movieFocusMode, Data([2])))
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writeCount == 0)
        #expect(rack.afSettings.pending == nil && rack.afSettingsPending)
        try await drain(model, rack: rack)
        #expect(await wire.writeCount == 1)
        rack.closePanel()
        try await drain(model, rack: rack)
        #expect(await wire.values() == .init(mode: "AF-F", area: "Wide-S", subject: "Off"))
    }

    @Test("Bounded DeviceBusy polling never authorizes a property write or silently retries")
    func readinessFailureIsVisibleAndBounded() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        await wire.setReadiness(.deviceBusy)
        rack.selectMode(.nativeAF)
        for _ in 0..<8 { #expect(await model.debugServiceFocusAFSettings()) }
        #expect(await wire.writeCount == 0)
        #expect(rack.afSettingsFailure != nil && !rack.afSettingsPending)
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(!rack.allowsAutofocus)
        await wire.setReadiness(.ok)
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        #expect(await wire.writeCount == 3)
    }

    @Test(
        "An accepted write with mismatching readback owns nothing and does not automatically retry")
    func mismatchingWriteReadbackFailsClosed() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        await wire.setIgnoreWrites(true)
        rack.selectMode(.nativeAF)
        #expect(await model.debugServiceFocusAFSettings())
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writeCount == 1)
        #expect(rack.afSettingsFailure != nil && !rack.afSettingsPending)
        #expect(!rack.allowsAutofocus)
        #expect(!(await model.debugServiceFocusAFSettings()))
        rack.closePanel()
        #expect(!rack.afSettingsPending)
        #expect(await wire.values() == .init(mode: "AF-S", area: "Wide-S", subject: "People"))
    }

    @Test(
        "Confirmed setup completes without waiting for native AF to acquire a low-contrast subject")
    func confirmedSetupKeepsNativeTargetingAvailable() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.focusPointLocked = true
        rack.selectMode(.nativeAF)
        #expect(!model.focusPointLocked)
        for _ in 0..<3 {
            model.debugSeedFocusAF(recording: false)
            #expect(await model.debugServiceFocusAFSettings())
            #expect(await model.debugServiceNextCameraWrite())
        }
        model.debugSeedFocusAF(recording: false, result: .notFocused)
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.writeCount == 3)
        #expect(!rack.afSettingsPending && rack.allowsAutofocus)
        rack.closePanel()
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.writeCount == 3 && rack.afSettings.restoring)
    }

    @Test("Already matching setup sends no writes, preserves marks, and leaves nothing to restore")
    func matchingSetupPreservesMarks() async throws {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        var state = FocusRackState.initial
        state.program.marks = [.init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 100)]
        rack.present(state)
        let revision = model.focusRackObservation().externalFocusRevision
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        #expect(await wire.writeCount == 0)
        #expect(rack.state?.program.marks == state.program.marks)
        #expect(model.focusRackObservation().externalFocusRevision == revision)
        model.debugSeedFocusAF(recording: true)
        rack.closePanel()
        #expect(!rack.afSettingsPending && rack.allowsAutofocus)
    }

    @Test("Closing with a stale idle display waits for the entered driver chunk to clean up")
    func closeWaitsForFreshCleanupAcknowledgement() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        rack.selectMode(.timedRack)
        try await drain(model, rack: rack)
        // Request a real setup change before the stale display misses an entered MF chunk.
        await wire.set(.area, value: "Wide-L")
        model.applyBootstrapObservation(
            .property(.movieFocusMeteringMode, Data(ByteCoding.uint16LE(0x8019))))
        model.debugSeedFocusAF(recording: false)
        rack.selectMode(.timedRack)
        let held = FocusAFHeldChunk()
        let access = NikonFocusRackAccess(
            isCurrent: { true }, prepareRun: { _ in true }, requestStop: { _ in },
            driveChunk: { _, _, _ in await held.drive() },
            refreshSafety: {
                try .init(
                    reported: .init(
                        focalLength: "70", focalMinX100: 7000, focalMaxX100: 7000,
                        apertureMinX100: 280, focusMode: "AF-S", focusArea: "Auto",
                        focusSubject: "Off",
                        captureSelector: .video))
            })
        let controller = FocusRackController(
            driver: access,
            clock: .init(now: { 100 }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }))
        await controller.observe(
            .init(
                sessionID: "SIMULATED-cleanup", connected: true, foregroundOwner: true,
                recording: false, frameSequence: 1,
                focus: .init(
                    trackingAFActive: false, subjectDetectionActive: false,
                    boxCount: 1, selectedBoxIndex: nil), focusResult: "focused"))
        for _ in 0..<2_000 {
            if await controller.snapshot().capabilities.canNudge { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let displayedIdle = await controller.snapshot()
        #expect(displayedIdle.capabilities.canNudge)
        try await controller.handle(.nudge(towardNear: false, steps: 1))
        for _ in 0..<2_000 {
            if await held.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await held.entered)
        rack.present(displayedIdle)
        rack.debugBindController(controller)
        await wire.holdNextAFRead()
        let preparing = Task { await model.debugServiceFocusAFSettings() }
        for _ in 0..<2_000 {
            if await wire.readHeld { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await wire.readHeld)
        rack.closePanel()
        #expect(!rack.isActive && rack.modeSwitchPending)
        #expect(!(await model.debugServiceFocusAFSettings()))
        #expect(await wire.writeCount == 4)
        await wire.releaseRead()
        #expect(await preparing.value)
        #expect(model.debugPendingCameraWriteCount == 0)
        #expect(rack.modeSwitchPending && rack.afSettings.pending == nil)
        rack.open()
        #expect(rack.isActive && rack.modeSwitchPending)
        #expect(!(await model.debugServiceFocusAFSettings()))
        await held.release()
        for _ in 0..<2_000 {
            if !rack.modeSwitchPending { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!rack.modeSwitchPending)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .target(.timedRack))
        rack.closePanel()
        for _ in 0..<2_000 {
            if !rack.modeSwitchPending { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await drain(model, rack: rack)
        #expect(await wire.values() == .init(mode: "AF-S", area: "Wide-L", subject: "People"))
        await controller.close()
    }

    @Test("Replacement sessions never inherit restoration ownership")
    func replacementAbandonsRestoration() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        rack.closePanel()
        #expect(await model.debugServiceFocusAFSettings())
        let replacementWire = FocusAFQueueTransport(values: .target(.nativeAF))
        let replacement = try await NativeCameraSession.establish(
            transport: replacementWire, host: "usb:SIMULATED-af-replacement",
            cameraName: "SIMULATED",
            requestPairing: false)
        defer { replacement.close() }
        model.debugAdoptEstablishedMediaSession(replacement)
        #expect(!rack.afSettingsPending && rack.afSettings.sessionID == nil)
        _ = await model.debugServiceNextCameraWrite()
        #expect(await replacementWire.writeCount == 0)
        #expect(await wire.writeCount == 3)
    }

    @Test("A preview restart releases a queued Native AF target and permits another selection")
    func previewRestartReleasesNativeTarget() async throws {
        let (model, native, wire, rack) = try await fixture(values: .target(.nativeAF))
        let originalBias = model.preferences.qualityBias
        defer {
            model.setQualityBias(originalBias)
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        rack.armNativeTarget(.a)
        #expect(rack.captureNativeTarget(try NativeAFPoint(x: 0.25, y: 0.2)))
        #expect(rack.nativeRack.dispatchedRequest != nil)
        model.setQualityBias(originalBias == .latency ? .balanced : .latency)
        #expect(rack.nativeRack.dispatchedRequest == nil)
        #expect(rack.notice != nil)
        #expect(await wire.targetCommands.isEmpty)
        model.debugSeedFocusAF(recording: false)
        rack.armNativeTarget(.b)
        #expect(rack.captureNativeTarget(try NativeAFPoint(x: 0.8, y: 0.6)))
        #expect(rack.nativeRack.dispatchedRequest?.mark == .b)
    }

    @Test(
        "An invalid or throwing AF pre-write read fails setup without inventing a camera control lock",
        arguments: [false, true])
    func failedAFPrewriteReadDoesNotLockFocusControl(readThrows: Bool) async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        rack.selectMode(.nativeAF)
        #expect(await model.debugServiceFocusAFSettings())
        let change = try #require(rack.afSettings.pending)
        let write = try #require(change.property.write(change.value))
        if readThrows {
            await wire.failNextRead(write.property)
        } else {
            await wire.shortNextRead(write.property)
        }
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writeCount == 0)
        #expect(rack.afSettingsFailure != nil)
        #expect(!model.lockedControls.contains(.focus))
        rack.selectMode(.nativeAF)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .target(.nativeAF))
        #expect(await wire.writeCount == 3)
    }

    @Test("Authority-expiry queue pruning defers an unsent AF change so setup can resume")
    func authorityExpiryDefersQueuedAFChange() async throws {
        let (model, native, wire, rack) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.debugEnqueueCameraWrite(.movieBaseISO)
        rack.selectMode(.nativeAF)
        #expect(await model.debugServiceFocusAFSettings())
        #expect(model.debugPendingCameraWriteCount == 2)
        #expect(rack.afSettings.pending != nil)
        rack.revokeAFWrite()
        await wire.expireNextWrite(.movieBaseISO)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(model.debugPendingCameraWriteCount == 0)
        #expect(rack.afSettings.pending == nil)
        #expect(rack.afSettingsPending)
        #expect(await wire.writeCount == 0)
        try await drain(model, rack: rack)
        #expect(await wire.values() == .target(.nativeAF))
    }

    private func drain(
        _ model: NativeAppModel, rack: FocusRackModel,
        result: PTPLiveViewFocusInfo.FocusResult = .focused
    ) async throws {
        for _ in 0..<12 {
            model.debugSeedFocusAF(recording: false, result: result)
            _ = await model.debugServiceFocusAFSettings()
            _ = await model.debugServiceNextCameraWrite()
            if !rack.afSettingsPending { break }
        }
        #expect(!rack.afSettingsPending)
        #expect(rack.afSettingsFailure == nil)
    }

    private func fixture(
        values: FocusAFSettingsValues = .init(mode: "AF-S", area: "Wide-S", subject: "People")
    ) async throws -> (NativeAppModel, NativeCameraSession, FocusAFQueueTransport, FocusRackModel) {
        let wire = FocusAFQueueTransport(values: values)
        let native = try await NativeCameraSession.establish(
            transport: wire, host: "usb:SIMULATED-af-settings", cameraName: "SIMULATED",
            requestPairing: false)
        let model = NativeAppModel()
        model.debugAdoptEstablishedMediaSession(native)
        model.connection = .connected
        model.isMonitorPresented = true
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([1])))
        for property in FocusAFProperty.allCases {
            let value = try #require(values[property])
            let write = try #require(property.write(value))
            model.applyBootstrapObservation(.property(write.property, write.data))
        }
        model.debugSeedFocusAF(recording: false)
        let rack = FocusRackModel(model: model)
        model.focusRack = rack
        return (model, native, wire, rack)
    }
}

private actor FocusAFQueueTransport: CameraTransport {
    nonisolated let kind = CameraTransportKind.usb
    private let establishment = LargeTransferTransport(operations: [
        .setDevicePropValue, .setDevicePropValueEx, .getDevicePropValue, .getDevicePropValueEx,
        .deviceReady, .changeAfArea,
    ])
    private var properties: [UInt32: Data] = [PTPPropertyCode.liveViewSelector.rawValue: Data([1])]
    private var readiness = PTPResponseCode.ok
    private var ignoreWrites = false
    private var shortRead: PTPPropertyCode?
    private var failedRead: PTPPropertyCode?
    private var expiredWrite: PTPPropertyCode?
    private var holdRead = false
    private var readCompletion: CheckedContinuation<Void, Never>?
    private var holdTarget = false
    private var targetCompletion: CheckedContinuation<Void, Never>?
    private(set) var targetHeld = false
    private(set) var readHeld = false
    private(set) var writeCount = 0
    private(set) var readinessPollCount = 0
    private(set) var targetCommands: [[UInt32]] = []
    private static let afProperties: Set<UInt32> = [
        PTPPropertyCode.movieFocusMode.rawValue, PTPPropertyCode.movieFocusMeteringMode.rawValue,
        PTPPropertyCode.movieAFSubjectDetection.rawValue,
    ]

    init(values: FocusAFSettingsValues) {
        for property in FocusAFProperty.allCases {
            if let value = values[property], let write = property.write(value) {
                properties[write.property.rawValue] = write.data
            }
        }
    }
    func set(_ property: FocusAFProperty, value: String) {
        if let write = property.write(value) { properties[write.property.rawValue] = write.data }
    }
    func setReadiness(_ value: PTPResponseCode) { readiness = value }
    func setIgnoreWrites(_ value: Bool) { ignoreWrites = value }
    func shortNextRead(_ property: PTPPropertyCode) { shortRead = property }
    func failNextRead(_ property: PTPPropertyCode) { failedRead = property }
    func expireNextWrite(_ property: PTPPropertyCode) { expiredWrite = property }
    func holdNextTargetResponse() { holdTarget = true }
    func releaseTargetResponse() {
        targetCompletion?.resume()
        targetCompletion = nil
        targetHeld = false
    }
    func holdNextAFRead() { holdRead = true }
    func releaseRead() {
        holdRead = false
        readCompletion?.resume()
        readCompletion = nil
        readHeld = false
    }
    func values() -> FocusAFSettingsValues {
        let snapshot = properties.reduce(PTPCameraPropertySnapshot()) { snapshot, entry in
            guard let property = PTPPropertyCode(rawValue: entry.key) else { return snapshot }
            return snapshot.applying(property: property, data: entry.value)
        }
        return .init(
            mode: snapshot.focusMode, area: snapshot.focusArea, subject: snapshot.focusSubject)
    }
    func executeTransaction(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        try await transact(
            operationCode, transactionID, parameters, dataPhase, dataOut, deadline, admission: nil)
    }
    func executeTransaction(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?,
        admission: NikonCommandAdmission
    ) async throws -> PTPIPTransactionResult {
        try await transact(
            operationCode, transactionID, parameters, dataPhase, dataOut, deadline,
            admission: admission)
    }
    private func transact(
        _ operation: PTPOperationCode, _ transaction: UInt32?, _ parameters: [UInt32],
        _ phase: PTPDataPhase, _ output: Data?, _ deadline: Duration?,
        admission: NikonCommandAdmission?
    ) async throws -> PTPIPTransactionResult {
        try admission?.requireCurrent()
        if operation == .getDeviceInfo {
            return try await establishment.executeTransaction(
                operationCode: operation, transactionID: transaction, parameters: parameters,
                dataPhase: phase, dataOut: output, deadline: deadline)
        }
        let property = parameters.first ?? 0
        if failedRead?.rawValue == property,
            operation == .getDevicePropValue || operation == .getDevicePropValueEx
        {
            failedRead = nil
            throw CocoaError(.fileReadUnknown)
        }
        if operation == .setDevicePropValue || operation == .setDevicePropValueEx {
            if expiredWrite?.rawValue == property {
                expiredWrite = nil
                throw NativeCameraSessionError.commandAuthorityExpired
            }
            if !ignoreWrites { properties[property] = output }
            if Self.afProperties.contains(property) { writeCount += 1 }
        }
        if holdRead, operation == .getDevicePropValue,
            property == PTPPropertyCode.movieFocusMode.rawValue
        {
            holdRead = false
            readHeld = true
            await withCheckedContinuation { readCompletion = $0 }
        }
        if operation == .deviceReady { readinessPollCount += 1 }
        if operation == .changeAfArea {
            targetCommands.append(parameters)
            if holdTarget {
                holdTarget = false
                targetHeld = true
                await withCheckedContinuation { targetCompletion = $0 }
            }
        }
        let code = operation == .deviceReady ? readiness : .ok
        let response = ByteCoding.uint16LE(code.rawValue) + ByteCoding.uint32LE(transaction ?? 1)
        var data =
            operation == .getDevicePropValue || operation == .getDevicePropValueEx
            ? properties[property] ?? Data() : Data()
        if shortRead?.rawValue == property,
            operation == .getDevicePropValue || operation == .getDevicePropValueEx
        {
            shortRead = nil
            data = Data()
        }
        return .init(operationResponse: try .init(payloadBytes: response), data: data)
    }
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    nonisolated func close() {}
}

private actor FocusAFHeldChunk {
    private(set) var entered = false
    private var completion: CheckedContinuation<NikonFocusRackDriveOutcome, Never>?
    func drive() async -> NikonFocusRackDriveOutcome {
        entered = true
        return await withCheckedContinuation { completion = $0 }
    }
    func release() {
        completion?.resume(returning: .cancelledReady)
        completion = nil
    }
}
