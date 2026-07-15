import Testing

@testable import OpenZCineAndroidFacade

struct AndroidLiveViewPolicyWireTests {
    @Test("Android wire resolves shared stream choices and thermal cadence")
    func resolvesPreviewOnlyPolicy() throws {
        let nominal = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 0,
                qualityBiasRaw: 0,
                thermalTierRaw: 0,
                isRecording: false,
                cameraOverheating: false))
        #expect(nominal.imageSize == 1)
        #expect(nominal.compression == 1)
        #expect(nominal.frameIntervalNanoseconds == 33_000_000)
        #expect(AndroidLiveViewPolicyWire.encode(nominal) == "1\t1\t33000000")

        let recordingUnderSeriousHeat = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 2,
                qualityBiasRaw: 2,
                thermalTierRaw: 2,
                isRecording: true,
                cameraOverheating: false))
        // Recording caps quality at VGA; the JPEG-bias selector is still
        // preview-only and the serious tier only slows preview pulls.
        #expect(recordingUnderSeriousHeat.imageSize == 2)
        #expect(recordingUnderSeriousHeat.compression == 3)
        #expect(recordingUnderSeriousHeat.frameIntervalNanoseconds == 49_500_000)
    }

    @Test("Hardware-verified camera hot state wins and invalid JNI values fail closed")
    func overheatAndInvalidValues() throws {
        let hot = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 2,
                qualityBiasRaw: 1,
                thermalTierRaw: 3,
                isRecording: false,
                cameraOverheating: true))
        #expect(hot.imageSize == 1)
        #expect(hot.compression == 2)
        #expect(hot.frameIntervalNanoseconds == 66_000_000)
        #expect(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 9,
                qualityBiasRaw: 0,
                thermalTierRaw: 0,
                isRecording: false,
                cameraOverheating: false) == nil)
    }
}
