import Testing

@testable import OpenZCineCore

@Suite("Scope display scale")
struct ScopeDisplayScaleTests {
    private let curve = ExposureToneCurve.redLog3G10

    @Test("Crush and clip codes land exactly on the fixed 5% safe-border lines")
    func anchorsLandOnTheFixedLines() {
        let mapping = ExposureSignalMapping(curve: curve)
        let black = ScopeDisplayScale.logBlackFloorCode(curve: curve)
        #expect(
            abs(
                ScopeDisplayScale.waveformLevel(signalNative: black, mapping: mapping)
                    - ScopeDisplayScale.crushLineLevel) < 1e-9)
        #expect(
            abs(
                ScopeDisplayScale.waveformLevel(signalNative: mapping.clipNative, mapping: mapping)
                    - ScopeDisplayScale.clipLineLevel) < 1e-9)
        // The borders themselves are constants — they never move with ISO.
        #expect(ScopeDisplayScale.crushLineLevel == 0.05)
        #expect(ScopeDisplayScale.clipLineLevel == 0.95)
    }

    @Test("The anchors hold when the ISO warning endpoint moves")
    func anchorsFollowISO() {
        for clip in [145.0, 180.0, 215.0] {
            let mapping = ExposureSignalMapping(curve: curve, clipNative: clip)
            #expect(
                abs(
                    ScopeDisplayScale.waveformLevel(signalNative: clip, mapping: mapping)
                        - ScopeDisplayScale.clipLineLevel) < 1e-9)
            #expect(
                abs(
                    ScopeDisplayScale.waveformLevel(
                        signalNative: mapping.blackNative, mapping: mapping)
                        - ScopeDisplayScale.crushLineLevel) < 1e-9)
        }
    }

    @Test("Sub-black and super-clip codes keep gradation in the margins, monotonically")
    func marginsKeepGradation() {
        let mapping = ExposureSignalMapping(curve: curve, clipNative: 180)
        // Native 0 → plot bottom; native 255 → plot top.
        #expect(ScopeDisplayScale.waveformLevel(signalNative: 0, mapping: mapping) == 0)
        #expect(ScopeDisplayScale.waveformLevel(signalNative: 255, mapping: mapping) == 1)
        // Strictly increasing across the full range — no flat spots that hide detail.
        var previous = -1.0
        for native in stride(from: 0.0, through: 255.0, by: 1) {
            let level = ScopeDisplayScale.waveformLevel(signalNative: native, mapping: mapping)
            #expect(level > previous)
            previous = level
        }
    }

    @Test("Middle grey never moves — not with ISO, not with any exposure change")
    func middleGrayIsImmovable() {
        let fixed = ScopeDisplayScale.middleGrayLevel(curve: curve)
        for clip in [145.0, 160.0, 180.0, 200.0, 215.0] {
            let mapping = ExposureSignalMapping(curve: curve, clipNative: clip)
            // The guide position is mapping-independent…
            #expect(ScopeDisplayScale.middleGrayLevel(mapping: mapping) == fixed)
            // …and the TRACE's mid-grey code plots exactly on it for every mapping, so the
            // signal's mid grey sits still while ISO re-stretches only the highlights.
            #expect(
                abs(
                    ScopeDisplayScale.waveformLevel(
                        signalNative: curve.middleGrayNativeCode, mapping: mapping) - fixed)
                    < 1e-9)
        }
        // Shadows below mid grey are pinned too: their level is identical across mappings.
        // (Mid grey itself is native ≈84.99998, so 84 is the highest strictly-below sample.)
        let low = ExposureSignalMapping(curve: curve, clipNative: 145)
        let high = ExposureSignalMapping(curve: curve, clipNative: 215)
        for native in [30.0, 50.0, 70.0, 84.0] {
            #expect(
                ScopeDisplayScale.waveformLevel(signalNative: native, mapping: low)
                    == ScopeDisplayScale.waveformLevel(signalNative: native, mapping: high))
        }
    }

    @Test("Histogram redistributes onto the anchored axis, conserving counts")
    func histogramRemap() {
        let mapping = ExposureSignalMapping(curve: curve, clipNative: 180)
        var histogram = [Int](repeating: 0, count: 256)
        let floor = Int(ScopeDisplayScale.logBlackFloorCode(curve: curve).rounded())
        histogram[floor] = 4
        histogram[180] = 3
        histogram[255] = 2
        let display = ScopeDisplayScale.remapHistogram(histogram, mapping: mapping)
        #expect(display[Int((0.05 * 255).rounded())] >= 4)
        #expect(display[Int((0.95 * 255).rounded())] >= 3)
        #expect(display[255] == 2)
        #expect(display.reduce(0, +) == 9)
    }
}
