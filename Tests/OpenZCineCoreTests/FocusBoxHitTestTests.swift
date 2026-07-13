import Testing

@testable import OpenZCineCore

private func focusInfo(
    _ box: PTPLiveViewAFBox, space: (Int, Int) = (1000, 562)
) -> PTPLiveViewFocusInfo {
    PTPLiveViewFocusInfo(
        coordinateWidth: space.0,
        coordinateHeight: space.1,
        focusResult: .focused,
        subjectDetectionActive: false,
        selectedBoxIndex: 0,
        boxes: [box]
    )
}

@Test func hitTestFindsBoxUnderPoint() {
    // Box centred at camera (500,281) in a 1000×562 space → feed (180,101) at 360×202.
    let info = focusInfo(PTPLiveViewAFBox(centerX: 500, centerY: 281, width: 140, height: 140))
    #expect(info.boxIndex(containingX: 180, y: 101, feedWidth: 360, feedHeight: 202) == 0)
}

@Test func hitTestMissesPointOutsideBox() {
    let info = focusInfo(PTPLiveViewAFBox(centerX: 500, centerY: 281, width: 140, height: 140))
    #expect(info.boxIndex(containingX: 5, y: 5, feedWidth: 360, feedHeight: 202) == nil)
}

@Test func hitTestPaddingExtendsTouchArea() {
    let info = focusInfo(PTPLiveViewAFBox(centerX: 0, centerY: 0, width: 20, height: 20))
    // Box half-extent in feed ≈ 3.6px; (10,10) is outside without padding, inside with 20px padding.
    #expect(
        info.boxIndex(containingX: 10, y: 10, feedWidth: 360, feedHeight: 202, padding: 0) == nil)
    #expect(
        info.boxIndex(containingX: 10, y: 10, feedWidth: 360, feedHeight: 202, padding: 20) == 0)
}

@Test func hitTestReturnsNilWhenNoBoxes() {
    let info = PTPLiveViewFocusInfo(
        coordinateWidth: 1000, coordinateHeight: 562, focusResult: .unknown,
        subjectDetectionActive: false, selectedBoxIndex: nil, boxes: []
    )
    #expect(info.boxIndex(containingX: 100, y: 100, feedWidth: 360, feedHeight: 202) == nil)
}
