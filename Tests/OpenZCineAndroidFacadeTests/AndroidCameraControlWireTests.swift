import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct AndroidCameraControlWireTests {
    @Test func mapsEverySupportedSemanticSelectorWithoutPropertyBytes() {
        #expect(AndroidCameraControlWire.control(selector: 0) == .iso)
        #expect(AndroidCameraControlWire.control(selector: 1) == .shutter)
        #expect(AndroidCameraControlWire.control(selector: 2) == .iris)
        #expect(AndroidCameraControlWire.control(selector: 3) == .whiteBalance)
        #expect(AndroidCameraControlWire.control(selector: 4) == .focusMode)
        #expect(AndroidCameraControlWire.control(selector: 5) == .focusArea)
        #expect(AndroidCameraControlWire.control(selector: 6) == .focusSubject)
        #expect(AndroidCameraControlWire.control(selector: 7) == .exposureMode)
        #expect(AndroidCameraControlWire.control(selector: 8) == .audioSensitivity)
        #expect(AndroidCameraControlWire.control(selector: 9) == .audioInput)
        #expect(AndroidCameraControlWire.control(selector: 10) == .windFilter)
        #expect(AndroidCameraControlWire.control(selector: 11) == .attenuator)
        #expect(AndroidCameraControlWire.control(selector: 12) == .audio32BitFloat)
        #expect(AndroidCameraControlWire.control(selector: 13) == .baseISO)
        #expect(AndroidCameraControlWire.control(selector: 14) == .shutterMode)
        #expect(AndroidCameraControlWire.control(selector: 15) == .shutterLock)
        #expect(AndroidCameraControlWire.control(selector: 16) == .whiteBalanceTint)
        #expect(AndroidCameraControlWire.control(selector: 17) == .resolutionFrameRate)
        #expect(AndroidCameraControlWire.control(selector: 18) == .codec)
        #expect(AndroidCameraControlWire.control(selector: 19) == .vibrationReduction)
        #expect(AndroidCameraControlWire.control(selector: 20) == .electronicVR)
        #expect(AndroidCameraControlWire.control(selector: -1) == nil)
        #expect(AndroidCameraControlWire.control(selector: 21) == nil)
    }
}
