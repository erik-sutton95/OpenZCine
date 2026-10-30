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
}
