import Testing

@testable import OpenZCineCore

@Suite("Scope sampler")
struct ScopeSamplerTests {
    @Test("A white frame fills the top luma and channel bins")
    func whiteFrame() {
        let rgba = [UInt8](repeating: 255, count: 2 * 2 * 4)
        let samples = ScopeSampler.sample(
            rgba: rgba, width: 2, height: 2, bytesPerRow: 8, stride: 1)
        #expect(samples.histogramLuma[255] == 4)
        #expect(samples.histogramRed[255] == 4)
        #expect(samples.histogramGreen[255] == 4)
        #expect(samples.histogramBlue[255] == 4)
        #expect(samples.histogramLuma.reduce(0, +) == 4)
        #expect(samples.points.count == 4)
        #expect(samples.points.allSatisfy { $0.luma == 255 })
        // x positions are 0 and 0.5 across a 2-wide frame.
        #expect(samples.points.map(\.xRatio).sorted() == [0, 0, 0.5, 0.5])
    }

    @Test("A black pixel lands in the zero bins")
    func blackPixel() {
        let rgba: [UInt8] = [0, 0, 0, 255]
        let samples = ScopeSampler.sample(
            rgba: rgba, width: 1, height: 1, bytesPerRow: 4, stride: 1)
        #expect(samples.histogramLuma[0] == 1)
        #expect(samples.points.count == 1)
        #expect(samples.points[0].xRatio == 0)
        #expect(samples.points[0].luma == 0)
    }

    @Test("Mid grey floors to its code value")
    func midGrey() {
        let rgba: [UInt8] = [128, 128, 128, 255]
        let samples = ScopeSampler.sample(
            rgba: rgba, width: 1, height: 1, bytesPerRow: 4, stride: 1)
        #expect(samples.histogramLuma[128] == 1)
    }

    @Test("Stride skips pixels")
    func strideSkips() {
        // 4×1 frame, stride 2 → samples columns 0 and 2 only.
        let rgba = [UInt8](repeating: 200, count: 4 * 1 * 4)
        let samples = ScopeSampler.sample(
            rgba: rgba, width: 4, height: 1, bytesPerRow: 16, stride: 2)
        #expect(samples.points.count == 2)
        #expect(samples.histogramLuma.reduce(0, +) == 2)
    }

    @Test("Channels are read independently")
    func channels() {
        // One pure-red pixel: R=255, G=B=0.
        let rgba: [UInt8] = [255, 0, 0, 255]
        let samples = ScopeSampler.sample(
            rgba: rgba, width: 1, height: 1, bytesPerRow: 4, stride: 1)
        #expect(samples.histogramRed[255] == 1)
        #expect(samples.histogramGreen[0] == 1)
        #expect(samples.histogramBlue[0] == 1)
        // Luma of pure red = 0.2126*255 = 54.2 → floored 54.
        #expect(samples.histogramLuma[54] == 1)
    }

    @Test("Histogram-only sampling omits scatter points")
    func histogramOnlyOmitsPoints() {
        let rgba = [UInt8](repeating: 255, count: 2 * 2 * 4)
        let samples = ScopeSampler.sample(
            rgba: rgba, width: 2, height: 2, bytesPerRow: 8, stride: 1, includePoints: false)
        #expect(samples.points.isEmpty)
        #expect(samples.histogramLuma[255] == 4)
    }

    @Test("Invalid input returns empty samples")
    func invalid() {
        #expect(ScopeSampler.sample(rgba: [], width: 0, height: 0, bytesPerRow: 0).points.isEmpty)
        // Buffer too small for the declared geometry.
        let tiny: [UInt8] = [0, 0, 0, 255]
        let samples = ScopeSampler.sample(rgba: tiny, width: 4, height: 4, bytesPerRow: 16)
        #expect(samples.points.isEmpty)
    }

    @Test("Traffic-light edges align with the waveform's anchored safe-border lines")
    func trafficEdgesMatchAnchoredAxis() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let floor = ScopeSampler.trafficCrushFloor(mapping: mapping)
        let clip = ScopeSampler.trafficClipEdge(mapping: mapping)
        // The detection edges sit at (or just inside) the codes the display anchors to the lines.
        #expect(
            ScopeDisplayScale.waveformLevel(signalNative: Double(floor), mapping: mapping)
                <= ScopeDisplayScale.crushLineLevel + 0.05)
        #expect(
            ScopeDisplayScale.waveformLevel(signalNative: Double(clip), mapping: mapping)
                >= ScopeDisplayScale.clipLineLevel - 0.05)
    }

    @Test("Traffic lights fire when a channel piles up at the clip or crush edge")
    func trafficLights() {
        func histogram(at bin: Int, count: Int = 1000) -> [Int] {
            var h = [Int](repeating: 0, count: 256)
            h[bin] = count
            return h
        }
        let mid = histogram(at: 128)
        // A red channel pinned to white clips (red light on the clip side only).
        let clippedRed = ScopeSampler.trafficLights(
            red: histogram(at: 255), green: mid, blue: mid, curve: .redLog3G10)
        #expect(clippedRed.clipRed)
        #expect(!clippedRed.crushRed)
        #expect(!clippedRed.clipGreen)
        // A blue channel pinned to the log toe floor crushes.
        let toeFloor = ScopeSampler.trafficCrushFloor(curve: .redLog3G10)
        let crushedBlue = ScopeSampler.trafficLights(
            red: mid, green: mid, blue: histogram(at: toeFloor), curve: .redLog3G10)
        #expect(crushedBlue.crushBlue)
        #expect(!crushedBlue.clipBlue)
        // Legal black (studio swing 16) is a valid shadow, not crush.
        let legalBlack = ScopeSampler.trafficLights(
            red: mid, green: mid, blue: histogram(at: 16), curve: .redLog3G10)
        #expect(!legalBlack.crushBlue)
        // Mid-tones light nothing.
        let clean = ScopeSampler.trafficLights(red: mid, green: mid, blue: mid, curve: .redLog3G10)
        #expect(clean == .none)
    }

    @Test("Crush band sits at the log toe floor, not native 0 or legal black")
    func crushBandPlacement() {
        let floor = ScopeSampler.trafficCrushFloor(curve: .redLog3G10)
        let edge = ScopeSampler.trafficCrushEdge(curve: .redLog3G10)
        #expect(floor > Int(StudioSwing.legalBlackNative))
        #expect(edge >= floor)
        #expect(edge - floor <= 8, "crush band should be a narrow tolerance above the toe floor")
    }

    @Test("Crush fires at the log black floor, not only at native 0")
    func crushFiresAtLogFloor() {
        // The actual bug: a log feed never sends native 0 — its blackest pixel is the toe floor
        // (signalNative(referenceIRE: 0) = blackIRE × 2.55 ≈ native 23, Log3G10's encode of zero
        // light). A pile-up there is a crushed shadow and must light crush; earlier the crush edge
        // sat at native 0, so it never fired.
        func histogram(at bin: Int, count: Int = 1000) -> [Int] {
            var h = [Int](repeating: 0, count: 256)
            h[bin] = count
            return h
        }
        let mid = histogram(at: 128)
        for curve in [ExposureToneCurve.redLog3G10, .nikonNLog] {
            let floor = Int(ExposureScale.signalNative(referenceIRE: 0, curve: curve).rounded())
            #expect(floor > 10, "log floor should be well above native 0")
            let lit = ScopeSampler.trafficLights(
                red: mid, green: mid, blue: histogram(at: floor), curve: curve)
            #expect(lit.crushBlue, "pile-up at the \(curve) black floor must light crush")
            #expect(!lit.clipBlue)
        }
    }

    @Test("Traffic lights respect an explicit edge-energy threshold")
    func trafficThreshold() {
        var justOver = [Int](repeating: 0, count: 256)
        justOver[128] = 9930
        justOver[255] = 70  // 0.7% clipped → fires at 0.6%
        #expect(
            ScopeSampler.trafficLights(
                red: justOver, green: justOver, blue: justOver, curve: .redLog3G10,
                threshold: 0.006
            ).clipRed)
        var justUnder = [Int](repeating: 0, count: 256)
        justUnder[128] = 9950
        justUnder[255] = 50  // 0.5% clipped → quiet at 0.6%
        #expect(
            !ScopeSampler.trafficLights(
                red: justUnder, green: justUnder, blue: justUnder, curve: .redLog3G10,
                threshold: 0.006
            ).clipRed)
    }

    @Test("Crush/clip compensation maps quarter-stop options to pixel fractions")
    func crushClipCompensationStops() {
        let expected: [(AssistConfiguration.CrushClipCompensation, Double)] = [
            (.zero, 0.0), (.quarter, 0.25), (.half, 0.5), (.threeQuarter, 0.75), (.one, 1.0),
        ]
        for (compensation, stops) in expected {
            #expect(compensation.stops == stops)
            #expect(abs(compensation.pixelFractionThreshold - stops / 10) < 1e-12)
        }
        // 1.0 stop (10%): strictly above threshold fires; at or below stays quiet.
        var aboveThreshold = [Int](repeating: 0, count: 256)
        aboveThreshold[128] = 8990
        aboveThreshold[255] = 1010  // 10.1%
        #expect(
            ScopeSampler.trafficLights(
                red: aboveThreshold, green: aboveThreshold, blue: aboveThreshold,
                curve: .redLog3G10, threshold: 0.10
            ).clipRed)
        var below = [Int](repeating: 0, count: 256)
        below[128] = 9100
        below[255] = 900  // 9.0%
        #expect(
            !ScopeSampler.trafficLights(
                red: below, green: below, blue: below, curve: .redLog3G10, threshold: 0.10
            ).clipRed)
    }

    @Test("Point median matches full sort for odd and even counts")
    func medianWaveformLevelPoints() {
        let curve = ExposureToneCurve.redLog3G10
        let natives = [16, 40, 55, 128, 200, 255]
        let points = natives.enumerated().map { index, native in
            ScopePoint(
                xRatio: Double(index) / Double(natives.count), red: UInt8(native),
                green: UInt8(native), blue: UInt8(native), luma: UInt8(native))
        }
        let median = ScopeSampler.medianWaveformLevel(
            points: points, curve: curve, channel: { $0.red })
        let sortedLevels = natives.map {
            ScopeDisplayScale.waveformLevel(signalNative: Double($0), curve: curve)
        }.sorted()
        let expected = (sortedLevels[2] + sortedLevels[3]) / 2
        #expect(abs(median - expected) < 0.0001)
    }

    @Test("Histogram median lands on the middle native bin")
    func medianWaveformLevelHistogram() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[40] = 50
        histogram[200] = 50
        let median = ScopeSampler.medianWaveformLevel(histogram: histogram, curve: .redLog3G10)
        let expected = ScopeDisplayScale.waveformLevel(signalNative: 40, curve: .redLog3G10)
        #expect(abs(median - expected) < 0.0001)
    }
}
