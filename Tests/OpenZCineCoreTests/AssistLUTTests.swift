import Foundation
import Testing

@testable import OpenZCineCore

@Test func analysisAssistToolsExposeQuickSettings() {
    for tool in [
        MonitorAssistTool.peaking, .falseColor, .zebra, .waveform, .parade, .histogram,
        .trafficLights,
    ] {
        #expect(tool.hasConfiguration)
    }
}

@Test func lutIsTheFirstAssistToolAndHasOptions() {
    #expect(MonitorAssistTool.allCases.first == .lut)
    #expect(MonitorAssistTool.lut.hasConfiguration)
}

@Test func lutResolvesActiveOnlyWhenTheToolIsOn() {
    #expect(LUTResolution.active(visibleTools: [], selected: .builtIn(.monochrome)) == nil)
    #expect(
        LUTResolution.active(visibleTools: [.lut], selected: .builtIn(.log3G10Rec709))
            == .builtIn(.log3G10Rec709))
}

@Test func lutSelectionCacheKeysAreDistinct() {
    #expect(LUTSelection.builtIn(.monochrome).cacheKey == "builtIn:Mono")
    #expect(
        LUTSelection.stored(category: .custom, fileName: "X.cube").cacheKey
            == "stored:Custom:X.cube")
}

@Test func assistConfigurationDefaultsToAStartingLook() {
    // The ZR's native feed is Log3G10 — the camera-matched conversion leads.
    #expect(AssistConfiguration.defaults.selectedLUT == .builtIn(.log3G10Rec709))
}

@Test func selectedLUTSurvivesJSONRoundTrip() throws {
    var config = AssistConfiguration.defaults
    config.selectedLUT = .stored(category: .custom, fileName: "MyLook.cube")

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: data)

    #expect(decoded.selectedLUT == .stored(category: .custom, fileName: "MyLook.cube"))
}

@Test func removedTealOrangeSelectionFallsBackToDefault() throws {
    // Confirmed synthesized shape (compiled probe against the pre-migration Codable): encoding
    // `.builtIn(.monochrome)` produced `{"builtIn":{"_0":"Mono"}}` — a single unlabeled associated
    // value nests under key "_0". This legacy payload matches that shape with the removed look's
    // raw value hand-swapped in.
    let legacy = Data(#"{"builtIn":{"_0":"Teal/Orange"}}"#.utf8)
    let decoded = try JSONDecoder().decode(LUTSelection.self, from: legacy)
    #expect(decoded == .builtIn(.log3G10Rec709))
}

@Test func contributedBuiltInSelectionRoundTrips() throws {
    // Adding a case must not disturb the persisted shape: the new look has to survive a save/load,
    // and `removedTealOrangeSelectionFallsBackToDefault` above proves an older blob naming a look
    // this build doesn't have still falls back instead of resetting the whole assist configuration.
    var config = AssistConfiguration.defaults
    config.selectedLUT = .builtIn(.r3dNEMonitor)
    let data = try JSONEncoder().encode(config)
    #expect(String(decoding: data, as: UTF8.self).contains(#""_0":"R3D NE Monitor""#))
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: data)
    #expect(decoded.selectedLUT == .builtIn(.r3dNEMonitor))
}

@Test func storedSelectionsStillRoundTrip() throws {
    let original = LUTSelection.stored(category: .red, fileName: "ipp2.cube")
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(LUTSelection.self, from: data) == original)
}
