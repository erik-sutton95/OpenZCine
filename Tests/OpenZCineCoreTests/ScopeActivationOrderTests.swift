import Testing

@testable import OpenZCineCore

@Suite struct ScopeActivationOrderTests {
    @Test func activationAppendsInOrder() {
        var prefs = OperatorPreferences()
        prefs.recordScopeActivation(.parade, on: true)
        prefs.recordScopeActivation(.waveform, on: true)
        prefs.recordScopeActivation(.histogram, on: true)
        #expect(prefs.scopeActivationOrder == [.parade, .waveform, .histogram])
    }

    @Test func deactivationRemoves() {
        var prefs = OperatorPreferences()
        for tool in [MonitorAssistTool.parade, .waveform] {
            prefs.recordScopeActivation(tool, on: true)
        }
        prefs.recordScopeActivation(.parade, on: false)
        #expect(prefs.scopeActivationOrder == [.waveform])
    }

    @Test func reactivationMovesToNewest() {
        var prefs = OperatorPreferences()
        for tool in [MonitorAssistTool.parade, .waveform] {
            prefs.recordScopeActivation(tool, on: true)
        }
        prefs.recordScopeActivation(.parade, on: true)
        #expect(prefs.scopeActivationOrder == [.waveform, .parade])
    }

    @Test func nonScopeToolsNeverRecorded() {
        var prefs = OperatorPreferences()
        prefs.recordScopeActivation(.zebra, on: true)
        prefs.recordScopeActivation(.grid, on: true)
        #expect(prefs.scopeActivationOrder.isEmpty)
    }

    // MARK: - displayedFitScopes (R8)

    @Test func displayedFitScopesPicksTwoMostRecentInCanonicalOrder() {
        var prefs = OperatorPreferences()
        let on: [MonitorAssistTool] = [.waveform, .parade, .histogram]
        for tool in on { prefs.recordScopeActivation(tool, on: true) }
        // Order is [.waveform, .parade, .histogram]; two most recent = {.parade, .histogram},
        // re-sorted into canonical order.
        #expect(prefs.displayedFitScopes(on: Set(on)) == [.parade, .histogram])
    }

    @Test func displayedFitScopesFallsBackToCanonicalPrefixWhenOrderEmpty() {
        var prefs = OperatorPreferences()
        // Migrated install: active scopes but no recorded order.
        prefs.scopeActivationOrder = []
        #expect(prefs.displayedFitScopes(on: [.waveform, .parade, .histogram]) == [.waveform, .parade])
    }

    @Test func deactivatingDisplayedScopePromotesRememberedOne() {
        var prefs = OperatorPreferences()
        var on: Set<MonitorAssistTool> = []
        for tool in [MonitorAssistTool.waveform, .parade, .histogram] {
            on.insert(tool)
            prefs.recordScopeActivation(tool, on: true)
        }
        // Displayed = [.parade, .histogram]; .waveform is remembered.
        #expect(prefs.displayedFitScopes(on: on) == [.parade, .histogram])
        on.remove(.histogram)
        prefs.recordScopeActivation(.histogram, on: false)
        // .waveform (remembered) now rejoins the display alongside .parade, canonical order.
        #expect(prefs.displayedFitScopes(on: on) == [.waveform, .parade])
    }
}
