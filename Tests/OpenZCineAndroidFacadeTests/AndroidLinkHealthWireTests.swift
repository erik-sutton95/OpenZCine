import Testing

@testable import OpenZCineAndroidFacade

struct AndroidLinkHealthWireTests {
    @Test("Android link observations retain Swift scoring, details, and bar reset")
    func scoresAndResetsSignalBars() throws {
        let healthy = try #require(
            AndroidLinkHealthWire.snapshot(
                phaseRaw: AndroidCameraLinkPhaseWire.streaming.rawValue,
                roundTripMilliseconds: nil,
                liveViewFPS: 30,
                targetLiveViewFPS: 30,
                secondsSinceLastGoodFrame: 0.02,
                consecutiveBadFrames: 0,
                recentCommandFailures: 0,
                isRecoveringStream: false,
                isUSBTransport: false,
                resetSignalBars: true))
        #expect(healthy.score == 93)
        #expect(healthy.signalBars == 4)
        #expect(healthy.detailCaption.contains("30.0 / 30 FPS"))

        let disconnected = try #require(
            AndroidLinkHealthWire.snapshot(
                phaseRaw: AndroidCameraLinkPhaseWire.disconnected.rawValue,
                roundTripMilliseconds: nil,
                liveViewFPS: nil,
                targetLiveViewFPS: 30,
                secondsSinceLastGoodFrame: nil,
                consecutiveBadFrames: 0,
                recentCommandFailures: 0,
                isRecoveringStream: false,
                isUSBTransport: false,
                resetSignalBars: true))
        #expect(disconnected.score == 0)
        #expect(disconnected.signalBars == 0)
        #expect(disconnected.detailCaption == "Not connected")
    }

    @Test("A live USB cable has full presentation bars without replacing its health score")
    func usbPresentationOverride() throws {
        let snapshot = try #require(
            AndroidLinkHealthWire.snapshot(
                phaseRaw: AndroidCameraLinkPhaseWire.recovering.rawValue,
                roundTripMilliseconds: nil,
                liveViewFPS: 15,
                targetLiveViewFPS: 30,
                secondsSinceLastGoodFrame: 1.6,
                consecutiveBadFrames: 0,
                recentCommandFailures: 0,
                isRecoveringStream: true,
                isUSBTransport: true,
                resetSignalBars: true))
        #expect(snapshot.score > 0)
        #expect(snapshot.signalBars == 4)
        #expect(AndroidLinkHealthWire.encode(snapshot) != nil)
        #expect(
            AndroidLinkHealthWire.snapshot(
                phaseRaw: 99,
                roundTripMilliseconds: nil,
                liveViewFPS: nil,
                targetLiveViewFPS: 30,
                secondsSinceLastGoodFrame: nil,
                consecutiveBadFrames: 0,
                recentCommandFailures: 0,
                isRecoveringStream: false,
                isUSBTransport: false,
                resetSignalBars: false) == nil)
    }
}
