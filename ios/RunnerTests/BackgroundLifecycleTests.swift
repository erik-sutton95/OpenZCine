import Foundation
import OpenCineCore
import Testing

@testable import OpenZCineCore
@testable import Runner

/// F-ZIB-081: backgrounding releases the live-view reader, the command-channel keepalive and the
/// pushed-event drain. The baseline cancelled all three; the shared runtime kept the last two.
@MainActor
@Suite("Background lifecycle")
struct BackgroundLifecycleTests {
    @Test("Backgrounding retires the monitor's keepalive and event pumps")
    func backgroundRetiresMonitorPumps() {
        let model = NativeAppModel()
        let link = SimulatedMonitorLink()
        let runtime = NikonMonitorRuntime(link: link)
        model.debugAttachMonitorRuntime(runtime)
        defer { model.debugAttachMonitorRuntime(nil) }

        runtime.startKeepAlive(isBusy: { false }, failures: { _ in }, recover: {})
        runtime.startEventDrain(receive: { _ in }, unexpectedEnd: {})
        #expect(runtime.hasBackgroundPumps, "the foreground link owns both pumps")

        model.enterBackground()
        #expect(!runtime.hasBackgroundPumps, "backgrounding must leave no keepalive or event reader")
    }
}

/// A link whose pushed-event read parks until the runtime cancels it, so the drain is observably
/// alive before backgrounding and retired after.
@MainActor
private final class SimulatedMonitorLink: NikonMonitorLink {
    let serialNumber = "SIMULATED"

    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws {}
    func stopLiveView() async {}
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        throw NativeCameraSessionError.connectionClosed
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {}
    func nextEvent() async throws -> PTPEvent {
        try await Task.sleep(for: .seconds(3_600))
        throw NativeCameraSessionError.connectionClosed
    }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness { .complete }
    func shutdown() async {}
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {}
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data { Data() }
    func startRecording() async throws {}
    func stopRecording() async throws {}
}
