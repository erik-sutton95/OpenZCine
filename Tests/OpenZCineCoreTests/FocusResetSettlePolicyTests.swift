import OpenZCineCore
import Testing

@Test func subjectTrackingLatchedWhenTrackingAFStatusActive() {
    let focus = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: false,
        trackingAFActive: true,
        selectedBoxIndex: nil,
        boxes: [
            PTPLiveViewAFBox(centerX: 3000, centerY: 1700, width: 800, height: 800)
        ]
    )
    #expect(focus.isSubjectTrackingLatched)
}

@Test func focusResetSettleWaitsForTrackingAFStatusClear() {
    #expect(
        !FocusResetSettlePolicy.shouldRecenter(
            framesSinceRelease: 5, isTrackingLatched: false, trackingAFActive: true))
    #expect(
        FocusResetSettlePolicy.shouldRecenter(
            framesSinceRelease: 15, isTrackingLatched: false, trackingAFActive: true))
}

@Test func subjectTrackingLatchedWhenFaceBoxSelected() {
    let focus = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: true,
        selectedBoxIndex: 1,
        boxes: [
            PTPLiveViewAFBox(centerX: 3000, centerY: 1700, width: 800, height: 800),
            PTPLiveViewAFBox(centerX: 3100, centerY: 1750, width: 180, height: 180),
        ]
    )
    #expect(focus.isSubjectTrackingLatched)
}

@Test func subjectTrackingNotLatchedWithOnlyAfBox() {
    let focus = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: true,
        selectedBoxIndex: nil,
        boxes: [
            PTPLiveViewAFBox(centerX: 3000, centerY: 1700, width: 800, height: 800)
        ]
    )
    #expect(!focus.isSubjectTrackingLatched)
}

@Test func focusResetSettleWaitsForMinimumFrames() {
    #expect(!FocusResetSettlePolicy.shouldRecenter(framesSinceRelease: 2, isTrackingLatched: false))
    #expect(FocusResetSettlePolicy.shouldRecenter(framesSinceRelease: 3, isTrackingLatched: false))
}

@Test func focusResetSettleWaitsForLatchClearOrTimeout() {
    #expect(
        !FocusResetSettlePolicy.shouldRecenter(
            framesSinceRelease: 5, isTrackingLatched: true, trackingAFActive: false))
    #expect(
        FocusResetSettlePolicy.shouldRecenter(
            framesSinceRelease: 15, isTrackingLatched: true, trackingAFActive: false))
    #expect(
        !FocusResetSettlePolicy.shouldRecenter(
            framesSinceRelease: 10, isTrackingLatched: true, trackingAFActive: true))
}

@Test func focusResetReleaseDemotesWhenHeaderShowsTracking() {
    let tracking = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: false,
        trackingAFActive: true,
        selectedBoxIndex: nil,
        boxes: [
            PTPLiveViewAFBox(centerX: 3000, centerY: 1700, width: 800, height: 800)
        ]
    )
    let idle = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: false,
        selectedBoxIndex: nil,
        boxes: [
            PTPLiveViewAFBox(centerX: 3000, centerY: 1700, width: 800, height: 800)
        ]
    )
    #expect(
        FocusResetReleasePolicy.shouldDemoteSubjectArea(
            focusArea: "Single", liveViewFocus: tracking))
    #expect(
        FocusResetReleasePolicy.shouldDemoteSubjectArea(focusArea: "Subject", liveViewFocus: nil))
    #expect(
        !FocusResetReleasePolicy.shouldDemoteSubjectArea(
            focusArea: "Single", liveViewFocus: idle))
}

@Test func focusResetReleaseSuspendsWhenHeaderShowsSubjectDetection() {
    let detecting = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: true,
        selectedBoxIndex: nil,
        boxes: [
            PTPLiveViewAFBox(centerX: 3000, centerY: 1700, width: 800, height: 800)
        ]
    )
    #expect(
        !FocusResetReleasePolicy.shouldSuspendSubjectDetection(
            focusSubject: "Off", liveViewFocus: nil))
    #expect(
        FocusResetReleasePolicy.shouldSuspendSubjectDetection(
            focusSubject: "Off", liveViewFocus: detecting))
    #expect(
        FocusResetReleasePolicy.shouldSuspendSubjectDetection(
            focusSubject: "Auto", liveViewFocus: nil))
}

@Test func focusResetReleaseHeaderTrackingIndicator() {
    let tracking = PTPLiveViewFocusInfo(
        coordinateWidth: 6048,
        coordinateHeight: 3400,
        focusResult: .focused,
        subjectDetectionActive: false,
        trackingAFActive: true,
        selectedBoxIndex: nil,
        boxes: []
    )
    #expect(FocusResetReleasePolicy.isTrackingIndicatedOnHeader(tracking))
    #expect(!FocusResetReleasePolicy.isTrackingIndicatedOnHeader(nil))
}

@Test func focusResetRestoreAfterDemotionAndSuspension() {
    #expect(
        FocusResetRestorePolicy.shouldRestoreFocusArea(
            demoted: true,
            currentFocusArea: "Single",
            savedFocusArea: "Subject",
            focusMode: "AF-C"
        ))
    #expect(
        FocusResetRestorePolicy.shouldRestoreSubjectDetection(
            suspended: true,
            currentFocusSubject: "Off",
            savedFocusSubject: "People",
            focusMode: "AF-C"
        ))
}

@Test func focusResetRestoreSkipsWhenUserChangedPicker() {
    #expect(
        !FocusResetRestorePolicy.shouldRestoreFocusArea(
            demoted: true,
            currentFocusArea: "Wide-S",
            savedFocusArea: "Subject",
            focusMode: "AF-C"
        ))
    #expect(
        !FocusResetRestorePolicy.shouldRestoreSubjectDetection(
            suspended: true,
            currentFocusSubject: "Auto",
            savedFocusSubject: "People",
            focusMode: "AF-C"
        ))
}

@Test func focusResetRestoreSkipsManualFocus() {
    #expect(
        !FocusResetRestorePolicy.shouldRestoreFocusArea(
            demoted: true,
            currentFocusArea: "Single",
            savedFocusArea: "Subject",
            focusMode: "MF"
        ))
    #expect(
        !FocusResetRestorePolicy.shouldRestoreSubjectDetection(
            suspended: true,
            currentFocusSubject: "Off",
            savedFocusSubject: "People",
            focusMode: "MF"
        ))
}

@Test func focusResetRestoreSkipsWhenNothingWasDemotedOrSuspended() {
    #expect(
        !FocusResetRestorePolicy.shouldRestoreFocusArea(
            demoted: false,
            currentFocusArea: "Subject",
            savedFocusArea: "Subject",
            focusMode: "AF-C"
        ))
    #expect(
        !FocusResetRestorePolicy.shouldRestoreSubjectDetection(
            suspended: false,
            currentFocusSubject: "People",
            savedFocusSubject: "People",
            focusMode: "AF-C"
        ))
}
