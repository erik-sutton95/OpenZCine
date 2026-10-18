import Foundation
import Testing

@testable import OpenZCineCore

/// What survives the retired MAG tool: the persisted factor set, the tool policy and old saved
/// configs still decoding.
@Suite("Live-view magnification")
struct MagnificationTests {

    @Test("Every offered factor punches in by exactly that much")
    func factors() {
        #expect(AssistConfiguration.Magnification.Factor.allCases.count == 3)
        #expect(AssistConfiguration.Magnification.Factor.x2.scale == 2)
        #expect(AssistConfiguration.Magnification.Factor.x3.scale == 3)
        #expect(AssistConfiguration.Magnification.Factor.x4.scale == 4)
    }

    /// Retired: no surface offers it, while saved names still decode.
    @Test("Magnification is retired from every surface")
    func toolPolicy() {
        #expect(MonitorAssistTool.magnification.isRetired)
        #expect(!MonitorAssistTool.activeCases.contains(.magnification))
    }

    @Test("The factor persists and an older saved config still loads")
    func persistence() throws {
        var preferences = AssistConfiguration()
        preferences.magnification.factor = .x4
        let data = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(AssistConfiguration.self, from: data)
        #expect(restored.magnification.factor == .x4)
        // A config saved before this field existed decodes to the default rather than failing.
        var json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "magnification")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: legacy)
        #expect(decoded.magnification.factor == .x2)
    }
}
