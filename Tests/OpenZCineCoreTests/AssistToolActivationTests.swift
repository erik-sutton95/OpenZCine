import Testing

@testable import OpenZCineCore

@Test func togglePlainToolFlipsMembershipOnlyInContext() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.toggle(
        .peaking, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(prefs.visibleAssistTools(for: .liveView).contains(.peaking))
    #expect(!prefs.visibleAssistTools(for: .playback).contains(.peaking))
    AssistToolActivation.toggle(
        .peaking, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(!prefs.visibleAssistTools(for: .liveView).contains(.peaking))
}

@Test func liveAndPlaybackAssistSetsAreIndependent() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.set(
        .falseColor, visible: true, context: .liveView, preferences: &prefs, configuration: &config)
    AssistToolActivation.set(
        .waveform, visible: true, context: .playback, preferences: &prefs, configuration: &config)
    #expect(prefs.visibleAssistTools(for: .liveView) == Set([.falseColor]))
    #expect(prefs.visibleAssistTools(for: .playback) == Set([.waveform]))
}

@Test func toggleLevelKeepsEnabledFlagInSync() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.toggle(
        .level, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(prefs.visibleAssistTools(for: .liveView).contains(.level))
    #expect(config.level.enabled)
    AssistToolActivation.toggle(
        .level, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(!prefs.visibleAssistTools(for: .liveView).contains(.level))
    #expect(!config.level.enabled)
}

@Test func levelStaysEnabledWhenPlaybackContextHasItOn() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.set(
        .level, visible: true, context: .playback, preferences: &prefs, configuration: &config)
    #expect(config.level.enabled)
    AssistToolActivation.set(
        .level, visible: false, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(config.level.enabled)
}

@Test func toggleDesqueezeKeepsEnabledFlagInSync() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.toggle(
        .desqueeze, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(prefs.visibleAssistTools(for: .liveView).contains(.desqueeze))
    #expect(config.desqueeze.enabled)
    AssistToolActivation.toggle(
        .desqueeze, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(!prefs.visibleAssistTools(for: .liveView).contains(.desqueeze))
    #expect(!config.desqueeze.enabled)
}

@Test func setVisibleIsIdempotentAndSyncsEnabled() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.set(
        .level, visible: true, context: .liveView, preferences: &prefs, configuration: &config)
    AssistToolActivation.set(
        .level, visible: true, context: .liveView, preferences: &prefs, configuration: &config)
    #expect(prefs.visibleAssistTools(for: .liveView).contains(.level))
    #expect(config.level.enabled)
}

@Test func legacyToggleDefaultsToLiveViewContext() {
    var prefs = OperatorPreferences.defaults
    var config = AssistConfiguration.defaults
    AssistToolActivation.toggle(.zebra, preferences: &prefs, configuration: &config)
    #expect(prefs.visibleAssistTools(for: .liveView).contains(.zebra))
    #expect(!prefs.visibleAssistTools(for: .playback).contains(.zebra))
}
