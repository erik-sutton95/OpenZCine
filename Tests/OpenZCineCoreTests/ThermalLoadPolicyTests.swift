import Testing

@testable import OpenZCineCore

struct ThermalLoadPolicyTests {
    @Test func nominalAndFairAreNoOp() {
        #expect(ThermalTier.nominal.cadenceMultiplier == 1.0)
        #expect(ThermalTier.fair.cadenceMultiplier == 1.0)
        #expect(!ThermalTier.nominal.isSheddingLoad)
        #expect(!ThermalTier.fair.isSheddingLoad)
    }

    @Test func hotTiersShedMonotonically() {
        #expect(ThermalTier.serious.cadenceMultiplier > 1.0)
        #expect(ThermalTier.critical.cadenceMultiplier > ThermalTier.serious.cadenceMultiplier)
        #expect(ThermalTier.serious.isSheddingLoad)
        #expect(ThermalTier.critical.isSheddingLoad)
    }

    @Test func multiplierNeverSpeedsUpRefresh() {
        // The whole safety story rests on this: shedding can only ever slow a refresh, never speed it.
        for tier in ThermalTier.allCases {
            #expect(tier.cadenceMultiplier >= 1.0)
            #expect(tier.sheddingInterval(base: 1.0 / 24.0) >= 1.0 / 24.0)
        }
    }

    @Test func tiersOrderByHeat() {
        #expect(ThermalTier.nominal < ThermalTier.fair)
        #expect(ThermalTier.fair < ThermalTier.serious)
        #expect(ThermalTier.serious < ThermalTier.critical)
    }

    @Test func feedStaysReadableAtCritical() {
        // Encodes the floor invariant: even at critical, the feed must stay >= 10 fps and the scopes
        // (dense 1/8 s base, worst case) >= 4 Hz. Bumping a multiplier past that fails here.
        let m = ThermalTier.critical.cadenceMultiplier
        #expect(1.0 / ThermalTier.critical.sheddingInterval(base: 1.0 / 24.0) >= 10.0)
        #expect(1.0 / ThermalTier.critical.sheddingInterval(base: 1.0 / 8.0) >= 4.0)
        #expect(m >= 1.0)
    }

    @Test func liveViewLoadPolicyNeverRaisesTheRequestedSize() {
        for requested: UInt8 in 1...3 {
            for tier in ThermalTier.allCases {
                let size = LiveViewLoadPolicy.effectiveImageSize(
                    requested: requested,
                    isRecording: true,
                    thermalTier: tier,
                    cameraOverheating: false)
                #expect(size <= requested)
                #expect((1...3).contains(size))
            }
        }
    }

    @Test func liveViewLoadPolicyCapsPreviewForRecordingAndHeat() {
        #expect(
            LiveViewLoadPolicy.effectiveImageSize(
                requested: 3, isRecording: true, thermalTier: .nominal,
                cameraOverheating: false) == 2)
        #expect(
            LiveViewLoadPolicy.effectiveImageSize(
                requested: 3, isRecording: false, thermalTier: .serious,
                cameraOverheating: false) == 2)
        #expect(
            LiveViewLoadPolicy.effectiveImageSize(
                requested: 3, isRecording: false, thermalTier: .critical,
                cameraOverheating: false) == 1)
        #expect(
            LiveViewLoadPolicy.effectiveImageSize(
                requested: 3, isRecording: false, thermalTier: .nominal,
                cameraOverheating: true) == 1)
    }
}
