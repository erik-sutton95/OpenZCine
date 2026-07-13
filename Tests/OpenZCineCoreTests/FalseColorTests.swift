import Foundation
import Testing

@testable import OpenZCineCore

@Suite("False colour mapping")
struct FalseColorTests {
    @Test("RGB is decoded before source-gamut luminance weighting")
    func sourceLinearLuminance() {
        let red = ExposureToneCurve.redLog3G10
        let redMiddleGray = red.encode(linearLight: 0.18)
        #expect(
            abs(
                FalseColorMap.linearLuminance(
                    red: redMiddleGray, green: redMiddleGray, blue: redMiddleGray, curve: red)
                    - 0.18) < 0.00001)

        let nLog = ExposureToneCurve.nikonNLog
        let nLogMiddleGray = nLog.encode(linearLight: 0.18)
        #expect(
            abs(
                FalseColorMap.linearLuminance(
                    red: nLogMiddleGray, green: nLogMiddleGray, blue: nLogMiddleGray,
                    curve: nLog) - 0.18) < 0.00001)

        let encoded = (red: 0.31, green: 0.42, blue: 0.53)
        let expected =
            0.286694 * red.decode(encodedValue: encoded.red)
            + 0.842979 * red.decode(encodedValue: encoded.green)
            - 0.129673 * red.decode(encodedValue: encoded.blue)
        #expect(
            abs(
                FalseColorMap.linearLuminance(
                    red: encoded.red, green: encoded.green, blue: encoded.blue, curve: red)
                    - expected) < 0.0000001)
    }

    @Test("ZC Stops exposes the RED ONE-style exposure landmarks")
    func stopLegend() {
        #expect(
            FalseColorScale.stops.legendStops.map(\.label)
                == [
                    "Minimum", "−3", "18%", "Skin +1", "+2",
                    "⅔ below max", "⅓ below max", "Maximum",
                ])
        #expect(FalseColorScale.stops.bands.count == 8)
    }

    @Test("ZC Stops uses the supplied RED ONE-style colour progression")
    func stopPaletteProgression() {
        let expectedRGB255: [(Double, Double, Double)] = [
            (78, 11, 82), (17, 149, 141), (8, 203, 24), (245, 143, 148),
            (212, 208, 13), (255, 244, 0), (255, 126, 18), (250, 60, 36),
        ]
        for (band, expected) in zip(FalseColorScale.stops.bands, expectedRGB255) {
            #expect(abs(band.red - expected.0 / 255) < 0.0001)
            #expect(abs(band.green - expected.1 / 255) < 0.0001)
            #expect(abs(band.blue - expected.2 / 255) < 0.0001)
        }
    }

    @Test("Landmarks stay stop-relative while maximum warnings follow camera clip")
    func stopLandmarksMapForBothCurves() throws {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            for stop in -6...5 {
                let encoded = curve.encode(linearLight: 0.18 * pow(2, Double(stop)))
                let value = FalseColorMap.exposureValue(
                    red: encoded, green: encoded, blue: encoded,
                    scale: .stops, curve: curve)
                #expect(abs(value - Double(stop)) < 0.0001)
            }

            let bands = FalseColorScale.stops.bands(mapping: mapping)
            #expect(FalseColorMap.band(value: -8, scale: .stops, mapping: mapping) == bands[0])
            #expect(FalseColorMap.band(value: -3, scale: .stops, mapping: mapping) == bands[1])
            #expect(FalseColorMap.band(value: 0, scale: .stops, mapping: mapping) == bands[2])
            #expect(FalseColorMap.band(value: 1, scale: .stops, mapping: mapping) == bands[3])
            #expect(FalseColorMap.band(value: 2, scale: .stops, mapping: mapping) == bands[4])
            #expect(FalseColorMap.band(value: -2, scale: .stops, mapping: mapping) == nil)

            let maximum = FalseColorMap.maximumSceneStop(mapping: mapping)
            #expect(
                FalseColorMap.band(
                    value: maximum - 2.0 / 3, scale: .stops, mapping: mapping) == bands[5])
            #expect(
                FalseColorMap.band(
                    value: maximum - 1.0 / 3, scale: .stops, mapping: mapping) == bands[6])
            #expect(
                FalseColorMap.band(value: maximum, scale: .stops, mapping: mapping) == bands[7])
        }
    }

    @Test("ZC Stops retains scene detail inside one exposure zone")
    func zcStopsRetainsSceneDetail() {
        let curve = ExposureToneCurve.redLog3G10
        let darker = curve.encode(linearLight: 0.18 * pow(2, -0.1))
        let brighter = curve.encode(linearLight: 0.18 * pow(2, 0.1))
        let darkOutput = FalseColorMap.mappedColor(
            red: darker, green: darker, blue: darker,
            scale: .stops, curve: curve)
        let brightOutput = FalseColorMap.mappedColor(
            red: brighter, green: brighter, blue: brighter,
            scale: .stops, curve: curve)

        #expect(brightOutput.red > darkOutput.red)
        #expect(brightOutput.green > darkOutput.green)
        #expect(brightOutput.blue > darkOutput.blue)
        #expect(darkOutput.green > darkOutput.red + 0.1)
        #expect(darkOutput.green > darkOutput.blue + 0.1)
        #expect(brightOutput.green > brightOutput.red + 0.1)
        #expect(brightOutput.green > brightOutput.blue + 0.1)
    }

    @Test("ZC Stops feathers landmark edges into luminance grayscale")
    func zcStopsTransitionsAreSmooth() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let boundaryStop = 1.0 / 6
        let linear = 0.18 * pow(2, boundaryStop)
        let encoded = mapping.curve.encode(linearLight: linear)
        let boundary = FalseColorMap.mappedColor(
            red: encoded, green: encoded, blue: encoded,
            scale: .stops, mapping: mapping)
        let detail = MonitorDisplayToneMap(mapping: mapping).displayCode(sceneLinear: linear)
        let colorWeight = 1 - FalseColorMap.zcStopsDetailBlend
        let middleGrey = (8.0 / 255, 203.0 / 255, 24.0 / 255)
        let painted = (
            middleGrey.0 * colorWeight + detail * FalseColorMap.zcStopsDetailBlend,
            middleGrey.1 * colorWeight + detail * FalseColorMap.zcStopsDetailBlend,
            middleGrey.2 * colorWeight + detail * FalseColorMap.zcStopsDetailBlend
        )
        let expected = (
            (painted.0 + detail) * 0.5,
            (painted.1 + detail) * 0.5,
            (painted.2 + detail) * 0.5
        )
        #expect(abs(boundary.red - expected.0) < 0.001)
        #expect(abs(boundary.green - expected.1) < 0.001)
        #expect(abs(boundary.blue - expected.2) < 0.001)
    }

    @Test("ZC Stops renders unmarked exposure values as display luminance")
    func zcStopsGapsAreGrayscale() {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let linear = 0.18 / 4
            let encoded = curve.encode(linearLight: linear)
            let output = FalseColorMap.mappedColor(
                red: encoded, green: encoded, blue: encoded,
                scale: .stops, mapping: mapping)
            let expected = MonitorDisplayToneMap(mapping: mapping).displayCode(sceneLinear: linear)
            expectColor(output, equals: (expected, expected, expected), tolerance: 0.0001)
        }
    }

    @Test("IRE uses RED Video Mode integer ranges")
    func ireLegendAndBands() throws {
        #expect(
            FalseColorScale.ire.legendStops.map(\.label)
                == [
                    "0–4", "5", "10–12", "41–48", "61–70", "92–93", "94–95",
                    "96–98", "99–100",
                ])
        #expect(FalseColorScale.ire.bands.count == 9)

        let expectedBounds: [(Double, Double)] = [
            (0, 5), (5, 6), (10, 13), (41, 49), (61, 71),
            (92, 94), (94, 96), (96, 99), (99, .infinity),
        ]
        for (band, expected) in zip(FalseColorScale.ire.bands, expectedBounds) {
            #expect(band.lowerBound == expected.0)
            #expect(band.upperBound == expected.1)
        }

        #expect(FalseColorMap.band(value: 7, scale: .ire) == nil)
        #expect(FalseColorMap.band(value: 20, scale: .ire) == nil)
        #expect(FalseColorMap.band(value: 55, scale: .ire) == nil)
        #expect(FalseColorMap.band(value: 80, scale: .ire) == nil)
        let red = try #require(FalseColorMap.band(value: 100.1, scale: .ire))
        #expect((red.red, red.green, red.blue) == (0.78, 0.28, 0.18))
    }

    @Test("Monitor IRE anchors grey and clip identically for both curves")
    func ireAnchorsForBothCurves() {
        let mappings = [
            ExposureSignalMapping(curve: .redLog3G10),
            ExposureSignalMapping(curve: .redLog3G10, clipNative: 145),
            ExposureSignalMapping(curve: .nikonNLog),
            ExposureSignalMapping(curve: .nikonNLog, clipNative: 200),
        ]
        for mapping in mappings {
            let black = FalseColorMap.exposureValue(
                linearLuminance: 0, scale: .ire, mapping: mapping)
            let middle = FalseColorMap.exposureValue(
                linearLuminance: 0.18, scale: .ire, mapping: mapping)
            let clipLinear = mapping.curve.decode(encodedValue: mapping.clipNative / 255)
            let clip = FalseColorMap.exposureValue(
                linearLuminance: clipLinear, scale: .ire, mapping: mapping)
            #expect(abs(black) < 0.0001)
            #expect(abs(middle - 42) < 0.0001)
            #expect(abs(clip - 100) < 0.0001)
            #expect(FalseColorMap.band(value: middle, scale: .ire, mapping: mapping) != nil)
        }
    }

    @Test("IRE colours resolve through Log3G10 and N-Log")
    func ireColorsForBothCurves() {
        let samples: [(ire: Double, color: (Double, Double, Double))] = [
            (2, (0.44, 0.22, 0.76)),
            (5.5, (0.28, 0.37, 0.85)),
            (11.5, (0.18, 0.58, 0.64)),
            (45, (0.38, 0.63, 0.35)),
            (66, (0.83, 0.53, 0.71)),
            (93, (0.83, 0.77, 0.45)),
            (95, (0.89, 0.72, 0.29)),
            (97.5, (0.85, 0.55, 0.22)),
            (100, (0.78, 0.28, 0.18)),
        ]
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            for sample in samples {
                let encoded = encoded(monitorIRE: sample.ire, mapping: mapping)
                let output = FalseColorMap.mappedColor(
                    red: encoded, green: encoded, blue: encoded,
                    scale: .ire, mapping: mapping)
                expectColor(output, equals: sample.color, tolerance: 0.002)
            }
        }
    }

    @Test("IRE gaps show display-referred luminance")
    func ireMonochromeGaps() {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let encoded = encoded(monitorIRE: 20, mapping: mapping)
            let output = FalseColorMap.mappedColor(
                red: encoded, green: encoded, blue: encoded,
                scale: .ire, mapping: mapping)
            expectColor(output, equals: (0.2, 0.2, 0.2), tolerance: 0.001)
        }
    }

    @Test("IRE boundaries blend instead of creating hard contours")
    func ireTransitionsAreSmooth() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let below = mappedNeutral(monitorIRE: 93.9, scale: .ire, mapping: mapping)
        let boundary = mappedNeutral(monitorIRE: 94, scale: .ire, mapping: mapping)
        let above = mappedNeutral(monitorIRE: 94.1, scale: .ire, mapping: mapping)

        #expect(boundary.red >= min(below.red, above.red))
        #expect(boundary.red <= max(below.red, above.red))
        #expect(boundary.green >= min(below.green, above.green))
        #expect(boundary.green <= max(below.green, above.green))
        #expect(colorDistance(below, above) < 0.2)
    }

    @Test("Limits paints only crush and clip warnings")
    func limitsLegendAndBands() throws {
        #expect(
            FalseColorScale.limits.legendStops.map(\.label)
                == ["0–4", "5–9", "94–98", "99–100"])
        #expect(FalseColorScale.limits.bands.count == 4)
        #expect(FalseColorMap.band(value: 20, scale: .limits) == nil)
        #expect(FalseColorMap.band(value: 50, scale: .limits) == nil)

        let purple = try #require(FalseColorMap.band(value: 2, scale: .limits))
        let blue = try #require(FalseColorMap.band(value: 7, scale: .limits))
        let yellow = try #require(FalseColorMap.band(value: 96, scale: .limits))
        let red = try #require(FalseColorMap.band(value: 100, scale: .limits))
        #expect((purple.red, purple.green, purple.blue) == (0.44, 0.22, 0.76))
        #expect((blue.red, blue.green, blue.blue) == (0.28, 0.37, 0.85))
        #expect((yellow.red, yellow.green, yellow.blue) == (0.89, 0.72, 0.29))
        #expect((red.red, red.green, red.blue) == (0.78, 0.28, 0.18))
    }

    @Test("Limits preserves unflagged source colour for both curves")
    func limitsPreservesMidtones() {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let neutral = encoded(monitorIRE: 50, mapping: mapping)
            let source = (red: neutral + 0.005, green: neutral, blue: neutral - 0.005)
            #expect(
                FalseColorMap.band(
                    red: source.red, green: source.green, blue: source.blue,
                    scale: .limits, mapping: mapping) == nil)
            let output = FalseColorMap.mappedColor(
                red: source.red, green: source.green, blue: source.blue,
                scale: .limits, mapping: mapping)
            expectColor(output, equals: source, tolerance: 0.0000001)
        }
    }

    @Test("Limits paint clears the midrange and saturates inside the zones")
    func limitsPaintValues() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        #expect(FalseColorMap.limitsPaint(value: 50, mapping: mapping).weight == 0)
        #expect(FalseColorMap.limitsPaint(value: 20, mapping: mapping).weight == 0)
        let crush = FalseColorMap.limitsPaint(value: 2, mapping: mapping)
        #expect(crush.weight == 1)
        #expect((crush.red, crush.green, crush.blue) == (0.44, 0.22, 0.76))
        let clip = FalseColorMap.limitsPaint(value: 96, mapping: mapping)
        #expect(clip.weight == 1)
        #expect((clip.red, clip.green, clip.blue) == (0.89, 0.72, 0.29))
        // The feather across a zone boundary (the crush band ends at 10) blends smoothly
        // rather than stepping.
        let feather = FalseColorMap.limitsPaint(value: 10.2, mapping: mapping)
        #expect(feather.weight > 0 && feather.weight < 1)
    }

    @Test("Limits paint and weight cubes flag the zones and clear the midrange")
    func limitsCubes() {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let paintCube = FalseColorMap.limitsPaintCube(mapping: mapping)
            let weightCube = FalseColorMap.limitsWeightCube(mapping: mapping)
            // Mid grey composites nothing, so the graded feed shows through untouched…
            let mid = sampledNeutral(
                cube: weightCube, encoded: encoded(monitorIRE: 50, mapping: mapping))
            #expect(mid.red < 0.02)
            // …while crush and clip flag at full weight with their zone colours.
            let crushWeight = sampledNeutral(
                cube: weightCube, encoded: encoded(monitorIRE: 2, mapping: mapping))
            let clipWeight = sampledNeutral(
                cube: weightCube, encoded: encoded(monitorIRE: 96, mapping: mapping))
            #expect(crushWeight.red > 0.9)
            #expect(clipWeight.red > 0.9)
            let crushPaint = sampledNeutral(
                cube: paintCube, encoded: encoded(monitorIRE: 2, mapping: mapping))
            #expect(crushPaint.blue > crushPaint.green + 0.3)  // shadow-limit purple
            let clipPaint = sampledNeutral(
                cube: paintCube, encoded: encoded(monitorIRE: 96, mapping: mapping))
            #expect(clipPaint.red > 0.7)  // highlight-limit yellow
            #expect(clipPaint.green > 0.5)
        }
    }

    @Test("The generated IRE cube retains narrow shadow and highlight warnings")
    func ireCubeNarrowBands() {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let cube = FalseColorMap.cube(scale: .ire, mapping: mapping)
            let blue = sampledNeutral(
                cube: cube, encoded: encoded(monitorIRE: 5.5, mapping: mapping))
            let teal = sampledNeutral(
                cube: cube, encoded: encoded(monitorIRE: 11.5, mapping: mapping))
            let orange = sampledNeutral(
                cube: cube, encoded: encoded(monitorIRE: 97.5, mapping: mapping))
            let red = sampledNeutral(
                cube: cube, encoded: encoded(monitorIRE: 100, mapping: mapping))
            #expect(blue.blue > blue.red + 0.15)
            #expect(blue.blue > blue.green + 0.15)
            #expect(teal.green > teal.red + 0.15)
            #expect(teal.blue > teal.red + 0.15)
            #expect(orange.red > 0.72)
            #expect(orange.green > red.green)
            #expect(orange.blue < 0.32)
            #expect(red.red > 0.68)
            #expect(red.green < 0.4)
            #expect(red.blue < 0.3)
        }
    }

    @Test("Signal curve is inferred from the ZR codec")
    func curveSelection() {
        for codec in ["R3D NE", "R3D NE 10-bit R3D", "Log3G10"] {
            #expect(ExposureToneCurve.forCameraCodec(codec) == .redLog3G10)
        }
        for codec in [
            "N-RAW", "NRAW", "N-Log", "ProRes RAW HQ", "ProRes 422 HQ",
            "H.265 10-bit", "H265", "H.264", "",
        ] {
            #expect(ExposureToneCurve.forCameraCodec(codec) == .nikonNLog)
        }
    }

    private func encoded(monitorIRE: Double, mapping: ExposureSignalMapping) -> Double {
        let linear = linear(monitorIRE: monitorIRE, mapping: mapping)
        return mapping.curve.encode(linearLight: linear)
    }

    private func linear(monitorIRE: Double, mapping: ExposureSignalMapping) -> Double {
        if monitorIRE <= 0 { return 0 }
        if monitorIRE >= 100 {
            return mapping.curve.decode(encodedValue: mapping.clipNative / 255)
        }
        let tone = MonitorDisplayToneMap(mapping: mapping)
        var lower = 0.0
        var upper = mapping.curve.decode(encodedValue: mapping.clipNative / 255)
        for _ in 0..<80 {
            let middle = (lower + upper) * 0.5
            if tone.ire(sceneLinear: middle) < monitorIRE {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (lower + upper) * 0.5
    }

    private func mappedNeutral(
        monitorIRE: Double, scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> (red: Double, green: Double, blue: Double) {
        let value = encoded(monitorIRE: monitorIRE, mapping: mapping)
        return FalseColorMap.mappedColor(
            red: value, green: value, blue: value, scale: scale, mapping: mapping)
    }

    private func expectColor(
        _ actual: (red: Double, green: Double, blue: Double),
        equals expected: (red: Double, green: Double, blue: Double),
        tolerance: Double
    ) {
        #expect(abs(actual.red - expected.red) < tolerance)
        #expect(abs(actual.green - expected.green) < tolerance)
        #expect(abs(actual.blue - expected.blue) < tolerance)
    }

    private func colorDistance(
        _ first: (red: Double, green: Double, blue: Double),
        _ second: (red: Double, green: Double, blue: Double)
    ) -> Double {
        abs(first.red - second.red) + abs(first.green - second.green)
            + abs(first.blue - second.blue)
    }

    private func sampledNeutral(cube: CubeLUT, encoded: Double)
        -> (red: Double, green: Double, blue: Double)
    {
        let position = min(1, max(0, encoded)) * Double(cube.size - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, cube.size - 1)
        let fraction = position - Double(low)
        var output = (red: 0.0, green: 0.0, blue: 0.0)
        for b in [low, high] {
            for g in [low, high] {
                for r in [low, high] {
                    let weight = interpolationWeight(
                        r: r, g: g, b: b, low: low, high: high, fraction: fraction)
                    let index = (r + g * cube.size + b * cube.size * cube.size) * 3
                    output.red += Double(cube.rgb[index]) * weight
                    output.green += Double(cube.rgb[index + 1]) * weight
                    output.blue += Double(cube.rgb[index + 2]) * weight
                }
            }
        }
        return output
    }

    private func interpolationWeight(
        r: Int, g: Int, b: Int, low: Int, high: Int, fraction: Double
    ) -> Double {
        guard low != high else { return 0.125 }
        let axis: (Int) -> Double = { $0 == high ? fraction : 1 - fraction }
        return axis(r) * axis(g) * axis(b)
    }
}
