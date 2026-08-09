import Foundation
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

    @Test("The live-view pump's own frame observations outrank the Android shell's")
    func liveViewPumpHealthOutranksShellObservations() throws {
        // A stream the shell believes is healthy: no bad frame (it never sees one — they are
        // dropped inside the pump) at the body's own 30 fps over a 20 ms link.
        func snapshot(pump: AndroidLiveViewStreamHealth?, shellFreshness: Double)
            throws -> AndroidLinkHealthSnapshot
        {
            try #require(
                AndroidLinkHealthWire.snapshot(
                    phaseRaw: AndroidCameraLinkPhaseWire.streaming.rawValue,
                    roundTripMilliseconds: 20,
                    liveViewFPS: 30,
                    targetLiveViewFPS: 30,
                    secondsSinceLastGoodFrame: shellFreshness,
                    consecutiveBadFrames: 0,
                    recentCommandFailures: 0,
                    isRecoveringStream: false,
                    isUSBTransport: false,
                    resetSignalBars: true,
                    liveViewStreamHealth: pump))
        }

        let shellOnly = try snapshot(pump: nil, shellFreshness: 0.02)
        #expect(shellOnly.score == 100)
        #expect(shellOnly.signalBars == 4)

        // Same shell report, but the pump is nine unparsable frames deep and has not decoded one
        // for two seconds: -50 bad frames, -20 freshness. Without the pump's values this body
        // degrades all the way to the stream restart while the bars still read four.
        let degrading = try snapshot(
            pump: AndroidLiveViewStreamHealth(
                lastGoodFrameAt: Date().addingTimeInterval(-2), consecutiveBadFrames: 9),
            shellFreshness: 0.02)
        #expect(degrading.score == 30)
        #expect(degrading.signalBars == 2)

        // The override runs both ways: a shell clock that reset across a stream generation must not
        // dock a link the pump is decoding from right now.
        let freshPump = try snapshot(
            pump: AndroidLiveViewStreamHealth(
                lastGoodFrameAt: Date(), consecutiveBadFrames: 0),
            shellFreshness: 4)
        #expect(freshPump.score == 100)
    }
}
