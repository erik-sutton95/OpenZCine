import Foundation
import OpenZCineCore
import Testing

struct NativeAFRackTests {
    private let near: NativeAFPoint
    private let far: NativeAFPoint

    init() throws {
        near = try NativeAFPoint(x: 0.2, y: 0.7)
        far = try NativeAFPoint(x: 0.8, y: 0.3)
    }

    @Test func pointValidationAlsoAppliesToDecodedTargets() throws {
        #expect(throws: NativeAFRackError.invalidPoint) { try NativeAFPoint(x: -0.01, y: 0) }
        #expect(throws: NativeAFRackError.invalidPoint) { try NativeAFPoint(x: 1, y: 1.01) }
        #expect(throws: NativeAFRackError.invalidPoint) { try NativeAFPoint(x: .nan, y: 0.5) }
        #expect(throws: NativeAFRackError.invalidPoint) { try NativeAFPoint(x: 0, y: .infinity) }
        #expect(try NativeAFPoint(x: 0, y: 1).x == 0)
        #expect(
            try JSONDecoder().decode(NativeAFPoint.self, from: JSONEncoder().encode(near)) == near)
        let invalid = Data(#"{"x":2,"y":0.5}"#.utf8)
        #expect(throws: NativeAFRackError.invalidPoint) {
            try JSONDecoder().decode(NativeAFPoint.self, from: invalid)
        }
    }

    @Test func captureRequiresArmingAndSelectsTheSavedPointImmediately() throws {
        var rack = NativeAFRack()
        try rack.setStartDelay(5)
        #expect(throws: NativeAFRackError.selectionNotArmed) { try rack.capture(near, now: 10) }
        try rack.arm(.a)
        let request = try rack.capture(near, now: 10)
        #expect(rack.selectingMark == nil)
        #expect(rack.target(for: .a) == near)
        #expect(rack.target(for: .b) == nil)
        #expect(request.mark == .a)
        #expect(request.point == near)
        #expect(request.dueAt == 10)
        #expect(rack.dueRequest(at: 10) == request)
        #expect(rack.lastSelectedMark == nil)
    }

    @Test func delayedDirectionOnlySelectsDestinationAndGoIgnoresDelay() throws {
        var rack = try savedRack()
        try rack.setStartDelay(3)
        let delayed = try rack.request(.b, now: 20, delayed: true)
        #expect(delayed.point == far)
        #expect(delayed.dueAt == 23)
        #expect(rack.remainingDelay(at: 21.25) == 1.75)
        #expect(rack.dueRequest(at: 22.999) == nil)
        #expect(rack.dueRequest(at: 23) == delayed)
        #expect(throws: NativeAFRackError.requestNotDue) {
            try rack.beginDispatch(id: delayed.id, at: 22)
        }
        let go = try rack.request(.a, now: 21, delayed: false)
        #expect(go.point == near)
        #expect(go.dueAt == 21)
        #expect(go.id != delayed.id)
        #expect(throws: NativeAFRackError.requestNotPending) {
            try rack.beginDispatch(id: delayed.id, at: 23)
        }
    }

    @Test func dispatchIsExclusiveAndAcknowledgmentDoesNotMeanOpticalArrival() throws {
        var rack = try savedRack()
        let request = try rack.request(.b, now: 20, delayed: false)
        let dispatched = try rack.beginDispatch(id: request.id, at: 20)
        #expect(dispatched == request)
        #expect(rack.pendingRequest == nil)
        #expect(rack.dispatchedRequest == request)
        #expect(throws: NativeAFRackError.commandInFlight) { try rack.arm(.a) }
        #expect(throws: NativeAFRackError.commandInFlight) {
            try rack.request(.a, now: 21, delayed: false)
        }
        #expect(throws: NativeAFRackError.commandInFlight) { try rack.reset() }
        let staleCompleted = rack.complete(id: request.id + 1)
        #expect(!staleCompleted)
        #expect(rack.lastSelectedMark == nil)
        let completed = rack.complete(id: request.id)
        #expect(completed)
        #expect(rack.lastSelectedMark == .b)
        #expect(rack.dispatchedRequest == nil)
        let repeatedCompleted = rack.complete(id: request.id)
        #expect(!repeatedCompleted)
        // A retry is available immediately: no sharpness or previous optical-arrival input exists.
        let retry = try rack.request(.b, now: 21, delayed: false)
        #expect(retry.point == far)
    }

    @Test func interruptionCancelsUnsentWorkAndRetainsTargets() throws {
        var rack = try savedRack()
        try rack.setStartDelay(5)
        let delayed = try rack.request(.a, now: 10, delayed: true)
        rack.cancel()
        #expect(rack.dueRequest(at: 20) == nil)
        #expect(rack.target(for: .a) == near)
        #expect(rack.target(for: .b) == far)
        #expect(throws: NativeAFRackError.requestNotPending) {
            try rack.beginDispatch(id: delayed.id, at: 20)
        }
        try rack.arm(.b)
        rack.cancel()
        #expect(rack.selectingMark == nil)
        #expect(rack.target(for: .b) == far)
    }

    @Test func cancellationNeverReleasesDispatchedCommandOwnership() throws {
        var rack = try savedRack()
        let request = try rack.request(.a, now: 10, delayed: false)
        try rack.beginDispatch(id: request.id, at: 10)
        rack.cancel()
        #expect(rack.dispatchedRequest == request)
        #expect(throws: NativeAFRackError.commandInFlight) {
            try rack.request(.b, now: 11, delayed: false)
        }
        let failed = rack.fail(id: request.id)
        #expect(failed)
        #expect(rack.lastSelectedMark == nil)
        let retry = try rack.request(.a, now: 12, delayed: false)
        try rack.beginDispatch(id: retry.id, at: 12)
        let staleFailed = rack.fail(id: request.id)
        let staleCompleted = rack.complete(id: request.id)
        #expect(!staleFailed)
        #expect(!staleCompleted)
        #expect(rack.dispatchedRequest == retry)
    }

    @Test func armingAndRecaptureReplaceOnlyUnsentIntent() throws {
        var rack = try savedRack()
        _ = try rack.request(.b, now: 10, delayed: false)
        try rack.arm(.a)
        #expect(rack.pendingRequest == nil)
        let replacement = try NativeAFPoint(x: 0.4, y: 0.4)
        let request = try rack.capture(replacement, now: 11)
        #expect(rack.target(for: .a) == replacement)
        #expect(rack.target(for: .b) == far)
        #expect(request.point == replacement)
    }

    @Test func newIntentOrInterruptionClearsAnOldAcknowledgment() throws {
        var rack = try savedRack()
        let first = try rack.request(.a, now: 10, delayed: false)
        try rack.beginDispatch(id: first.id, at: 10)
        rack.complete(id: first.id)
        #expect(rack.lastSelectedMark == .a)
        try rack.arm(.b)
        #expect(rack.lastSelectedMark == nil)
        let second = try rack.capture(far, now: 11)
        try rack.beginDispatch(id: second.id, at: 11)
        rack.complete(id: second.id)
        #expect(rack.lastSelectedMark == .b)
        let third = try rack.request(.a, now: 12, delayed: false)
        #expect(rack.lastSelectedMark == nil)
        try rack.beginDispatch(id: third.id, at: 12)
        rack.fail(id: third.id)
        #expect(rack.lastSelectedMark == nil)
        let fourth = try rack.request(.b, now: 13, delayed: false)
        try rack.beginDispatch(id: fourth.id, at: 13)
        rack.complete(id: fourth.id)
        rack.cancel()
        #expect(rack.lastSelectedMark == nil)
        #expect(rack.target(for: .a) == near)
        #expect(rack.target(for: .b) == far)
    }

    @Test func invalidInputsPreserveExistingRequestAndTargets() throws {
        var rack = try savedRack()
        try rack.setStartDelay(2)
        let request = try rack.request(.a, now: 10, delayed: true)
        #expect(throws: NativeAFRackError.invalidDelay) { try rack.setStartDelay(-1) }
        #expect(throws: NativeAFRackError.invalidDelay) { try rack.setStartDelay(.infinity) }
        #expect(throws: NativeAFRackError.invalidDelay) { try rack.setStartDelay(.nan) }
        #expect(throws: NativeAFRackError.invalidTime) {
            try rack.request(.b, now: .nan, delayed: true)
        }
        #expect(rack.pendingRequest == request)
        #expect(rack.startDelay == 2)
        #expect(rack.dueRequest(at: .infinity) == nil)
        try rack.setStartDelay(4)
        #expect(rack.pendingRequest?.dueAt == 12)
        try rack.reset()
        #expect(rack.pendingRequest == nil)
        #expect(rack.target(for: .a) == nil)
        #expect(rack.target(for: .b) == nil)
        #expect(throws: NativeAFRackError.missingTarget(.a)) {
            try rack.request(.a, now: 20, delayed: false)
        }
        #expect(rack.startDelay == 4)
    }

    @Test func admissionUsesOneReasonAndNeverNeedsAnOpticalArrivalState() {
        #expect(admission().allowed)
        #expect(admission().disabledReason == nil)
        let blocked = [
            admission(connected: false), admission(foreground: false),
            admission(interfaceLocked: true), admission(focusPointLocked: true),
            admission(liveViewFresh: false), admission(commandIdle: false),
            admission(settingsPending: true), admission(settingsFailure: "AF setup failed."),
            admission(configured: false), admission(movieMode: false),
        ]
        for state in blocked {
            #expect(!state.allowed)
            #expect(state.disabledReason?.isEmpty == false)
        }
        #expect(admission(settingsFailure: "AF setup failed.").disabledReason == "AF setup failed.")
        #expect(
            admission(interfaceLocked: true, commandIdle: false).disabledReason
                == admission(interfaceLocked: true).disabledReason)
        #expect(
            admission(commandIdle: false, settingsPending: true).disabledReason
                == admission(settingsPending: true).disabledReason)
    }

    private func admission(
        connected: Bool = true, foreground: Bool = true, interfaceLocked: Bool = false,
        focusPointLocked: Bool = false, liveViewFresh: Bool = true, commandIdle: Bool = true,
        settingsPending: Bool = false, settingsFailure: String? = nil, configured: Bool = true,
        movieMode: Bool = true
    ) -> NativeAFAdmission {
        NativeAFAdmission(
            connected: connected, foreground: foreground, interfaceLocked: interfaceLocked,
            focusPointLocked: focusPointLocked, liveViewFresh: liveViewFresh,
            commandIdle: commandIdle,
            settingsPending: settingsPending, settingsFailure: settingsFailure,
            configured: configured, movieMode: movieMode)
    }

    private func savedRack() throws -> NativeAFRack {
        var rack = NativeAFRack()
        try rack.arm(.a)
        try rack.capture(near, now: 0)
        try rack.arm(.b)
        try rack.capture(far, now: 1)
        rack.cancel()
        return rack
    }
}
