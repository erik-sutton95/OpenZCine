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

    @Test func displayedFitScopesUsesCanonicalPrefixDespiteRecordedRecency() {
        var prefs = OperatorPreferences()
        let on: [MonitorAssistTool] = [.waveform, .parade, .histogram]
        for tool in on { prefs.recordScopeActivation(tool, on: true) }
        // Stored activation history stays intact; fit uses the canonical eligible prefix.
        #expect(prefs.displayedFitScopes(on: Set(on)) == [.waveform, .parade])
    }

    @Test func displayedFitScopesUsesCanonicalPrefixForMigratedSelection() {
        var prefs = OperatorPreferences()
        // Migrated install: active scopes but no recorded order.
        prefs.scopeActivationOrder = []
        #expect(
            prefs.displayedFitScopes(on: [.waveform, .parade, .histogram]) == [.waveform, .parade])
    }

    @Test func deactivatingDisplayedScopePromotesNextEligibleSelection() {
        var prefs = OperatorPreferences()
        var on: Set<MonitorAssistTool> = []
        for tool in [MonitorAssistTool.waveform, .parade, .histogram] {
            on.insert(tool)
            prefs.recordScopeActivation(tool, on: true)
        }
        // The first two display; histogram stays selected but hidden in fit.
        #expect(prefs.displayedFitScopes(on: on) == [.waveform, .parade])
        on.remove(.waveform)
        prefs.recordScopeActivation(.waveform, on: false)
        // Removing the first eligible selection admits the next one in canonical order.
        #expect(prefs.displayedFitScopes(on: on) == [.parade, .histogram])
    }
}
