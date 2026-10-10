import Foundation
import OpenCineMedia
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

    @Test("CineStop exposes canonical whole-stop exposure landmarks")
    func stopLegend() {
        #expect(
            FalseColorScale.stops.legendStops.map(\.label) == [
                "crush", "shadows", "−2", "−1", "18%", "+1", "+2", "highlights", "clip",
            ])
        #expect(FalseColorScale.stops.bands.count == 9)
    }

    @Test("CineStop uses the canonical shared colour progression")
    func stopPaletteProgression() {
        let expectedRGB255: [(Double, Double, Double)] = [
            (75, 8, 165), (102, 102, 102), (39, 76, 0), (155, 196, 56),
            (127, 127, 127), (221, 174, 180), (252, 232, 96), (179, 178, 178), (245, 39, 0),
        ]
        #expect(FalseColorScale.stops.bands.count == expectedRGB255.count)
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
            // Display-referred curves clamp above their finite headroom by design — each
            // curve's landmarks are exercised across its own representable range.
            let maxStop = log2(curve.decode(encodedValue: 1) / 0.18)
            for stop in -6...5 where Double(stop) <= maxStop + 0.0001 {
                let encoded = curve.encode(linearLight: 0.18 * pow(2, Double(stop)))
                let value = FalseColorMap.exposureValue(
                    red: encoded, green: encoded, blue: encoded,
                    scale: .stops, curve: curve)
                #expect(abs(value - Double(stop)) < 0.0001)
            }

            let bands = FalseColorScale.stops.bands(mapping: mapping)
            for (stop, index) in [
                (-8.0, 0), (-3.0, 1), (-2.0, 2), (-1.0, 3),
                (0.0, 4), (1.0, 5), (2.0, 6),
            ] {
                #expect(
                    FalseColorMap.band(value: stop, scale: .stops, mapping: mapping) == bands[index]
                )
            }
            let maximum = FalseColorMap.maximumSceneStop(mapping: mapping)
            #expect(
                FalseColorMap.band(value: maximum - 0.1, scale: .stops, mapping: mapping)
                    == bands[bands.count - 2])
            #expect(
                FalseColorMap.band(value: maximum, scale: .stops, mapping: mapping) == bands.last)
        }
    }

    @Test("The former scene-detail scenario now verifies canonical flat exposure zones")
    func zcStopsRetainsSceneDetail() {
        // Canonical CineStop deliberately flattens detail within a whole-stop zone.
        let curve = ExposureToneCurve.redLog3G10
        let darker = curve.encode(linearLight: 0.18 * pow(2, -0.1))
        let brighter = curve.encode(linearLight: 0.18 * pow(2, 0.1))
        let darkOutput = FalseColorMap.mappedColor(
            red: darker, green: darker, blue: darker,
            scale: .stops, curve: curve)
        let brightOutput = FalseColorMap.mappedColor(
            red: brighter, green: brighter, blue: brighter,
            scale: .stops, curve: curve)
        expectColor(
            darkOutput, equals: (127.0 / 255, 127.0 / 255, 127.0 / 255), tolerance: 0.000001)
        expectColor(
            brightOutput, equals: (darkOutput.red, darkOutput.green, darkOutput.blue),
            tolerance: 0.000001)
    }

    @Test("CineStop feathers whole-stop boundaries between canonical flat colours")
    func zcStopsTransitionsAreSmooth() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let code = mapping.curve.encode(linearLight: 0.18 * pow(2, 0.5))
        let boundary = FalseColorMap.mappedColor(
            red: code, green: code, blue: code,
            scale: .stops, mapping: mapping)
        let expected = ((127.0 + 221) / 510, (127.0 + 174) / 510, (127.0 + 180) / 510)
        expectColor(boundary, equals: expected, tolerance: 0.000001)
    }

    @Test("CineStop shadows and highlights use canonical flat grayscale zones")
    func zcStopsGapsAreGrayscale() {
        // The old sparse-ramp gaps now form complete shadow and highlight zones.
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let encoded = curve.encode(linearLight: 0.18 / 8)
            let output = FalseColorMap.mappedColor(
                red: encoded, green: encoded, blue: encoded,
                scale: .stops, mapping: mapping)
            expectColor(output, equals: (102.0 / 255, 102.0 / 255, 102.0 / 255), tolerance: 0.0001)
            if FalseColorMap.maximumSceneStop(mapping: mapping) > 3.1 {
                let highlight = curve.encode(linearLight: 0.18 * pow(2, 3))
                let bright = FalseColorMap.mappedColor(
                    red: highlight, green: highlight, blue: highlight,
                    scale: .stops, mapping: mapping)
                expectColor(
                    bright, equals: (179.0 / 255, 178.0 / 255, 178.0 / 255), tolerance: 0.0001)
            }
        }
    }

    @Test("IRE uses six canonical zones; Video owns the former nine-zone ramp")
    func ireLegendAndBands() throws {
        #expect(
            FalseColorScale.ire.legendStops.map(\.label)
                == ["BDL", "NBDL", "18%MG", "MG+1", "80%WC", "95%WC"])
        #expect(FalseColorScale.ire.bands.count == 6)
        let expectedBounds: [(Double, Double)] = [
            (0, 2.5), (2.5, 10), (38, 42), (52, 56), (80, 95), (95, .infinity),
        ]
        for (band, expected) in zip(FalseColorScale.ire.bands, expectedBounds) {
            #expect(band.lowerBound == expected.0)
            #expect(band.upperBound == expected.1)
        }
        #expect(FalseColorMap.band(value: 11, scale: .ire) == nil)
        #expect(FalseColorMap.band(value: 20, scale: .ire) == nil)
        #expect(FalseColorMap.band(value: 60, scale: .ire) == nil)
        #expect(FalseColorMap.band(value: 79, scale: .ire) == nil)
        let red = try #require(FalseColorMap.band(value: 100.1, scale: .ire))
        #expect((red.red, red.green, red.blue) == (220.0 / 255, 51.0 / 255, 33.0 / 255))
    }

    @Test("LOG monitor IRE keeps each source paper-grey anchor and calibrated clip")
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
            #expect(abs(middle - mapping.curve.encode(linearLight: 0.18) * 100) < 0.0001)
            #expect(abs(clip - 100) < 0.0001)
            #expect(FalseColorMap.band(value: middle, scale: .ire, mapping: mapping) == nil)
        }
    }

    @Test("IRE colours resolve through Log3G10 and N-Log")
    func ireColorsForBothCurves() {
        let samples: [(ire: Double, color: (Double, Double, Double))] = [
            (1, (115.0 / 255, 33.0 / 255, 120.0 / 255)),
            (6, (29.0 / 255, 2.0 / 255, 221.0 / 255)),
            (40, (123.0 / 255, 207.0 / 255, 87.0 / 255)),
            (54, (241.0 / 255, 190.0 / 255, 198.0 / 255)),
            (88, (1, 1, 88.0 / 255)),
            (100, (220.0 / 255, 51.0 / 255, 33.0 / 255)),
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
        let below = mappedNeutral(monitorIRE: 94.95, scale: .ire, mapping: mapping)
        let boundary = mappedNeutral(monitorIRE: 95, scale: .ire, mapping: mapping)
        let above = mappedNeutral(monitorIRE: 95.05, scale: .ire, mapping: mapping)

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
        let yellow = try #require(FalseColorMap.band(value: 94.5, scale: .limits))
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
        let clip = FalseColorMap.limitsPaint(value: 100, mapping: mapping)
        #expect(clip.weight == 1)
        #expect((clip.red, clip.green, clip.blue) == (0.78, 0.28, 0.18))
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
                cube: weightCube, encoded: encoded(monitorIRE: 100, mapping: mapping))
            #expect(crushWeight.red > 0.9)
            #expect(clipWeight.red > 0.9)
            let crushPaint = sampledNeutral(
                cube: paintCube, encoded: encoded(monitorIRE: 2, mapping: mapping))
            #expect(crushPaint.blue > crushPaint.green + 0.3)  // shadow-limit purple
            // An arbitrary source code interpolates neighbouring cube vertices, including
            // the canonical yellow/red feather. Test full clip colour at an interior vertex.
            let denominator = Double(paintCube.size - 1)
            let clipInterior = min(
                1,
                (ceil(encoded(monitorIRE: 100, mapping: mapping) * denominator) + 1)
                    / denominator)
            let clipPaint = sampledNeutral(cube: paintCube, encoded: clipInterior)
            let clipBand = FalseColorScale.limits.bands(mapping: mapping).last
            #expect(clipBand != nil)
            if let clipBand {
                expectColor(
                    clipPaint,
                    equals: (clipBand.red, clipBand.green, clipBand.blue), tolerance: 0.00001)
            }
            let interiorWeight = sampledNeutral(cube: weightCube, encoded: clipInterior)
            #expect(interiorWeight.red > 0.99)
        }
    }

    @Test("The generated IRE cube retains narrow shadow and highlight warnings")
    func ireCubeNarrowBands() {
        for curve in ExposureToneCurve.allCases {
            let mapping = ExposureSignalMapping(curve: curve)
            let cube = FalseColorMap.cube(scale: .ire, mapping: mapping)
            // The narrow warning is now six-zone IRE's NBDL blue. The middle-gray
            // band spans 38...42 and the upper warning begins at 95.
            let blue = sampledNeutral(cube: cube, encoded: encoded(monitorIRE: 6, mapping: mapping))
            let green = sampledNeutral(
                cube: cube, encoded: encoded(monitorIRE: 40, mapping: mapping))
            let red = sampledNeutral(
                cube: cube, encoded: encoded(monitorIRE: 100, mapping: mapping))
            #expect(blue.blue > blue.red + 0.15)
            #expect(blue.blue > blue.green + 0.15)
            #expect(green.green > green.red + 0.15)
            #expect(green.green > green.blue + 0.15)
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

    @Test("CineStop retains saved keys while Video is a fourth independent scale")
    func savedScaleKeys() throws {
        #expect(FalseColorScale(rawValue: "Stops") == .stops)
        #expect(FalseColorScale(rawValue: "IRE") == .ire)
        #expect(FalseColorScale(rawValue: "Limits") == .limits)
        #expect(FalseColorScale(rawValue: "Video") == .video)
        #expect(FalseColorScale.stops.sharedScale == .sceneStops)
        #expect(FalseColorScale.video.sharedScale == .stops)
        #expect(
            try JSONDecoder().decode(FalseColorScale.self, from: Data("\"Stops\"".utf8)) == .stops)
    }

    @Test("All four scales use canonical Media bands, including calibrated clip shelves")
    func canonicalBands() {
        for (curve, transfer) in [
            (ExposureToneCurve.redLog3G10, MonitorTransfer.log3G10),
            (.nikonNLog, .nlog),
        ] {
            for clip in [145.0, 180.0, 200.0, 230.0] {
                let mapping = ExposureSignalMapping(curve: curve, clipNative: clip)
                for scale in FalseColorScale.allCases {
                    let expected = LiveColorScience.falseColorBands(
                        scale.sharedScale,
                        transfer: transfer, clipEncoded: mapping.clipNative / 255)
                    let actual = scale.legendStops(mapping: mapping)
                    #expect(actual.count == expected.count)
                    for (entry, band) in zip(actual, expected) {
                        #expect(entry.label == band.label)
                        #expect(entry.band.lowerBound == band.lowerBound)
                        #expect(entry.band.upperBound == band.upperBound)
                        #expect(entry.band.red == band.red)
                        #expect(entry.band.green == band.green)
                        #expect(entry.band.blue == band.blue)
                    }
                }
            }
        }
    }

    @Test("Video and six-zone IRE classify distinct representative boundaries")
    func videoAndIREBoundaries() throws {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        #expect(FalseColorScale.video.bands.count == 9)
        #expect(FalseColorScale.ire.bands.count == 6)
        #expect(FalseColorMap.band(value: 5.5, scale: .video, mapping: mapping) != nil)
        #expect(FalseColorMap.band(value: 11.5, scale: .ire, mapping: mapping) == nil)
        let mg = try #require(FalseColorMap.band(value: 38, scale: .ire, mapping: mapping))
        #expect((mg.red, mg.green, mg.blue) == (123.0 / 255, 207.0 / 255, 87.0 / 255))
        #expect(FalseColorMap.band(value: 42, scale: .ire, mapping: mapping) == nil)
        #expect(FalseColorMap.band(value: 49, scale: .video, mapping: mapping) == nil)
        let white = try #require(FalseColorMap.band(value: 95, scale: .ire, mapping: mapping))
        #expect((white.red, white.green, white.blue) == (220.0 / 255, 51.0 / 255, 33.0 / 255))
    }

    @Test("CineStop whole-stop zones are flat and their clip shelf follows camera calibration")
    func sceneStopBoundariesAndClip() throws {
        let low = ExposureSignalMapping(curve: .redLog3G10, clipNative: 145)
        let high = ExposureSignalMapping(curve: .redLog3G10, clipNative: 215)
        let middle = try #require(FalseColorMap.band(value: 0, scale: .stops, mapping: low))
        #expect((middle.red, middle.green, middle.blue) == (127.0 / 255, 127.0 / 255, 127.0 / 255))
        #expect(FalseColorMap.band(value: -0.5, scale: .stops, mapping: low) == middle)
        #expect(FalseColorMap.band(value: 0.5, scale: .stops, mapping: low) != middle)
        #expect(
            FalseColorMap.maximumSceneStop(mapping: low)
                < FalseColorMap.maximumSceneStop(mapping: high))
        let expected = log2(low.curve.decode(encodedValue: (145 - 7.0) / 255) / 0.18)
        #expect(abs(FalseColorMap.maximumSceneStop(mapping: low) - expected) < 0.000001)
        for stop in [-0.3, 0.3] {
            let code = low.curve.encode(linearLight: 0.18 * pow(2, stop))
            let output = FalseColorMap.mappedColor(
                red: code, green: code, blue: code,
                scale: .stops, mapping: low)
            #expect(abs(output.red - middle.red) < 0.000001)
            #expect(abs(output.green - middle.green) < 0.000001)
            #expect(abs(output.blue - middle.blue) < 0.000001)
        }
    }

    @Test("LOG and 709 use different real monitor readings without altering CineStop exposure")
    func monitorReadingModes() {
        for (curve, transfer) in [
            (ExposureToneCurve.redLog3G10, MonitorTransfer.log3G10),
            (.nikonNLog, .nlog),
        ] {
            let mapping = ExposureSignalMapping(curve: curve)
            let gray = curve.encode(linearLight: 0.18)
            let log = FalseColorMap.exposureValue(
                red: gray, green: gray, blue: gray,
                scale: .video, mapping: mapping)
            let rec709 = FalseColorMap.exposureValue(
                red: gray, green: gray, blue: gray,
                scale: .video, mapping: mapping, read709: true)
            #expect(
                abs(
                    log
                        - OpenCineMedia.ScopeDisplayScale.monitorPercent(
                            gray, transfer: transfer,
                            clipByte: Int(mapping.clipNative.rounded()))) < 0.000001)
            #expect(abs(rec709 - log) > 2)
            #expect(
                abs(
                    FalseColorMap.exposureValue(
                        red: gray, green: gray, blue: gray,
                        scale: .stops, mapping: mapping, read709: true)) < 0.000001)
            #expect(
                FalseColorMap.maximumSceneStop(mapping: mapping, read709: true)
                    != FalseColorMap.maximumSceneStop(mapping: mapping))
            let logCube = FalseColorMap.cube(scale: .video, mapping: mapping, size: 9)
            let rec709Cube = FalseColorMap.cube(
                scale: .video, mapping: mapping, size: 9, read709: true)
            #expect(logCube.rgb != rec709Cube.rgb)
        }
    }

    @Test("Limits leaves midrange source colour intact and fully paints the calibrated shelf")
    func limitsPassthroughAndClip() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10, clipNative: 180)
        #expect(FalseColorMap.limitsPaint(value: 50, mapping: mapping).weight == 0)
        let code = mapping.curve.encode(linearLight: 0.18)
        let output = FalseColorMap.mappedColor(
            red: code, green: code, blue: code,
            scale: .limits, mapping: mapping)
        #expect(output.red == code && output.green == code && output.blue == code)
        for read709 in [false, true] {
            let mask = FalseColorMap.limitsWeightCube(mapping: mapping, read709: read709)
            #expect(mask.rgb.allSatisfy { $0.isFinite && (0...1).contains($0) })
            let top = mask.map(red: 1, green: 1, blue: 1)
            #expect(top.red == 1 && top.green == 1 && top.blue == 1)
        }
        let mask = FalseColorMap.limitsWeightCube(mapping: mapping)
        let canonical = MonitorFalseColorLattice.signal(
            scale: .limits, transfer: .log3G10, clipByte: 180, size: mask.size
        ).cube(.weight)
        // The unsnapped shelf can cross a feathered or adjacent lattice cell. Its response
        // must match Pocket's shared lattice; it is not an interior full-opacity sample.
        let shelf = Float(180 - 7) / 255
        let observed = mask.map(red: shelf, green: shelf, blue: shelf)
        let expected = canonical.map(red: shelf, green: shelf, blue: shelf)
        #expect(observed.red == expected.red)
        #expect(observed.green == expected.green && observed.blue == expected.blue)
        #expect(mask.rgb == canonical.rgb)
        let denominator = Double(mask.size - 1)
        let clipInterior = Float(
            min(
                1,
                (ceil(encoded(monitorIRE: 100, mapping: mapping) * denominator) + 1)
                    / denominator))
        let fullClip = mask.map(red: clipInterior, green: clipInterior, blue: clipInterior)
        #expect(fullClip.red > 0.99 && fullClip.green > 0.99 && fullClip.blue > 0.99)
    }

    @Test("IRE and Video retain monochrome gaps and smooth categorical transitions")
    func grayscaleGapsAndFeathering() {
        for (curve, transfer) in [
            (ExposureToneCurve.redLog3G10, MonitorTransfer.log3G10),
            (.nikonNLog, .nlog),
        ] {
            let mapping = ExposureSignalMapping(curve: curve)
            let clip = Int(mapping.clipNative.rounded())
            for scale in [FalseColorScale.video, .ire] {
                let code = OpenCineMedia.ScopeDisplayScale.signalNative(
                    monitorPercent: 20,
                    transfer: transfer, clipByte: clip)
                let gap = FalseColorMap.mappedColor(
                    red: code, green: code, blue: code,
                    scale: scale, mapping: mapping)
                #expect(abs(gap.red - 0.2) < 0.000001)
                #expect(gap.red == gap.green && gap.green == gap.blue)
                let edge = scale == .video ? 94.0 : 95.0
                let colors = [edge - 0.1, edge, edge + 0.1].map { value in
                    let encoded = OpenCineMedia.ScopeDisplayScale.signalNative(
                        monitorPercent: value,
                        transfer: transfer, clipByte: clip)
                    return FalseColorMap.mappedColor(
                        red: encoded, green: encoded, blue: encoded,
                        scale: scale, mapping: mapping)
                }
                let channels = [
                    (colors[0].red, colors[1].red, colors[2].red),
                    (colors[0].green, colors[1].green, colors[2].green),
                    (colors[0].blue, colors[1].blue, colors[2].blue),
                ]
                for (below, at, above) in channels {
                    #expect(at >= min(below, above) - 0.000001)
                    #expect(at <= max(below, above) + 0.000001)
                    #expect(abs(above - below) < 0.3)
                }
            }
        }
    }

    private func encoded(monitorIRE: Double, mapping: ExposureSignalMapping) -> Double {
        let transfer: MonitorTransfer
        switch mapping.curve {
        case .redLog3G10: transfer = .log3G10
        case .nikonNLog: transfer = .nlog
        case .srgb: transfer = .srgb
        case .hlg: transfer = .hdr
        }
        return OpenCineMedia.ScopeDisplayScale.signalNative(
            monitorPercent: monitorIRE, transfer: transfer,
            clipByte: Int(mapping.clipNative.rounded()))
    }

    private func linear(monitorIRE: Double, mapping: ExposureSignalMapping) -> Double {
        mapping.curve.decode(encodedValue: encoded(monitorIRE: monitorIRE, mapping: mapping))
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
