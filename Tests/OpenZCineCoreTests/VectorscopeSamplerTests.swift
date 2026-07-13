import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Vectorscope chroma conversion")
struct VectorscopeChromaTests {
    @Test func neutralsCarryNoChroma() {
        for value in [UInt8(0), 18, 128, 255] {
            let (cb, cr) = VectorscopeSampler.chroma(red: value, green: value, blue: value)
            #expect(abs(cb) < 1e-9)
            #expect(abs(cr) < 1e-9)
        }
    }

    @Test func primariesLandAtBT709Positions() {
        // Pure red: Y = 0.2126, Cb = (0 − Y)/1.8556, Cr = (1 − Y)/1.5748 = +0.5 exactly.
        let red = VectorscopeSampler.chroma(red: 255, green: 0, blue: 0)
        #expect(abs(red.cr - 0.5) < 1e-9)
        #expect(abs(red.cb - (-0.2126 / 1.8556)) < 1e-9)
        // Pure blue: Cb = +0.5 exactly.
        let blue = VectorscopeSampler.chroma(red: 0, green: 0, blue: 255)
        #expect(abs(blue.cb - 0.5) < 1e-9)
        #expect(abs(blue.cr - (-0.0722 / 1.5748)) < 1e-9)
        // Yellow (R+G) is blue's Cb opposite: Cb = −0.5 exactly.
        let yellow = VectorscopeSampler.chroma(red: 255, green: 255, blue: 0)
        #expect(abs(yellow.cb - (-0.5)) < 1e-9)
    }

    @Test func complementaryColorsMirrorThroughCentre() {
        let green = VectorscopeSampler.chroma(red: 0, green: 255, blue: 0)
        let magenta = VectorscopeSampler.chroma(red: 255, green: 0, blue: 255)
        #expect(abs(green.cb + magenta.cb) < 1e-9)
        #expect(abs(green.cr + magenta.cr) < 1e-9)
    }

    @Test func chromaComponentsStayInHalfRange() {
        for (r, g, b): (UInt8, UInt8, UInt8) in [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (255, 255, 0), (0, 255, 255), (255, 0, 255),
        ] {
            let (cb, cr) = VectorscopeSampler.chroma(red: r, green: g, blue: b)
            #expect(cb >= -0.5 && cb <= 0.5)
            #expect(cr >= -0.5 && cr <= 0.5)
        }
    }

    @Test func smpte75PercentBarsLandAtIndependentRec709Targets() {
        // SMPTE RP 219's 75% bars use 191/255 channel amplitude. Expected BT.709 Cb/Cr values are
        // fixed here independently so a matrix, orientation, or scale regression cannot move both
        // the trace and its graticule together while keeping a tautological test green.
        let bars: [(rgb: (UInt8, UInt8, UInt8), cb: Double, cr: Double)] = [
            ((191, 191, 0), -0.374_509_804, 0.034_340_371),
            ((0, 191, 191), 0.085_816_754, -0.374_509_804),
            ((0, 191, 0), -0.288_693_050, -0.340_169_433),
            ((191, 0, 191), 0.288_693_050, 0.340_169_433),
            ((191, 0, 0), -0.085_816_754, 0.374_509_804),
            ((0, 0, 191), 0.374_509_804, -0.034_340_371),
        ]
        for bar in bars {
            let actual = VectorscopeSampler.chroma(
                red: bar.rgb.0, green: bar.rgb.1, blue: bar.rgb.2)
            #expect(abs(actual.cb - bar.cb) < 0.000_000_001)
            #expect(abs(actual.cr - bar.cr) < 0.000_000_001)
        }
    }

    @Test func cubeTrilinearSampleMatchesLatticeAndInterpolates() {
        // Identity 2³ cube: every input returns itself.
        let identity = CubeLUT(
            size: 2,
            rgb: [
                0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0,
                0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1,
            ])
        for value: Float in [0, 0.25, 0.5, 1] {
            let out = identity.map(red: value, green: value, blue: value)
            #expect(abs(out.red - value) < 1e-6)
            #expect(abs(out.green - value) < 1e-6)
            #expect(abs(out.blue - value) < 1e-6)
        }
        // Out-of-domain inputs clamp instead of reading out of bounds.
        let clamped = identity.map(red: -1, green: 2, blue: 0.5)
        #expect(clamped.red == 0)
        #expect(clamped.green == 1)
        #expect(abs(clamped.blue - 0.5) < 1e-6)
    }

    @Test func monitorPointsPushNeutralLogRampThroughTheLookAndStayNeutral() {
        let cube = MonitorLUT.log3G10Rec709.cube()
        let ramp = stride(from: 40, through: 240, by: 40).map { value in
            ScopePoint(
                xRatio: 0, red: UInt8(value), green: UInt8(value), blue: UInt8(value),
                luma: UInt8(value))
        }
        let monitor = VectorscopeSampler.monitorPoints(ramp, through: cube)
        #expect(monitor.count == ramp.count)
        for point in monitor {
            // Neutral in → neutral out (within cube quantization), so the trace stays centred.
            let spread =
                Int(max(point.red, max(point.green, point.blue)))
                - Int(min(point.red, min(point.green, point.blue)))
            #expect(spread <= 2)
        }
        // The tone map is not the identity: mid grey moves off its log code.
        let midIn = ScopePoint(xRatio: 0, red: 85, green: 85, blue: 85, luma: 85)
        let midOut = VectorscopeSampler.monitorPoints([midIn], through: cube)[0]
        #expect(midOut.red != 85)
    }

    @Test func liveCurveResolutionRequiresPositiveSignalIdentity() {
        #expect(ExposureToneCurve.verifiedForCameraSignal("R3D NE") == .redLog3G10)
        #expect(ExposureToneCurve.verifiedForCameraSignal("RED Log3G10") == .redLog3G10)
        #expect(ExposureToneCurve.verifiedForCameraSignal("N-Log") == .nikonNLog)
        #expect(ExposureToneCurve.verifiedForCameraSignal("NLOG 10-bit") == .nikonNLog)
        for ambiguous in ["N-RAW", "ProRes RAW HQ", "ProRes 422 HQ", "H.265 10-bit", "HLG", ""] {
            #expect(ExposureToneCurve.verifiedForCameraSignal(ambiguous) == nil)
        }
    }
}

@Suite("Vectorscope bin accumulation")
struct VectorscopeAccumulateTests {
    private func point(red: UInt8, green: UInt8, blue: UInt8) -> ScopePoint {
        ScopePoint(xRatio: 0, red: red, green: green, blue: blue, luma: 0)
    }

    @Test func neutralPixelsPileIntoTheCentreBin() {
        let points = Array(repeating: point(red: 128, green: 128, blue: 128), count: 5)
        let bins = VectorscopeSampler.accumulate(points: points, binCount: 128)
        #expect(bins.binCount == 128)
        #expect(bins.counts.count == 128 * 128)
        #expect(bins.peak == 5)
        // Neutral chroma (0, 0) maps to (0.5, 0.5) → bin round(0.5 × 127) = 64 on both axes.
        #expect(bins.counts[64 * 128 + 64] == 5)
        #expect(bins.counts.reduce(0) { $0 + Int($1) } == 5)
    }

    @Test func pureBlueLandsOnThePositiveCbEdge() {
        let bins = VectorscopeSampler.accumulate(
            points: [point(red: 0, green: 0, blue: 255)], binCount: 128)
        // Cb = +0.5 → x = 1 → column 127; Cr slightly negative → row just below centre.
        let expectedRow = Int(((-0.0722 / 1.5748) + 0.5) * 127).advanced(by: 0)
        let hit = bins.counts.firstIndex(of: 1)
        #expect(hit != nil)
        if let hit {
            #expect(hit % 128 == 127)
            #expect(abs(hit / 128 - expectedRow) <= 1)
        }
    }

    @Test func smpte75PercentBarsHitExpected128BinCoordinates() throws {
        let bars: [(point: ScopePoint, column: Int, row: Int)] = [
            (point(red: 191, green: 0, blue: 0), 53, 111),
            (point(red: 191, green: 0, blue: 191), 100, 107),
            (point(red: 0, green: 0, blue: 191), 111, 59),
            (point(red: 0, green: 191, blue: 191), 74, 16),
            (point(red: 0, green: 191, blue: 0), 27, 20),
            (point(red: 191, green: 191, blue: 0), 16, 68),
        ]
        for bar in bars {
            let bins = VectorscopeSampler.accumulate(points: [bar.point], binCount: 128)
            let index = try #require(bins.counts.firstIndex(of: 1))
            #expect(index % 128 == bar.column)
            #expect(index / 128 == bar.row)
        }
    }

    @Test func gainMagnifiesTheTraceAndClipsOvershoot() {
        // A subtle chroma offset doubles its distance from centre at 2x gain.
        let subtle = point(red: 140, green: 128, blue: 128)
        let unity = VectorscopeSampler.accumulate(points: [subtle], binCount: 128)
        let zoomed = VectorscopeSampler.accumulate(points: [subtle], binCount: 128, gain: 2)
        let unityIndex = unity.counts.firstIndex(of: 1)!
        let zoomedIndex = zoomed.counts.firstIndex(of: 1)!
        let unityOffset = Double(unityIndex % 128) - 63.5
        let zoomedOffset = Double(zoomedIndex % 128) - 63.5
        #expect(abs(zoomedOffset - 2 * unityOffset) <= 1.5)
        // Saturated chroma at 2x overshoots the plot and is dropped, not edge-clamped.
        let saturated = VectorscopeSampler.accumulate(
            points: [point(red: 255, green: 0, blue: 0)], binCount: 128, gain: 2)
        #expect(saturated.counts.allSatisfy { $0 == 0 })
    }

    @Test func binsRetainAverageTraceColour() throws {
        let bins = VectorscopeSampler.accumulate(
            points: Array(repeating: point(red: 255, green: 0, blue: 0), count: 3),
            binCount: 128)
        let index = try #require(bins.counts.firstIndex(of: 3))
        let average = bins.averageColor(at: index)
        #expect(abs(average.red - 1) < 0.000_001)
        #expect(average.green == 0)
        #expect(average.blue == 0)
        let tint = average.traceTint
        #expect(tint.red == 1)
        #expect(tint.green == 0)
        #expect(tint.blue == 0)
    }

    @Test func neutralBinUsesWhiteTraceTint() throws {
        let bins = VectorscopeSampler.accumulate(
            points: [point(red: 32, green: 32, blue: 32)], binCount: 128)
        let index = try #require(bins.counts.firstIndex(of: 1))
        let tint = bins.averageColor(at: index).traceTint
        #expect(tint == VectorscopeColor(red: 1, green: 1, blue: 1))
    }

    @Test func emptyInputsProduceEmptyBins() {
        #expect(VectorscopeSampler.accumulate(points: [], binCount: 128) == .empty)
        #expect(
            VectorscopeSampler.accumulate(
                points: [point(red: 1, green: 2, blue: 3)], binCount: 0) == .empty)
        #expect(
            VectorscopeSampler.accumulate(
                points: [point(red: 1, green: 2, blue: 3)], binCount: .max) == .empty)
        #expect(
            VectorscopeSampler.accumulate(
                points: [point(red: 1, green: 2, blue: 3)],
                binCount: VectorscopeBins.maximumBinCount + 1) == .empty)
        #expect(VectorscopeBins.empty.peak == 0)
    }

    @Test func malformedBinGridsNormalizeToEmpty() {
        #expect(VectorscopeBins(binCount: -1, counts: []) == .empty)
        #expect(VectorscopeBins(binCount: .max, counts: []) == .empty)
        #expect(
            VectorscopeBins(
                binCount: VectorscopeBins.maximumBinCount + 1, counts: []) == .empty)
        #expect(VectorscopeBins(binCount: 2, counts: [1, 2, 3]) == .empty)
        #expect(
            VectorscopeBins(
                binCount: 2, counts: [1, 2, 3, 4], redSums: [1, 2, 3],
                greenSums: [1, 2, 3, 4], blueSums: [1, 2, 3, 4]) == .empty)
    }

    @Test func densityOnlyCompatibilityInitializerPreservesValidGrid() {
        let bins = VectorscopeBins(binCount: 2, counts: [0, 2, 1, 0])
        #expect(bins.binCount == 2)
        #expect(bins.counts == [0, 2, 1, 0])
        #expect(bins.peak == 2)
        #expect(bins.averageColor(at: 1) == .black)
        #expect(bins.averageColor(at: 1).traceTint == VectorscopeColor(red: 1, green: 1, blue: 1))
    }
}

@Suite("Vectorscope settings decoding")
struct VectorscopeSettingsDecodeTests {
    @Test func scopesBlobWithoutVectorscopeKeysDecodesWithDefaults() throws {
        // A configuration saved before the vectorscope existed must still load, keeping its own
        // values and defaulting the new ones.
        let legacy = #"{"waveformScale":1.2}"#
        let scopes = try JSONDecoder().decode(
            AssistConfiguration.Scopes.self, from: Data(legacy.utf8))
        #expect(scopes.vectorscopeScale == AssistConfiguration.Scopes.defaultScale)
        #expect(scopes.vectorscopeZoom == .x1)
        #expect(scopes.vectorscopeBrightness == AssistConfiguration.Scopes.defaultBrightness)
        #expect(scopes.waveformScale == 1.2)
    }

    @Test func zoomSelectionRoundTrips() throws {
        var scopes = AssistConfiguration.Scopes()
        scopes.vectorscopeZoom = .x4
        let encoded = try JSONEncoder().encode(scopes)
        let decoded = try JSONDecoder().decode(
            AssistConfiguration.Scopes.self, from: encoded)
        #expect(decoded.vectorscopeZoom == .x4)
    }

    @Test func retiredSourceSelectionKeyIsIgnoredWithoutDiscardingTheScopesBlob() throws {
        // Blobs saved while the vectorscope had a Monitor/Source selection carry the retired key;
        // it is skipped and every remaining setting keeps its saved value.
        let legacy =
            #"{"vectorscopeSource":"Monitor","vectorscopeZoom":"4x","paradeMode":"YRGB","vectorscopeBrightness":137}"#
        let scopes = try JSONDecoder().decode(
            AssistConfiguration.Scopes.self, from: Data(legacy.utf8))
        #expect(scopes.vectorscopeZoom == .x4)
        #expect(scopes.paradeMode == .yrgb)
        #expect(scopes.vectorscopeBrightness == 137)
    }
}
