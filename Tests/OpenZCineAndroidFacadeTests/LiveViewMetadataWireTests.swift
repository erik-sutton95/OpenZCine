import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct LiveViewMetadataWireTests {
    @Test func absentMetadataRemainsExplicitlyUnavailable() {
        let focus = LiveViewFocusWire(focus: nil)
        let level = LiveViewLevelWire(level: nil)

        #expect(!focus.hasFocus)
        #expect(focus.coordinateWidth == 0)
        #expect(focus.boxes.isEmpty)
        #expect(focus.selectedBoxIndex == LiveViewFocusWire.unavailableSelectedBoxIndex)
        #expect(!level.hasLevel)
        #expect(level.rollDegrees == 0)
    }

    @Test func focusWireCarriesCameraCoordinatesWithoutHeaderPolicyInKotlin() {
        let focus = PTPLiveViewFocusInfo(
            coordinateWidth: 6_048,
            coordinateHeight: 3_400,
            focusResult: .focused,
            subjectDetectionActive: true,
            trackingAFActive: true,
            selectedBoxIndex: 1,
            boxes: [
                PTPLiveViewAFBox(centerX: 3_024, centerY: 1_700, width: 800, height: 600),
                PTPLiveViewAFBox(centerX: 2_900, centerY: 1_400, width: 180, height: 180),
            ])

        let wire = LiveViewFocusWire(focus: focus)

        #expect(wire.hasFocus)
        #expect(wire.coordinateWidth == 6_048)
        #expect(wire.coordinateHeight == 3_400)
        #expect(wire.result == 2)
        #expect(wire.subjectDetectionActive)
        #expect(wire.trackingAFActive)
        #expect(wire.selectedBoxIndex == 1)
        #expect(wire.boxes == [3_024, 1_700, 800, 600, 2_900, 1_400, 180, 180])
    }

    @Test func levelWireSendsSignedCameraAngles() {
        let wire = LiveViewLevelWire(
            level: PTPLevelAngles(roll: 359.5, pitch: 270, yaw: 180))

        #expect(wire.hasLevel)
        #expect(abs(wire.rollDegrees - -0.5) < 0.000_001)
        #expect(abs(wire.pitchDegrees - -90) < 0.000_001)
        #expect(wire.yawDegrees == 180)
    }
}
