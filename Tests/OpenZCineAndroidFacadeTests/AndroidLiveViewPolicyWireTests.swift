import OpenZCineCore
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
        // Latency = Basic grade, size priority = 0. The compression property is a 6-value
        // enum; the old 1/2/3 mapping never reached the Fine grade at all.
        #expect(nominal.compression == 0)
        #expect(nominal.frameIntervalNanoseconds == 1_000_000_000 / 60)
        #expect(
            AndroidLiveViewPolicyWire.encode(nominal)
                == "1\t0\t\(1_000_000_000 / 60)")

        let recordingUnderSeriousHeat = try #require(
            AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 2,
                qualityBiasRaw: 2,
                thermalTierRaw: 2,
                isRecording: true,
                cameraOverheating: false))
        // The operator's preset is honoured unconditionally — recording and heat no longer step
        // the preview down. A field monitor that quietly drops its own resolution while rolling
        // is worse than a warm phone, and the step-down was also silently overriding the Stream
        // Preset the operator had chosen.
        #expect(recordingUnderSeriousHeat.imageSize == 3)
        // Detail = Fine grade, quality priority = 5 — previously unreachable.
        #expect(recordingUnderSeriousHeat.compression == 5)
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

    @Test("The operator's steps span the compression property's real range")
    func compressionReachesTheFineGrade() {
        // Six values: Basic/Normal/Fine x size-priority/quality-priority. The steps have to
        // walk the GRADES — an earlier 1/2/3 mapping assumed three values, so the top setting
        // only ever reached Normal and the Fine grade was unreachable from the UI.
        let bytes = OperatorPreferences.QualityBias.allCases.map(\.liveViewImageCompression)
        #expect(bytes == bytes.sorted())
        #expect(Set(bytes).count == bytes.count)
        #expect(bytes.allSatisfy { (0...5).contains($0) })
        #expect(OperatorPreferences.QualityBias.detail.liveViewImageCompression >= 4)
        // …and the facade must accept it, having previously rejected anything outside 1...3.
        for bias in OperatorPreferences.QualityBias.allCases {
            let resolved = AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: 2,
                qualityBiasRaw: OperatorPreferences.QualityBias.allCases.firstIndex(of: bias)!,
                thermalTierRaw: 0,
                isRecording: false,
                cameraOverheating: false)
            #expect(resolved?.compression == bias.liveViewImageCompression)
        }
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
        // Camera-reported overheat no longer shrinks the preview either.
        #expect(hot.imageSize == 3)
        // Balanced = Normal grade, quality priority = 3.
        #expect(hot.compression == 3)
        // Cadence stays at the fixed 60 Hz target.
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
