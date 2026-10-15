import Foundation
import OpenCineAppUITesting
import OpenCineCore

/// The bundle's principal class (`NSPrincipalClass`): declares what OpenZCine's review body can
/// do before any test runs. Z does not project `MonitorLayoutCapabilities` yet, so the value is declared
/// from what its demo body renders: card delete and rating, timecode and audio meters, no gimbal.
final class ConformanceApp: NSObject {
    override init() {
        super.init()
        ConformanceProfile.current = ConformanceProfile(
            app: "OpenZCine",
            capabilities: MonitorLayoutCapabilities(
                audio: true, clipDelete: true, clipStar: true, timecode: true))
    }
}
