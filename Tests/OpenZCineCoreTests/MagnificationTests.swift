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

    /// The whole point of the tool: focus is rarely in the middle of the shot, so a centred punch
    /// magnifies whatever happens to be there rather than the thing being focused.
    @Test("The punch-in aims at the focus box, not the middle of the frame")
    func anchorFollowsTheBox() {
        // A box in the upper-left quadrant of a 6048×3400 header space.
        let anchor = Magnification.anchor(
            boxCenterX: 1512, boxCenterY: 850, coordinateWidth: 6048, coordinateHeight: 3400)
        #expect(anchor.x == 0.25)
        #expect(anchor.y == 0.25)
        // Moving the point moves the anchor — this is read per frame, never latched.
        let moved = Magnification.anchor(
            boxCenterX: 4536, boxCenterY: 2550, coordinateWidth: 6048, coordinateHeight: 3400)
        #expect(moved.x == 0.75)
        #expect(moved.y == 0.75)
    }

    /// The anchor is the scale's FIXED POINT, so the visible window stays inside the frame at every
    /// factor without clamping — including hard against a corner, where recentring could not.
    @Test("Any in-frame anchor keeps the magnified window inside the picture")
    func anchorNeverLeavesTheFrame() {
        for factor in AssistConfiguration.Magnification.Factor.allCases {
            let scale = Magnification.scale(factor: factor.scale, isActive: true)
            for unit in [0.0, 0.25, 0.5, 0.75, 1.0] {
                // scaleEffect(s, anchor: a) maps p -> a + s(p - a); the visible window is the
                // preimage of [0, 1].
                let start = unit * (1 - 1 / scale)
                let end = start + 1 / scale
                #expect(start >= -1e-12)
                #expect(end <= 1 + 1e-12)
            }
        }
    }

    @Test("With no box to aim at, the punch-in falls back to the centre")
    func anchorFallsBackToCentre() {
        let none = Magnification.anchor(
            boxCenterX: nil, boxCenterY: nil, coordinateWidth: 6048, coordinateHeight: 3400)
        #expect(none == (x: 0.5, y: 0.5))
        // A header that reported no coordinate space cannot be divided by.
        let empty = Magnification.anchor(
            boxCenterX: 100, boxCenterY: 100, coordinateWidth: 0, coordinateHeight: 0)
        #expect(empty == (x: 0.5, y: 0.5))
        // A box outside the reported space clamps rather than throwing the view off the picture.
        let outside = Magnification.anchor(
            boxCenterX: 9000, boxCenterY: -40, coordinateWidth: 6048, coordinateHeight: 3400)
        #expect(outside.x == 1)
        #expect(outside.y == 0)
    }

    /// With subject detection on, the selected box is the face or eye actually being focused. At 4×
    /// the difference between "the face" and "the eye" is the whole question.
    @Test("The punch-in follows the selected subject box, else the AF area")
    func anchorBoxSelection() {
        #expect(Magnification.anchorBoxIndex(boxCount: 3, selectedBoxIndex: 2) == 2)
        #expect(Magnification.anchorBoxIndex(boxCount: 3, selectedBoxIndex: nil) == 0)
        // Nothing to aim at.
        #expect(Magnification.anchorBoxIndex(boxCount: 0, selectedBoxIndex: nil) == nil)
        #expect(Magnification.anchorBoxIndex(boxCount: 0, selectedBoxIndex: 1) == nil)
        // A selection the box array cannot honour falls back to the AF area rather than trapping.
        #expect(Magnification.anchorBoxIndex(boxCount: 2, selectedBoxIndex: 7) == 0)
        #expect(Magnification.anchorBoxIndex(boxCount: 2, selectedBoxIndex: -1) == 0)
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
