import OpenZCineCore
import Testing

@Suite("Camera-header monitor timecode")
struct MonitorTimecodeTests {
    @Test func monitorAndMulticamPreserveTheCameraFrameCounter() {
        let camera = Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 17)
        #expect(camera.monitorLabel == "01:02:03:17")
        let next = Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 18)
        #expect(next.monitorLabel == "01:02:03:18")
    }

    @Test func enabledZeroIsGenuineAndDisabledTimecodeIsUnavailable() {
        #expect(
            Timecode(on: true, hour: 0, minute: 0, second: 0, frame: 0).monitorLabel
                == "00:00:00:00")
        #expect(Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0).monitorLabel == nil)
    }

    @Test func malformedCameraTelemetryDoesNotBecomeAClock() {
        #expect(Timecode(on: true, hour: 24, minute: 0, second: 0, frame: 0).monitorLabel == nil)
        #expect(Timecode(on: true, hour: 1, minute: 2, second: 3, frame: -1).monitorLabel == nil)
    }
}
