import Testing

@testable import OpenZCineCore

private let originalAF = FocusAFSettingsValues(mode: "AF-C", area: "Wide-L", subject: "People")

private func afObservation(
    _ values: FocusAFSettingsValues, recording: Bool? = false, pending: Bool = false,
    focusIdle: Bool = true, restorationFocusSettled: Bool = true,
    commandsIdle: Bool = true, movie: Bool = true,
    foreground: Bool = true, session: String = "camera:1"
) -> FocusAFSettingsObservation {
    .init(
        sessionID: session, values: values, recording: recording, recordingPending: pending,
        movie: movie, foreground: foreground, focusIdle: focusIdle,
        restorationFocusSettled: restorationFocusSettled, commandsIdle: commandsIdle,
        rack: nil)
}

@Test func unacquiredSubjectPermitsSetupButCannotAuthorizeRestoration() throws {
    var lease = FocusAFSettingsLease()
    let original = FocusAFSettingsValues.target(.nativeAF)
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: original)
    var observation = afObservation(original, restorationFocusSettled: false)
    var rack = FocusRackState.initial
    rack.stepPosition = nil
    rack.referenceValid = false
    observation.rack = rack
    let pending = lease.nextChange(observation)
    let change = try #require(pending)
    #expect(change.property == .mode && change.value == "AF-S" && !change.restoring)
    #expect(lease.allows(change, observation: observation))
    observation.values = .target(.timedRack)
    lease.confirm(change, sessionID: "camera:1", values: observation.values)
    _ = lease.nextChange(observation)
    lease.requestRestore()
    #expect(lease.nextChange(observation) == nil)
    #expect(lease.restoring)
    observation.restorationFocusSettled = true
    let restorePending = lease.nextChange(observation)
    let restore = try #require(restorePending)
    #expect(restore.restoring && lease.allows(restore, observation: observation))
    observation.restorationFocusSettled = false
    #expect(!lease.allows(restore, observation: observation))
}

private func afValues(_ values: FocusAFSettingsValues, applying change: FocusAFSettingChange)
    -> FocusAFSettingsValues
{
    var updated = values
    switch change.property {
    case .mode: updated.mode = change.value
    case .area: updated.area = change.value
    case .subject: updated.subject = change.value
    }
    return updated
}

private func completeAFSetup(
    _ lease: inout FocusAFSettingsLease, values: FocusAFSettingsValues
) -> FocusAFSettingsValues {
    var current = values
    while let change = lease.nextChange(afObservation(current)) {
        current = afValues(current, applying: change)
        lease.confirm(change, sessionID: "camera:1", values: current)
    }
    return current
}

@Test func nativeAFSetupUsesConfirmedEffectsAndRestoresOriginalsWithModeLast() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let firstPending = lease.nextChange(afObservation(originalAF))
    let first = try #require(firstPending)
    #expect(first.property == .subject && first.value == "Off")
    #expect(lease.nextChange(afObservation(originalAF)) == nil)
    #expect(lease.allows(first, observation: afObservation(originalAF)))
    let afterFirst = afValues(originalAF, applying: first)
    lease.confirm(first, sessionID: "camera:1", values: afterFirst)
    let native = completeAFSetup(&lease, values: afterFirst)
    #expect(native == .target(.nativeAF))
    #expect(!lease.needsService)
    lease.requestRestore()
    var current = native
    var properties: [FocusAFProperty] = []
    while let change = lease.nextChange(afObservation(current)) {
        #expect(change.restoring)
        properties.append(change.property)
        current = afValues(current, applying: change)
        lease.confirm(change, sessionID: "camera:1", values: current)
    }
    #expect(properties == [.subject, .area, .mode])
    #expect(current == originalAF && !lease.needsService)
}

@Test func automaticAFWritesRequireConfirmedStoppedRecordingAndIdleFocus() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: originalAF)
    for observation in [
        afObservation(originalAF, recording: nil), afObservation(originalAF, recording: true),
        afObservation(originalAF, pending: true), afObservation(originalAF, focusIdle: false),
        afObservation(originalAF, commandsIdle: false), afObservation(originalAF, movie: false),
        afObservation(originalAF, foreground: false),
    ] {
        #expect(lease.nextChange(observation) == nil)
        #expect(lease.needsService)
    }
    let firstPending = lease.nextChange(afObservation(originalAF))
    let first = try #require(firstPending)
    #expect(first.property == .mode && first.value == "AF-S")
    #expect(!lease.allows(first, observation: afObservation(originalAF, recording: true)))
}

@Test func restoringSingleAutofocusStopsContinuousAFBeforeRestoringSubjectDetection() throws {
    var lease = FocusAFSettingsLease()
    let original = FocusAFSettingsValues(mode: "AF-S", area: "Wide-L", subject: "People")
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: original)
    let native = completeAFSetup(&lease, values: original)
    lease.requestRestore()
    let pending = lease.nextChange(afObservation(native))
    let first = try #require(pending)
    #expect(first.property == .mode && first.value == "AF-S")
}

@Test func deferredAFRestorationSurvivesRecordingUntilTheCameraIsQuiescent() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let native = completeAFSetup(&lease, values: originalAF)
    lease.requestRestore()
    #expect(lease.nextChange(afObservation(native, recording: true)) == nil)
    #expect(lease.nextChange(afObservation(native, recording: nil)) == nil)
    #expect(lease.nextChange(afObservation(native, focusIdle: false)) == nil)
    #expect(lease.restoring && lease.needsService)
    #expect(completeAFSetup(&lease, values: native) == originalAF)
}

@Test func manualAFIntentPreservesSameValueAndObservedAwayAndBackChanges() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let native = completeAFSetup(&lease, values: originalAF)
    lease.manualChange(.mode)
    lease.observe(.init(mode: native.mode, area: "Single", subject: native.subject))
    lease.observe(native)
    lease.requestRestore()
    let restored = completeAFSetup(&lease, values: native)
    #expect(restored.mode == "AF-F")
    #expect(restored.area == "Auto")
    #expect(restored.subject == "People")
}

@Test func manualAFChangeRevokesAQueuedAdmissionAndCannotClaimOwnership() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: originalAF)
    let changePending = lease.nextChange(afObservation(originalAF))
    let change = try #require(changePending)
    lease.manualChange(change.property)
    #expect(!lease.allows(change, observation: afObservation(originalAF)))
    let current = afValues(originalAF, applying: change)
    lease.confirm(change, sessionID: "camera:1", values: current)
    lease.requestRestore()
    #expect(lease.nextChange(afObservation(current)) == nil)
    #expect(!lease.needsService)
}

@Test func explicitAFModeSelectionCanReownLatestManualValues() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let native = completeAFSetup(&lease, values: originalAF)
    var manual = native
    manual.area = "Wide-S"
    lease.observe(manual)
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: manual)
    let timed = completeAFSetup(&lease, values: manual)
    lease.requestRestore()
    let restored = completeAFSetup(&lease, values: timed)
    #expect(restored.mode == originalAF.mode)
    #expect(restored.area == "Wide-S")
    #expect(restored.subject == originalAF.subject)
}

@Test func afModeSwitchPreservesOriginalsAndMatchingSettingsNeedNoWrites() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let native = completeAFSetup(&lease, values: originalAF)
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: native)
    let timed = completeAFSetup(&lease, values: native)
    lease.requestRestore()
    #expect(completeAFSetup(&lease, values: timed) == originalAF)
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: .target(.timedRack))
    #expect(lease.nextChange(afObservation(.target(.timedRack))) == nil)
    lease.requestRestore()
    #expect(lease.nextChange(afObservation(.target(.timedRack))) == nil)
}

@Test func unknownOrUnsupportedAFOriginalsCannotBeOverwritten() {
    for values in [
        FocusAFSettingsValues(mode: nil, area: "Auto", subject: "Off"),
        FocusAFSettingsValues(mode: "AF-S", area: "0xFFFF", subject: "Off"),
    ] {
        var lease = FocusAFSettingsLease()
        #expect(throws: FocusAFSettingsError.self) {
            try lease.requestMode(.nativeAF, sessionID: "camera:1", values: values)
        }
        #expect(!lease.needsService)
    }
}

@Test func afReconnectDiscardsOldLeaseAndStaleCompletions() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: originalAF)
    let changePending = lease.nextChange(afObservation(originalAF))
    let change = try #require(changePending)
    #expect(lease.nextChange(afObservation(originalAF, session: "camera:2")) == nil)
    lease.confirm(change, sessionID: "camera:1", values: afValues(originalAF, applying: change))
    #expect(!lease.needsService && lease.sessionID == nil)
}

@Test func failedAFReadbackOwnsNoUnconfirmedChangeAndDoesNotRetry() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let firstPending = lease.nextChange(afObservation(originalAF))
    let first = try #require(firstPending)
    let partial = afValues(originalAF, applying: first)
    lease.confirm(first, sessionID: "camera:1", values: partial)
    let secondPending = lease.nextChange(afObservation(partial))
    let second = try #require(secondPending)
    lease.confirm(second, sessionID: "camera:1", values: partial)
    #expect(lease.failure != nil && !lease.needsService)
    #expect(lease.nextChange(afObservation(partial)) == nil)
    lease.requestRestore()
    let restorePending = lease.nextChange(afObservation(partial))
    let restore = try #require(restorePending)
    #expect(restore.property == .subject && restore.value == "People")
}

@Test func closingRevokesUnsentSetupButRetainsOwnershipOfAnAlreadySentWrite() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let setupPending = lease.nextChange(afObservation(originalAF))
    let setup = try #require(setupPending)
    lease.requestRestore()
    #expect(!lease.allows(setup, observation: afObservation(originalAF)))
    let applied = afValues(originalAF, applying: setup)
    lease.confirm(setup, sessionID: "camera:1", values: applied)
    let restorePending = lease.nextChange(afObservation(applied))
    let restore = try #require(restorePending)
    #expect(restore.property == setup.property && restore.value == originalAF[setup.property])
}

@Test func unsentAFAdmissionCanDeferWithoutLosingPendingRestoration() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    let native = completeAFSetup(&lease, values: originalAF)
    lease.requestRestore()
    let restorePending = lease.nextChange(afObservation(native))
    let restore = try #require(restorePending)
    lease.deferChange(restore)
    #expect(lease.needsService && lease.restoring && lease.pending == nil)
    #expect(lease.nextChange(afObservation(native, recording: true)) == nil)
    let retryPending = lease.nextChange(afObservation(native))
    let retry = try #require(retryPending)
    #expect(retry.id != restore.id && retry.property == restore.property)
    lease.fail(restore, message: "Retired old receipt")
    #expect(lease.pending == retry && lease.failure == nil)
}

@Test func closingWithoutOwnedAFWritesDoesNotBlockFocusDuringRecording() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.timedRack, sessionID: "camera:1", values: .target(.timedRack))
    #expect(lease.nextChange(afObservation(.target(.timedRack), recording: true)) == nil)
    lease.requestRestore()
    #expect(!lease.needsService)
}

@Test func manualChangesWhileSetupIsDeferredAreNotOverwritten() throws {
    var lease = FocusAFSettingsLease()
    try lease.requestMode(.nativeAF, sessionID: "camera:1", values: originalAF)
    var manual = originalAF
    manual.area = "Single"
    #expect(lease.nextChange(afObservation(manual, recording: true)) == nil)
    let configured = completeAFSetup(&lease, values: manual)
    #expect(configured.area == "Single")
    lease.requestRestore()
    #expect(completeAFSetup(&lease, values: configured).area == "Single")
}
