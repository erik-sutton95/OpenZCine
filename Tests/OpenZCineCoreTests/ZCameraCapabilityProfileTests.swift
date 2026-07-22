import OpenZCineCore
import Testing

@Suite("Z camera capability profile")
struct ZCameraCapabilityProfileTests {
    @Test func tiersFromModelNames() {
        #expect(ZCameraCapabilityProfile.tier(forModelName: "ZR") == .cinema)
        #expect(ZCameraCapabilityProfile.tier(forModelName: "Z 9") == .extended)
        #expect(ZCameraCapabilityProfile.tier(forModelName: "Z 50") == .legacy)
        #expect(ZCameraCapabilityProfile.tier(forModelName: "Z 6II") == .gen2)
    }

    @Test func allTiersSupportLiveViewSelector() {
        for tier in ZCameraCapabilityTier.allCases {
            #expect(ZCameraCapabilityProfile.supportsLiveViewSelector(tier: tier))
        }
    }
}
