import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct LiveAudioMeterWireTests {
    @Test func absentCameraIndicatorStaysExplicitlyUnavailable() {
        let wire = LiveAudioMeterWire(sound: nil)

        #expect(!wire.hasLevels)
        #expect(wire.leftLevelDB == AudioMeterBallistics.floorDB)
        #expect(wire.leftPeakDB == AudioMeterBallistics.floorDB)
        #expect(wire.rightLevelDB == AudioMeterBallistics.floorDB)
        #expect(wire.rightPeakDB == AudioMeterBallistics.floorDB)
    }

    @Test func cameraIndicatorUsesTheSharedCoreDBFSMapping() {
        let sound = PTPLiveViewSoundIndicator(
            peakLeft: 14,
            peakRight: 10,
            currentLeft: 8,
            currentRight: 3)
        let expected = AudioMeterLevels(cameraIndicator: sound)
        let wire = LiveAudioMeterWire(sound: sound)

        #expect(wire.hasLevels)
        #expect(wire.leftLevelDB == expected.left.levelDB)
        #expect(wire.leftPeakDB == expected.left.peakDB)
        #expect(wire.rightLevelDB == expected.right.levelDB)
        #expect(wire.rightPeakDB == expected.right.peakDB)
    }
}
