import Foundation
import Testing

@testable import OpenZCineCore

/// A vertical step edge of amplitude `amp` blurred to `sigma`, rendered as the grey plane the
/// detector actually reads — the profile a lens puts on the sensor. Mid grey base so both a
/// positive and a negative excursion stay in range.
private func edgePlane(amp: Double, sigma: Double, size: Int = 40) -> [Double] {
    // Gaussian CDF via erf: the exact profile of a step convolved with the lens PSF.
    func level(_ x: Double) -> Double {
        0.5 * (1 + erf(x / (max(sigma, 1e-6) * 2.0.squareRoot())))
    }
    // Half a pixel off centre, so a perfectly sharp edge is a ONE-pixel step. Landing the edge
    // on a pixel centre instead gives that pixel the half value and spreads the step over two
    // transitions, which halves the fine operator and caps the ratio at 2.56 — a synthetic
    // artifact that looks exactly like a real detector failure.
    let centre = Double(size / 2) - 0.5
    return (0..<(size * size)).map { index in
        0.5 - amp / 2 + amp * level(Double(index % size) - centre)
    }
}

/// The two operator scales at the edge itself, built from the same public pieces the shells use:
/// the measured separable re-blur, then ``Peaking/robertsSquared`` on each plane.
private func edgeMeasurement(amp: Double, sigma: Double) -> (
    fine: Double, coarse: Double, ratio: Double
) {
    let size = 40
    let plane = edgePlane(amp: amp, sigma: sigma, size: size)
    func at(_ p: [Double], _ x: Int, _ y: Int) -> Double {
        p[min(max(y, 0), size - 1) * size + min(max(x, 0), size - 1)]
    }
    let taps = Peaking.reblurWeights.count / 2
    var rows = [Double](repeating: 0, count: size * size)
    var blurred = rows
    for y in 0..<size {
        for x in 0..<size {
            rows[y * size + x] = Peaking.reblurWeights.enumerated()
                .reduce(0) { $0 + $1.element * at(plane, x + $1.offset - taps, y) }
        }
    }
    for y in 0..<size {
        for x in 0..<size {
            blurred[y * size + x] = Peaking.reblurWeights.enumerated()
                .reduce(0) { $0 + $1.element * at(rows, x, y + $1.offset - taps) }
        }
    }
    // The response peaks at the step; both scales peak at the same column, the kernel being
    // symmetric, so one probe reads both.
    var best = (fine: 0.0, coarse: 0.0, ratio: 0.0)
    for x in (size / 2 - 3)...(size / 2 + 3) {
        let fine = Peaking.robertsSquared(x: x, y: size / 2) { at(plane, $0, $1) }
        if fine <= best.fine { continue }
        let coarse = Peaking.robertsSquared(x: x, y: size / 2) { at(blurred, $0, $1) }
        best = (fine, coarse, Peaking.sharpness(fine: fine, coarse: coarse))
    }
    return best
}

/// Mean stroke opacity over a plane, as a percentage — "how much paint is on screen".
private func ink(_ overlay: Peaking.Overlay) -> Double {
    100 * overlay.stroke.reduce(0, +) / Double(overlay.stroke.count)
}

@Suite("Focus peaking")
struct PeakingTests {
    @Test("A flat region has no gradient and never peaks")
    func flat() {
        let flat = [Double](repeating: 0.5, count: 40 * 40)
        #expect(Peaking.robertsSquared(x: 5, y: 5) { _, _ in 0.5 } == 0)
        #expect(ink(Peaking.overlay(grey: flat, width: 40, height: 40, sensitivity: .high)) == 0)
    }

    @Test("A perfectly sharp edge saturates the ratio ceiling, whatever its contrast")
    func sharpEdgeSaturates() {
        for amp in [0.2, 0.4, 1.0] {
            #expect(edgeMeasurement(amp: amp, sigma: 0.01).ratio == Peaking.ratioCeiling)
        }
    }

    @Test("A fully defocused edge collapses toward 1, whatever its contrast")
    func defocusedEdgeCollapses() {
        for amp in [0.2, 0.4, 1.0] {
            #expect(edgeMeasurement(amp: amp, sigma: 3).ratio < 1.2)
        }
    }

    /// The reported failure, as an assertion: a bright defocused highlight rim used to outrank
    /// dim in-focus detail because the old detector measured contrast rather than blur.
    @Test("Dim in-focus detail always outranks a bright defocused rim")
    func focusBeatsContrast() {
        let subject = edgeMeasurement(amp: 0.30, sigma: 0.7)  // fabric, in the focus plane
        let bokeh = edgeMeasurement(amp: 0.95, sigma: 2.0)  // clipped specular, well off it

        // The old magnitude-only metric got this backwards — the rim's raw operator is larger.
        #expect(bokeh.fine > subject.fine)
        // The ratio does not: it ranks by blur, so the subject wins by a clear margin.
        #expect(subject.ratio > bokeh.ratio + 1.0)
    }

    @Test("Every sensitivity separates in-focus detail from defocused background")
    func everySensitivitySeparates() {
        // Contrast high enough to clear even the strictest gate; the gate's own floor is the
        // subject of `contrastFloorRisesWithStrictness` below.
        let mustPeak = [(0.30, 0.7), (0.55, 0.8), (0.90, 0.7)]
        let mustReject = [(0.95, 2.0), (0.80, 3.0), (0.90, 4.0), (0.50, 1.8)]
        for sensitivity in Peaking.Sensitivity.allCases {
            for (amp, sigma) in mustPeak {
                let overlay = Peaking.overlay(
                    grey: edgePlane(amp: amp, sigma: sigma), width: 40, height: 40,
                    sensitivity: sensitivity)
                #expect(ink(overlay) > 0, "\(sensitivity) missed in-focus detail at \(amp)")
            }
            for (amp, sigma) in mustReject {
                let overlay = Peaking.overlay(
                    grey: edgePlane(amp: amp, sigma: sigma), width: 40, height: 40,
                    sensitivity: sensitivity)
                #expect(ink(overlay) == 0, "\(sensitivity) painted a defocused edge at \(amp)")
            }
        }
    }

    /// What a sensitivity step actually costs, stated rather than implied: the noise gate is an
    /// absolute magnitude, so a stricter step does not just reject more grain, it also stops
    /// seeing genuinely sharp edges below a contrast floor. That trade is the whole reason the
    /// gate moves so much less than the ratio threshold does between steps.
    @Test("A stricter step raises the contrast an in-focus edge needs")
    func contrastFloorRisesWithStrictness() {
        func floorContrast(_ sensitivity: Peaking.Sensitivity) -> Double {
            for step in 1...60 {
                let amp = Double(step) * 0.01
                let overlay = Peaking.overlay(
                    grey: edgePlane(amp: amp, sigma: 0.7), width: 40, height: 40,
                    sensitivity: sensitivity)
                if ink(overlay) > 0 { return amp }
            }
            return .infinity
        }
        let low = floorContrast(.low)
        let high = floorContrast(.high)
        #expect(high < low)
        // Even the strict end still reaches genuinely low-contrast detail, which is the half of
        // the original complaint that said peaking "misses things in the focus plane".
        #expect(high < 0.10)
        #expect(low < 0.25)
    }

    @Test("Noise reads as sharp, so only the gate can reject it")
    func noiseNeedsTheGate() {
        // Unblurred noise: the fine and coarse operators are comparable, so the ratio is high...
        let noise = (fine: 4.0e-6, coarse: 1.0e-6)
        #expect(Peaking.sharpness(fine: noise.fine, coarse: noise.coarse) > 3)
        // ...and every step still refuses it, purely on magnitude.
        for sensitivity in Peaking.Sensitivity.allCases {
            #expect(Peaking.gateOpacity(coarse: noise.coarse, gate: sensitivity.noiseGate) == 0)
        }
    }

    @Test("Sensitivity steps are ordered, and stricter means a higher bar")
    func sensitivityOrdering() {
        #expect(
            Peaking.Sensitivity.low.ratioThreshold > Peaking.Sensitivity.medium.ratioThreshold)
        #expect(
            Peaking.Sensitivity.medium.ratioThreshold > Peaking.Sensitivity.high.ratioThreshold)
        #expect(Peaking.Sensitivity.low.noiseGate > Peaking.Sensitivity.high.noiseGate)
        // Every threshold has to sit inside the ratio's actual range or it can never fire, and
        // the under-hairline's ramp starts below it, so that has to clear 1 too.
        for sensitivity in Peaking.Sensitivity.allCases {
            #expect(sensitivity.ratioThreshold > 1)
            #expect(sensitivity.ratioThreshold < Peaking.ratioCeiling)
            #expect(
                sensitivity.ratioThreshold - Peaking.antialiasWidth * Peaking.underRampOffset > 1)
        }
    }

    @Test("The sensitivity range is genuinely wide, and Med is still the anchor")
    func gateRangeIsWide() {
        let low = Peaking.Sensitivity.low.noiseGate
        let medium = Peaking.Sensitivity.medium.noiseGate
        let high = Peaking.Sensitivity.high.noiseGate
        #expect(low > medium)
        #expect(medium > high)
        // It used to span 2.9x, which made the ends barely worth reaching for.
        #expect(low / high > 8)
        // Med is re-anchored to its closed equivalent: same ink as before, far less fragmented.
        #expect(medium == 0.00174)
    }

    @Test("A wide range is only safe while the overlay is closed afterwards")
    func wideRangeRequiresClosing() {
        // The strict end works by punching holes in edges that ARE sharp, and a dashed line
        // reads as more noise than a solid one. Closing is what puts them back, so the two
        // cannot be separated: if the closing is ever removed, the range has to come back in.
        #expect(Peaking.maskClosingRadius > 0)
        // Closing, never opening — the strokes are ~1 px, so an erode-first pass would delete
        // them. A radius this small also cannot bridge genuinely separate edges.
        #expect(Peaking.maskClosingRadius <= 2.0)
        // The measured element: a five-point plus, not the 3x3 square the filter name suggests.
        #expect(Peaking.closingOffsets.count == 5)
        #expect(Peaking.closingOffsets.allSatisfy { abs($0.0) + abs($0.1) <= 1 })
    }

    /// Closing has to actually close, and this is the shape it exists for: a stroke the noise
    /// gate has punched a one-pixel hole in. Run directly on a hand-built mask through
    /// ``Peaking/overlay``'s own morphology, because a dashed line is the failure the whole
    /// sensitivity range rests on.
    @Test("Closing rejoins a dashed stroke without inventing a new one")
    func closingRejoinsDashes() {
        // A sharp vertical edge paints a continuous line; punching the plane's contrast down for
        // one row breaks it, and closing must put that row back.
        let size = 40
        var plane = edgePlane(amp: 0.9, sigma: 0.4, size: size)
        for x in 0..<size { plane[(size / 2) * size + x] = 0.5 }

        let closed = Peaking.overlay(
            grey: plane, width: size, height: size, sensitivity: .medium, closing: true)
        let open = Peaking.overlay(
            grey: plane, width: size, height: size, sensitivity: .medium, closing: false)
        // Closing only ever adds paint, and here it adds some.
        #expect(ink(closed) > ink(open))
        #expect(zip(closed.stroke, open.stroke).allSatisfy { $0 >= $1 })
        // It does not paint a flat frame: nothing to close means nothing appears.
        let flat = [Double](repeating: 0.5, count: size * size)
        #expect(
            ink(Peaking.overlay(grey: flat, width: size, height: size, sensitivity: .high)) == 0)
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
