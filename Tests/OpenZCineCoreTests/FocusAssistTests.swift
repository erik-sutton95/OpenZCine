import Foundation
import Testing

@testable import OpenZCineCore

/// A step edge of amplitude `amp` blurred to radius `sigma`, sampled the way the shader does:
/// the fine pair straddles the edge centre at ±1 px, the coarse pair at ±2 px.
private func edgeSample(amp: Double, sigma: Double) -> (fine: Double, coarse: Double) {
    // Gaussian CDF via erf — the exact profile of a step convolved with the lens PSF.
    func level(_ x: Double) -> Double {
        0.5 * amp * (1 + erf(x / (max(sigma, 1e-6) * 2.0.squareRoot())))
    }
    return (
        fine: Peaking.gradientMagnitude(
            left: level(-1), right: level(1), up: level(0), down: level(0), spacing: 1),
        coarse: Peaking.gradientMagnitude(
            left: level(-2), right: level(2), up: level(0), down: level(0), spacing: 2)
    )
}

@Suite("Focus peaking")
struct PeakingTests {
    @Test("A flat region has no gradient and never peaks")
    func flat() {
        #expect(
            Peaking.gradientMagnitude(left: 1, right: 1, up: 1, down: 1, spacing: 1) == 0)
        #expect(!Peaking.isEdge(fine: 0, coarse: 0))
    }

    @Test("A perfectly sharp edge reaches the maximum ratio, whatever its contrast")
    func sharpEdgeSaturates() {
        for amp in [0.05, 0.4, 1.0] {
            let sample = edgeSample(amp: amp, sigma: 0.01)
            let ratio = Peaking.sharpnessRatio(fine: sample.fine, coarse: sample.coarse)
            #expect(abs(ratio - Peaking.wideTapSharpRatio) < 0.01)
        }
    }

    @Test("A fully defocused edge collapses toward 1, whatever its contrast")
    func defocusedEdgeCollapses() {
        for amp in [0.05, 0.4, 1.0] {
            let sample = edgeSample(amp: amp, sigma: 6)
            let ratio = Peaking.sharpnessRatio(fine: sample.fine, coarse: sample.coarse)
            #expect(ratio < 1.05)
        }
    }

    /// The reported failure, as an assertion: a bright defocused highlight rim used to outrank
    /// dim in-focus detail because the old detector measured contrast rather than blur.
    @Test("Dim in-focus detail always outranks a bright defocused rim")
    func focusBeatsContrast() {
        let subject = edgeSample(amp: 0.05, sigma: 0.7)  // skin / fabric, in the focus plane
        let bokeh = edgeSample(amp: 0.95, sigma: 2.0)  // clipped specular, well off it

        // The old magnitude-only metric got this backwards — the rim's raw gradient is larger.
        #expect(bokeh.fine > subject.fine)

        // The ratio does not: it ranks by blur, so the subject wins by a clear margin.
        let subjectRatio = Peaking.sharpnessRatio(fine: subject.fine, coarse: subject.coarse)
        let bokehRatio = Peaking.sharpnessRatio(fine: bokeh.fine, coarse: bokeh.coarse)
        #expect(subjectRatio > bokehRatio + 0.2)
    }

    @Test("Every sensitivity separates in-focus detail from defocused background")
    func everySensitivitySeparates() {
        let mustPeak = [
            edgeSample(amp: 0.05, sigma: 0.7),  // very low contrast, sharp
            edgeSample(amp: 0.12, sigma: 0.7),
            edgeSample(amp: 0.35, sigma: 0.8),
            edgeSample(amp: 0.90, sigma: 0.7),
        ]
        let mustReject = [
            edgeSample(amp: 0.95, sigma: 2.0),  // bokeh rim, clipped
            edgeSample(amp: 0.80, sigma: 3.0),
            edgeSample(amp: 0.90, sigma: 4.0),
            edgeSample(amp: 0.50, sigma: 1.8),  // just off the focus plane
        ]
        for sensitivity in Peaking.Sensitivity.allCases {
            for sample in mustPeak {
                #expect(
                    Peaking.isEdge(
                        fine: sample.fine, coarse: sample.coarse, sensitivity: sensitivity),
                    "\(sensitivity) missed in-focus detail")
            }
            for sample in mustReject {
                #expect(
                    !Peaking.isEdge(
                        fine: sample.fine, coarse: sample.coarse, sensitivity: sensitivity),
                    "\(sensitivity) painted a defocused edge")
            }
        }
    }

    @Test("Noise reads as sharp, so only the gate can reject it")
    func noiseNeedsTheGate() {
        // Unblurred noise: the fine and coarse gradients are comparable, so the ratio is high.
        let noise = (fine: 0.004, coarse: 0.0025)
        #expect(Peaking.sharpnessRatio(fine: noise.fine, coarse: noise.coarse) > 1.5)
        for sensitivity in Peaking.Sensitivity.allCases {
            #expect(
                !Peaking.isEdge(
                    fine: noise.fine, coarse: noise.coarse, sensitivity: sensitivity))
        }
    }

    @Test("Sensitivity steps are ordered, and stricter means a higher bar")
    func sensitivityOrdering() {
        #expect(
            Peaking.Sensitivity.low.wideTapRatioThreshold
                > Peaking.Sensitivity.medium.wideTapRatioThreshold)
        #expect(
            Peaking.Sensitivity.medium.wideTapRatioThreshold
                > Peaking.Sensitivity.high.wideTapRatioThreshold)
        #expect(Peaking.Sensitivity.low.noiseGate > Peaking.Sensitivity.high.noiseGate)
        // Every threshold has to sit inside the ratio's actual range or it can never fire.
        for sensitivity in Peaking.Sensitivity.allCases {
            #expect(sensitivity.wideTapRatioThreshold > 1)
            #expect(sensitivity.wideTapRatioThreshold < Peaking.wideTapSharpRatio)
            #expect(sensitivity.reblurRatioThreshold > 1)
        }
    }

    @Test("The Core Image sensitivity range is genuinely wide, and Med is still the anchor")
    func reblurRangeIsWide() {
        let low = Peaking.Sensitivity.low.reblurNoiseGate
        let medium = Peaking.Sensitivity.medium.reblurNoiseGate
        let high = Peaking.Sensitivity.high.reblurNoiseGate
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
