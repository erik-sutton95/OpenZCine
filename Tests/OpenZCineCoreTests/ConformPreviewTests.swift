import Foundation
import Testing

@testable import OpenZCineCore

/// The test matrix the feature discussion asked for: 60→24, 120→24, already-conformed clips, VFR,
/// and missing metadata. Each case is here because getting it wrong shows the operator a speed the
/// edit will never reproduce, with nothing on screen saying so.
@Suite("Slow-motion conform preview")
struct ConformPreviewTests {

    @Test("The worked example from the request: 60 to 24 is 40%")
    func sixtyToTwentyFour() {
        #expect(ConformPreview.speed(captureRate: 60, targetRate: 24) == 0.4)
        #expect(ConformPreview.label(captureRate: 60, targetRate: 24) == "60 → 24 fps · 40%")
    }

    @Test("120 to 24 is 20%, and the offered targets are every rate slower than the source")
    func oneTwentyToTwentyFour() {
        #expect(ConformPreview.speed(captureRate: 120, targetRate: 24) == 0.2)
        let availability = ConformPreview.availability(
            for: ConformPreview.Source(captureRate: 120))
        #expect(availability.targets == ConformPreview.targetRates)
    }

    /// A 30 fps clip must not be offered "conform to 30" — the control would do nothing — nor
    /// "conform to 29.97", which is a pulldown pair rather than a slow-motion conform.
    @Test("Only rates strictly slower than the source are offered")
    func onlySlowerTargets() {
        let thirty = ConformPreview.availability(for: ConformPreview.Source(captureRate: 30))
        #expect(thirty.targets == [23.976, 24, 25])
        // 24 fps has nothing meaningfully slower, so the feature is not offered at all.
        let twentyFour = ConformPreview.availability(for: ConformPreview.Source(captureRate: 24))
        #expect(twentyFour == .notHighFrameRate)
        #expect(!twentyFour.isAvailable)
    }

    /// Each refusal exists because the alternative is a plausible, wrong number.
    @Test("Untrustworthy sources refuse rather than guess, and say why")
    func refusals() {
        #expect(ConformPreview.availability(for: ConformPreview.Source()) == .unknownRate)
        #expect(
            ConformPreview.availability(for: ConformPreview.Source(captureRate: 0)) == .unknownRate)
        #expect(
            ConformPreview.availability(for: ConformPreview.Source(captureRate: .nan))
                == .unknownRate)
        #expect(
            ConformPreview.availability(
                for: ConformPreview.Source(captureRate: 120, isVariableFrameRate: true))
                == .variableRate)
        // Already conformed in camera: applying the factor again would show 40% of 40%.
        #expect(
            ConformPreview.availability(
                for: ConformPreview.Source(captureRate: 120, isAlreadyConformed: true))
                == .alreadyConformed)
        // Every refusal is explained to the operator rather than silently disabling the control.
        for source in [
            ConformPreview.Source(),
            ConformPreview.Source(captureRate: 120, isVariableFrameRate: true),
            ConformPreview.Source(captureRate: 120, isAlreadyConformed: true),
            ConformPreview.Source(captureRate: 24),
        ] {
            #expect(ConformPreview.availability(for: source).unavailableReason != nil)
        }
    }

    /// A variable rate is refused even though a capture rate is present — one factor cannot be
    /// right across the clip, so the ordering of the checks is itself the behaviour.
    @Test("Variable frame rate outranks a usable-looking capture rate")
    func variableRateWins() {
        let source = ConformPreview.Source(
            captureRate: 120, isVariableFrameRate: true, isAlreadyConformed: true)
        #expect(ConformPreview.availability(for: source) == .variableRate)
    }

    @Test("Conformed duration stretches by the reciprocal of the speed")
    func duration() {
        // The 6 s, 60 fps fixture: at 24 it runs 15 s.
        let speed = ConformPreview.speed(captureRate: 60, targetRate: 24)
        #expect(ConformPreview.conformedDuration(sourceSeconds: 6, speed: speed) == 15)
        // Degenerate inputs produce 0 rather than an infinity that would reach a time label.
        #expect(ConformPreview.conformedDuration(sourceSeconds: 6, speed: 0) == 0)
        #expect(ConformPreview.conformedDuration(sourceSeconds: .infinity, speed: 0.4) == 0)
    }

    /// Scrubbing has to stay anchored to real frames: the conform is a clock change, not a
    /// re-timing of the media.
    @Test("Seeking maps a conformed playhead back to a source frame index")
    func sourceFrames() {
        let speed = ConformPreview.speed(captureRate: 60, targetRate: 24)
        // 15 s conformed is the whole 6 s clip: frame 360 of a 360-frame source.
        #expect(
            ConformPreview.sourceFrameIndex(
                conformedSeconds: 15, captureRate: 60, speed: speed) == 360)
        // Halfway through the conformed timeline is halfway through the frames.
        #expect(
            ConformPreview.sourceFrameIndex(
                conformedSeconds: 7.5, captureRate: 60, speed: speed) == 180)
        #expect(
            ConformPreview.sourceFrameIndex(
                conformedSeconds: 0, captureRate: 60, speed: speed) == 0)
    }

    @Test("Rates read the way an operator writes them")
    func rateLabels() {
        #expect(ConformPreview.rateLabel(24) == "24")
        #expect(ConformPreview.rateLabel(60) == "60")
        #expect(ConformPreview.rateLabel(23.976) == "23.98")
        #expect(ConformPreview.rateLabel(29.97) == "29.97")
        #expect(ConformPreview.rateLabel(0) == "—")
    }

    /// The pulldown rates do not divide evenly, so the percentage has to survive a non-integer.
    @Test("A non-integer conform still states its speed")
    func pulldownLabel() {
        #expect(
            ConformPreview.label(captureRate: 59.94, targetRate: 23.976)
                == "59.94 → 23.98 fps · 40%"
        )
        let odd = ConformPreview.label(captureRate: 120, targetRate: 25)
        #expect(odd == "120 → 25 fps · 20.8%")
    }
}
