import Testing

@testable import OpenZCineCore

@Suite("LinkSignalBars")
struct LinkSignalBarsTests {
    @Test("Quartile thresholds map to 0–4 bars from a reset state")
    func quartileThresholds() {
        // From bars == 0 the first score seeds the raw band immediately (no hysteresis).
        for (score, expected) in [
            (0, 0), (1, 1), (25, 1), (26, 2), (50, 2), (51, 3), (75, 3), (76, 4), (100, 4),
        ] {
            var filter = LinkSignalBars()
            #expect(filter.update(score: score) == expected, "score \(score)")
        }
    }

    @Test("Score hovering at a band boundary does not flicker")
    func hysteresisHolds() {
        var filter = LinkSignalBars()
        #expect(filter.update(score: 74) == 3)
        // Crossing into the 4-bar band without clearing the margin holds at 3…
        #expect(filter.update(score: 77) == 3)
        #expect(filter.update(score: 74) == 3)
        #expect(filter.update(score: 81) == 3)
        // …and clearing it commits.
        #expect(filter.update(score: 82) == 4)
        // Dropping just below the 4-bar floor holds at 4…
        #expect(filter.update(score: 74) == 4)
        #expect(filter.update(score: 70) == 4)
        // …until the score falls the margin below the current band's floor.
        #expect(filter.update(score: 69) == 3)
    }

    @Test("A multi-band collapse lands on the raw band once committed")
    func multiBandDrop() {
        var filter = LinkSignalBars()
        #expect(filter.update(score: 95) == 4)
        #expect(filter.update(score: 30) == 2)
    }

    @Test("Link loss and recovery bypass hysteresis")
    func zeroIsImmediate() {
        var filter = LinkSignalBars()
        #expect(filter.update(score: 90) == 4)
        #expect(filter.update(score: 0) == 0)
        #expect(filter.update(score: 85) == 4)
    }
}
