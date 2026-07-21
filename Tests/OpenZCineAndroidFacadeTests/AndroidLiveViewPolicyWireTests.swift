import Testing

@testable import OpenZCineAndroidFacade

struct AndroidLiveViewPolicyWireTests {
    @Test("Android wire resolves shared stream choices at a fixed 60 Hz cadence")
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
        #expect(nominal.frameIntervalNanoseconds == 1_000_000_000 / 60)
        #expect(
            AndroidLiveViewPolicyWire.encode(nominal)
                == "1\t1\t\(1_000_000_000 / 60)")

        let recordingUnderSeriousHeat = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 2,
                qualityBiasRaw: 2,
                thermalTierRaw: 2,
                isRecording: true,
                cameraOverheating: false))
        // Recording caps quality at VGA; the JPEG-bias selector is still
        // preview-only. Cadence stays locked at 60 Hz under thermal.
        #expect(recordingUnderSeriousHeat.imageSize == 2)
        #expect(recordingUnderSeriousHeat.compression == 3)
        #expect(recordingUnderSeriousHeat.frameIntervalNanoseconds == 1_000_000_000 / 60)
    }

    @Test("Recording frame rate is ignored; cadence stays locked at 60 Hz")
    func ignoresRecordingFrameRate() throws {
        let at25 = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 1,
                qualityBiasRaw: 1,
                thermalTierRaw: 0,
                isRecording: false,
                cameraOverheating: false,
                recordingFrameRate: 25))
        let at50 = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 1,
                qualityBiasRaw: 1,
                thermalTierRaw: 0,
                isRecording: false,
                cameraOverheating: false,
                recordingFrameRate: 50))
        #expect(at25.frameIntervalNanoseconds == 1_000_000_000 / 60)
        #expect(at50.frameIntervalNanoseconds == 1_000_000_000 / 60)
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
        // Overheat drops preview size; cadence stays at the fixed 60 Hz target.
        #expect(hot.frameIntervalNanoseconds == 1_000_000_000 / 60)
        #expect(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 9,
                qualityBiasRaw: 0,
                thermalTierRaw: 0,
                isRecording: false,
                cameraOverheating: false) == nil)
    }
}
