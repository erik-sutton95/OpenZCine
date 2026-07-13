import Testing

@testable import OpenZCineCore

@Suite("Camera link health scoring") struct CameraLinkHealthTests {
    @Test func disconnected() {
        let s = CameraLinkHealthScorer.score(.init(phase: .disconnected))
        #expect(s.linkHealthScore == 0)
    }
    @Test func healthyStreaming() {
        let s = CameraLinkHealthScorer.score(
            .init(
                phase: .streaming, ptpRoundTripMilliseconds: 45,
                liveViewFPS: 29.5, targetLiveViewFPS: 30, secondsSinceLastGoodFrame: 0.03))
        #expect(s.linkHealthScore >= 80)
    }
}
