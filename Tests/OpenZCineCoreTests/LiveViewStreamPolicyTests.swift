import Testing

@testable import OpenZCineCore

@Suite("Live-view stream policy preferences")
struct LiveViewStreamPolicyTests {
    @Test("Stream presets map to the documented disposable-preview sizes")
    func streamPresetImageSizes() {
        #expect(OperatorPreferences.StreamPreset.fast.liveViewImageSize == 1)
        #expect(OperatorPreferences.StreamPreset.balanced.liveViewImageSize == 2)
        #expect(OperatorPreferences.StreamPreset.quality.liveViewImageSize == 3)
    }

    @Test("Quality choices remain preview-compression selectors")
    func qualityBiasCompressionSelectors() {
        #expect(OperatorPreferences.QualityBias.latency.liveViewImageCompression == 1)
        #expect(OperatorPreferences.QualityBias.balanced.liveViewImageCompression == 2)
        #expect(OperatorPreferences.QualityBias.detail.liveViewImageCompression == 3)
    }
}
