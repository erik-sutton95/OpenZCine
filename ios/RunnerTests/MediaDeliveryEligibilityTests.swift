import Testing

@testable import Runner

@Suite("Media delivery eligibility")
struct MediaDeliveryEligibilityTests {
    @Test("Share stays available while the camera can cache an uncached clip")
    func connectedCameraUnlocksUncachedClip() {
        #expect(MediaDeliveryEligibility.canDeliver(clipIsLocal: false, cameraConnected: true))
        #expect(
            MediaDeliveryEligibility.canDeliver(localCount: 0, totalCount: 1, cameraConnected: true)
        )
    }

    @Test("A cached clip stays deliverable after disconnect")
    func cachedClipWorksOffline() {
        #expect(MediaDeliveryEligibility.canDeliver(clipIsLocal: true, cameraConnected: false))
        #expect(
            MediaDeliveryEligibility.canDeliver(
                localCount: 1, totalCount: 1, cameraConnected: false)
        )
    }

    @Test("Uncached clips are not deliverable without the camera")
    func uncachedClipNeedsCamera() {
        #expect(!MediaDeliveryEligibility.canDeliver(clipIsLocal: false, cameraConnected: false))
        #expect(
            !MediaDeliveryEligibility.canDeliver(
                localCount: 0, totalCount: 2, cameraConnected: false))
    }

    @Test("An empty selection is never deliverable")
    func emptySelectionIsNotDeliverable() {
        #expect(
            !MediaDeliveryEligibility.canDeliver(
                localCount: 0, totalCount: 0, cameraConnected: true)
        )
    }
}
