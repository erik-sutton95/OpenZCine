import Testing

@testable import OpenZCineCore

@Suite("Focus peaking")
struct PeakingTests {
    @Test("A flat region has no gradient and no edge")
    func flat() {
        #expect(Peaking.gradientMagnitude(center: 100, right: 100, below: 100) == 0)
        #expect(!Peaking.isEdge(center: 100, right: 100, below: 100))
    }

    @Test("A steep horizontal step is an edge")
    func horizontalEdge() {
        // |100-60| + |100-100| = 40 > 34.
        #expect(Peaking.gradientMagnitude(center: 100, right: 60, below: 100) == 40)
        #expect(Peaking.isEdge(center: 100, right: 60, below: 100))
    }

    @Test("A gentle gradient stays below the threshold")
    func gentle() {
        // |100-90| + |100-80| = 30, not an edge at the default threshold.
        #expect(!Peaking.isEdge(center: 100, right: 90, below: 80))
    }

    @Test("Threshold is strict")
    func strictThreshold() {
        #expect(!Peaking.isEdge(center: 100, right: 66, below: 100))  // mag 34, not > 34
        #expect(Peaking.isEdge(center: 100, right: 65, below: 100))  // mag 35
    }

    @Test("Peaking colours are defined for every preset")
    func colors() {
        #expect(Peaking.Color.allCases.count == 4)
        #expect(Peaking.Color.blue.rgb.2 == 1.0)
    }
}

@Suite("Zebra exposure stripes")
struct ZebraTests {
    @Test("Clipping luma lands in the highlight zone")
    func highlightZone() {
        #expect(Zebra.zone(luma: 250) == .highlight)
        #expect(Zebra.zone(luma: 242) == .highlight)  // inclusive
    }

    @Test("A band around mid grey is the midtone zone")
    func midtoneZone() {
        #expect(Zebra.zone(luma: 140) == .midtone)
        #expect(Zebra.zone(luma: 138) == .midtone)  // within ±5
        #expect(Zebra.zone(luma: 146) == .none)  // outside ±5
    }

    @Test("Highlight outranks midtone")
    func priority() {
        // A very bright pixel is highlight even though it isn't near the midtone target.
        #expect(Zebra.zone(luma: 245) == .highlight)
    }

    @Test("Ordinary exposure is unstriped")
    func noZone() {
        #expect(Zebra.zone(luma: 100) == .none)
    }

    @Test("Highlight checkerboard alternates every 7 px on the x+y diagonal")
    func highlightPattern() {
        #expect(Zebra.isStripeOn(zone: .highlight, x: 0, y: 0))  // 0 % 14 = 0 < 7
        #expect(!Zebra.isStripeOn(zone: .highlight, x: 7, y: 0))  // 7 % 14 = 7, not < 7
        #expect(Zebra.isStripeOn(zone: .highlight, x: 14, y: 0))  // wraps back on
    }

    @Test("No zone never stripes")
    func noneNeverStripes() {
        #expect(!Zebra.isStripeOn(zone: .none, x: 0, y: 0))
        #expect(!Zebra.isStripeOn(zone: .none, x: 3, y: 9))
    }

    @Test("Midtone diagonal phase is stable for negative x−y")
    func midtoneNegative() {
        // (x−y+140) mod 12 must stay in range even when y > x (no negative-modulo glitch).
        let on = Zebra.isStripeOn(zone: .midtone, x: 0, y: 100)
        let onEquivalent = Zebra.isStripeOn(zone: .midtone, x: 12, y: 100)  // +12 → same phase
        #expect(on == onEquivalent)
    }
}
