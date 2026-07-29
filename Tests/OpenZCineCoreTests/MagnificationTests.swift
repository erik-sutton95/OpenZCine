import Foundation
import Testing

@testable import OpenZCineCore

/// The acceptance criteria that can be checked without a screen: every factor, the round trip back
/// to the original framing, and the states that must not desynchronise.
@Suite("Live-view magnification")
struct MagnificationTests {

    @Test("Every offered factor punches in by exactly that much")
    func factors() {
        #expect(AssistConfiguration.Magnification.Factor.allCases.count == 3)
        for factor in AssistConfiguration.Magnification.Factor.allCases {
            #expect(Magnification.scale(factor: factor.scale, isActive: true) == factor.scale)
        }
        #expect(AssistConfiguration.Magnification.Factor.x2.scale == 2)
        #expect(AssistConfiguration.Magnification.Factor.x3.scale == 3)
        #expect(AssistConfiguration.Magnification.Factor.x4.scale == 4)
    }

    /// "One tap enters the selected magnification and the next tap returns to the IDENTICAL normal
    /// framing" — so inactive has to be exactly 1, not approximately.
    @Test("Punching out restores the original framing exactly")
    func roundTrip() {
        for factor in AssistConfiguration.Magnification.Factor.allCases {
            #expect(Magnification.scale(factor: factor.scale, isActive: false) == 1)
        }
        // "Repeated toggling does not accumulate transforms": the scale is derived from the factor
        // every time rather than compounded, so any number of round trips is still exactly 1.
        var scale = 1.0
        for _ in 0..<50 {
            scale = Magnification.scale(factor: 4, isActive: true)
            scale = Magnification.scale(factor: 4, isActive: false)
        }
        #expect(scale == 1)
    }

    @Test("A degenerate or absent factor cannot magnify")
    func degenerate() {
        #expect(Magnification.scale(factor: 1, isActive: true) == 1)
        #expect(Magnification.scale(factor: 0, isActive: true) == 1)
        #expect(Magnification.scale(factor: -2, isActive: true) == 1)
        #expect(Magnification.scale(factor: .nan, isActive: true) == 1)
        #expect(Magnification.scale(factor: .infinity, isActive: true) == 1)
    }

    /// "Disabling the tool while punched in restores the normal view and removes the button" — the
    /// state the acceptance criteria single out as never allowed to desynchronise.
    @Test("Disabling the tool cannot leave a punch-in armed behind a missing button")
    func disablingClearsBoth() {
        #expect(Magnification.showsButton(toolEnabled: true))
        #expect(!Magnification.showsButton(toolEnabled: false))
        #expect(!Magnification.activeAfterDisabling())
        // The pair together: no button, and no transform.
        let active = Magnification.activeAfterDisabling()
        #expect(Magnification.scale(factor: 4, isActive: active) == 1)
    }

    @Test("The button says which factor it will apply, and how to leave")
    func labels() {
        #expect(Magnification.buttonLabel(factor: .x3, isActive: false) == "Magnify 3x")
        #expect(Magnification.buttonLabel(factor: .x3, isActive: true) == "Exit 3x magnification")
    }

    /// It is a view-assist tool with a popup, and it has to reach photography — punching in to
    /// confirm focus matters at least as much for stills as for cinema.
    @Test("Magnification is a configurable tool and reaches photography")
    func toolPolicy() {
        #expect(MonitorAssistTool.magnification.hasConfiguration)
        #expect(MonitorAssistTool.magnification.appliesToPhotography)
        #expect(MonitorAssistTool.magnification.displaySettingsTitle == "Magnification")
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
