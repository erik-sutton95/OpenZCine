import Testing

@testable import OpenZCineCore

@Suite struct ScopeActivationOrderTests {
    @Test func activationAppendsInOrder() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        AssistToolActivation.set(
            .parade, visible: true, preferences: &prefs, configuration: &config)
        AssistToolActivation.set(
            .waveform, visible: true, preferences: &prefs, configuration: &config)
        AssistToolActivation.set(
            .histogram, visible: true, preferences: &prefs, configuration: &config)
        #expect(prefs.scopeActivationOrder == [.parade, .waveform, .histogram])
    }

    @Test func deactivationRemoves() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        for tool in [MonitorAssistTool.parade, .waveform] {
            AssistToolActivation.set(
                tool, visible: true, preferences: &prefs, configuration: &config)
        }
        AssistToolActivation.set(
            .parade, visible: false, preferences: &prefs, configuration: &config)
        #expect(prefs.scopeActivationOrder == [.waveform])
    }

    @Test func reactivationMovesToNewest() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        for tool in [MonitorAssistTool.parade, .waveform] {
            AssistToolActivation.set(
                tool, visible: true, preferences: &prefs, configuration: &config)
        }
        AssistToolActivation.set(
            .parade, visible: true, preferences: &prefs, configuration: &config)
        #expect(prefs.scopeActivationOrder == [.waveform, .parade])
    }

    @Test func nonScopeToolsNeverRecorded() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        AssistToolActivation.set(.zebra, visible: true, preferences: &prefs, configuration: &config)
        AssistToolActivation.set(.grid, visible: true, preferences: &prefs, configuration: &config)
        #expect(prefs.scopeActivationOrder.isEmpty)
    }

    @Test func playbackContextDoesNotTouchOrder() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        AssistToolActivation.set(
            .waveform, visible: true, context: .playback,
            preferences: &prefs, configuration: &config)
        #expect(prefs.scopeActivationOrder.isEmpty)
    }

    // MARK: - displayedFitScopes (R8)

    @Test func displayedFitScopesPicksTwoMostRecentInCanonicalOrder() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        for tool in [MonitorAssistTool.waveform, .parade, .histogram] {
            AssistToolActivation.set(
                tool, visible: true, preferences: &prefs, configuration: &config)
        }
        // Order is [.waveform, .parade, .histogram]; two most recent = {.parade, .histogram},
        // re-sorted into canonical order.
        #expect(prefs.displayedFitScopes == [.parade, .histogram])
    }

    @Test func displayedFitScopesFallsBackToCanonicalPrefixWhenOrderEmpty() {
        var prefs = OperatorPreferences()
        // Pre-migration payload: active scopes but no recorded order.
        prefs.liveViewVisibleAssistTools = [.waveform, .parade, .histogram]
        prefs.scopeActivationOrder = []
        #expect(prefs.displayedFitScopes == [.waveform, .parade])
    }

    @Test func deactivatingDisplayedScopePromotesRememberedOne() {
        var prefs = OperatorPreferences()
        var config = AssistConfiguration()
        for tool in [MonitorAssistTool.waveform, .parade, .histogram] {
            AssistToolActivation.set(
                tool, visible: true, preferences: &prefs, configuration: &config)
        }
        // Displayed = [.parade, .histogram]; .waveform is remembered.
        #expect(prefs.displayedFitScopes == [.parade, .histogram])
        AssistToolActivation.set(
            .histogram, visible: false, preferences: &prefs, configuration: &config)
        // .waveform (remembered) now rejoins the display alongside .parade, canonical order.
        #expect(prefs.displayedFitScopes == [.waveform, .parade])
    }
}
