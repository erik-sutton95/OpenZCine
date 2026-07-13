import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Guides aspect ratios")
struct GuidesTests {
    typealias Guides = AssistConfiguration.Guides

    @Test func aspectRatioValueParsesLabel() {
        #expect(abs(Guides.AspectRatio.ratio239.value - 2.39) < 1e-9)
        #expect(abs(Guides.AspectRatio.ratio9x16.value - 0.5625) < 1e-9)
        #expect(abs(Guides.AspectRatio.ratio1x1.value - 1.0) < 1e-9)
        #expect(abs(Guides.AspectRatio.ratio16x9.value - 16.0 / 9.0) < 1e-9)
    }

    @Test func familyListsMatchTabs() {
        #expect(Guides.AspectRatio.ratios(for: .film) == Guides.AspectRatio.film)
        #expect(Guides.AspectRatio.ratios(for: .social) == Guides.AspectRatio.social)
        // The vertical hero ratio is a social-only delivery format.
        #expect(Guides.AspectRatio.social.contains(.ratio9x16))
        #expect(!Guides.AspectRatio.film.contains(.ratio9x16))
        // Cinemascope is film-only.
        #expect(Guides.AspectRatio.film.contains(.ratio239))
        #expect(!Guides.AspectRatio.social.contains(.ratio239))
    }

    @Test func toggleAddsAndRemoves() {
        var guides = Guides(selectedRatios: [.ratio239])
        guides.toggle(.ratio185)
        #expect(guides.selectedRatios == [.ratio239, .ratio185])
        guides.toggle(.ratio239)
        #expect(guides.selectedRatios == [.ratio185])
        #expect(guides.isSelected(.ratio185))
        #expect(!guides.isSelected(.ratio239))
    }

    @Test func decodesLegacySingleAspectRatioIntoSet() throws {
        // The shipped shape used a single `aspectRatio` field; migrate it into the new set so a
        // persisted config doesn't reset the whole AssistConfiguration on decode.
        let legacy = #"{"family":"Film","aspectRatio":"2.35:1","maskEnabled":true}"#
        let guides = try JSONDecoder().decode(Guides.self, from: Data(legacy.utf8))
        #expect(guides.selectedRatios == [.ratio235])
        #expect(guides.maskEnabled == true)
    }

    @Test func roundTripsNewSelectedRatiosSet() throws {
        let original = Guides(
            family: .social, selectedRatios: [.ratio9x16, .ratio1x1], maskEnabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Guides.self, from: data)
        #expect(decoded == original)
    }

    @Test func summaryLabelReflectsSelection() {
        #expect(Guides(selectedRatios: []).summaryLabel == "—")
        #expect(Guides(selectedRatios: [.ratio239]).summaryLabel == "2.39:1")
        #expect(Guides(selectedRatios: [.ratio239, .ratio185]).summaryLabel == "2 ratios")
    }

    @Test func missingSelectionFallsBackToDefault() throws {
        let empty = #"{"family":"Social","maskEnabled":false}"#
        let guides = try JSONDecoder().decode(Guides.self, from: Data(empty.utf8))
        #expect(guides.selectedRatios == [.ratio239])
    }
}
