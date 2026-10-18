import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineCore
import Testing

@testable import Runner

/// Z reads the Nikon integration's one control model for the zoom chip and gimbal stick
/// sections instead of a brand constant; today no Z body offers either.
@Suite("Nikon control model adoption")
struct ControlCapabilityAdoptionTests {
    @MainActor
    @Test(
        "Without a connected body the static Nikon profile decides, offering no zoom chip or gimbal"
    )
    func theStaticProfileDecides() {
        let model = NativeAppModel()
        let controls = model.controlCapabilities
        #expect(controls.gimbal.support == .unsupported)
        #expect(controls.headTracking.support == .unsupported)
        #expect(controls.zoom.support == .unknown)
        #expect(controls.focus.isOffered)
        #expect(controls.codecColor.offer == nil, "before connection, values remain unknown")
        #expect(controls.displaySections.contains(.color), "known static color support")
        #expect(!model.chromeSectionMounts(.zoomChip))
        #expect(!model.chromeSectionMounts(.gimbalStick))
    }
}
