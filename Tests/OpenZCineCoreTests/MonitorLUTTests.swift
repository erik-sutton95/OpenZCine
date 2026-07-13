import Testing

@testable import OpenZCineCore

@Test func lutCategoriesAreOrderedBuiltInFirst() {
    #expect(LUTCategory.allCases.map(\.rawValue) == ["Built-in", "RED", "Custom"])
}

@Test func generatedCubeUsesRedFastestOrdering() {
    let cube = MonitorLUT.monochrome.cube(size: 2)

    #expect(cube.size == 2)
    #expect(cube.rgb.count == 2 * 2 * 2 * 3)
    // Entry 0 is (0,0,0) and the last is (1,1,1) — both luma-invariant under Mono.
    #expect(Array(cube.rgb[0..<3]) == [0, 0, 0])
    #expect(Array(cube.rgb.suffix(3)) == [1, 1, 1])
}

@Test func monochromeLookUsesRec709LumaWeights() {
    let cube = MonitorLUT.monochrome.cube(size: 2)

    // Entry 1 is pure red (1,0,0); luma = 0.2126.
    let entry = Array(cube.rgb[3..<6])
    #expect(abs(entry[0] - 0.2126) < 1e-4)
    #expect(entry[0] == entry[1])
    #expect(entry[1] == entry[2])
}

@Test func generatedLookHasFullSampleCount() {
    let cube = MonitorLUT.monochrome.cube(size: 17)
    #expect(cube.rgb.count == 17 * 17 * 17 * 3)
    // Stays in gamut.
    #expect(cube.rgb.allSatisfy { $0 >= 0 && $0 <= 1 })
}

@Test func builtInOrderLeadsWithCameraMatchedConversions() {
    // The two camera-matched log conversions lead the picker; Mono (the sole remaining creative
    // look, now that Teal/Orange is retired) stays last.
    #expect(MonitorLUT.allCases == [.log3G10Rec709, .nLogRec709, .monochrome])
}

@Test func rgbaComponentsInterleaveOpaqueAlpha() {
    let rgba = MonitorLUT.monochrome.cube(size: 2).rgbaComponents

    #expect(rgba.count == 2 * 2 * 2 * 4)
    #expect(Array(rgba[0..<4]) == [0, 0, 0, 1])  // entry 0 (black) + opaque alpha
    // Every 4th component is an opaque alpha.
    #expect(stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 1 })
}

// MARK: - Log → Rec.709 conversions

/// The cube's output sample on the neutral axis at grid coordinate `k` — i.e. the result of feeding
/// `k/(size-1)` to all three channels (red-fastest index `k + k·size + k·size²`).
private func neutralSample(_ cube: CubeLUT, _ k: Int) -> [Float] {
    let flatIndex = k + k * cube.size + k * cube.size * cube.size
    return Array(cube.rgb[(flatIndex * 3)..<(flatIndex * 3 + 3)])
}

/// Runs one neutral encoded input (fed to all three channels) through a look's generated 33³ cube,
/// returning the output code value on the neutral axis. Mirrors how the shell applies the LUT:
/// on the neutral axis trilinear interpolation collapses to 1-D linear interpolation between the two
/// bracketing neutral grid samples.
private func mapNeutral(_ look: MonitorLUT, _ encoded: Float) -> Float {
    let cube = look.cube()
    let pos = max(0, min(1, encoded)) * Float(cube.size - 1)
    let lo = Int(pos.rounded(.down))
    let hi = min(lo + 1, cube.size - 1)
    let frac = pos - Float(lo)
    let low = neutralSample(cube, lo)[0]
    let high = neutralSample(cube, hi)[0]
    return low * (1 - frac) + high * frac
}

@Test(arguments: [MonitorLUT.nLogRec709, .log3G10Rec709])
func midGreyAnchor(look: MonitorLUT) {
    // Published encoded mid grey per format: N-Log 10-bit 372/1023 (decodes to ≈0.180 reflectance),
    // Log3G10 0.333799 (≈0.181). The anchored tone map pins scene 0.18 to 42 monitor IRE.
    let encodedMid: Float = look == .nLogRec709 ? 372.0 / 1023.0 : 0.333799
    #expect(abs(mapNeutral(look, encodedMid) - 0.42) < 0.02)
}

@Test(arguments: [MonitorLUT.nLogRec709, .log3G10Rec709])
func neutralAxisMonotonicAndEndpoints(look: MonitorLUT) {
    let samples = (0..<33).map { mapNeutral(look, Float($0) / 32) }
    for pair in zip(samples, samples.dropFirst()) {
        // SAFETY: allCases/zip yield fixed non-empty sequences; no unwrap risk below either.
        #expect(pair.1 >= pair.0 - 1e-4)
    }
    #expect(samples.first! < 0.02)  // encoded black → ≈0
    #expect(abs(samples.last! - 1.0) < 0.01)  // encoded max → 1.0 via the shoulder, no hard clip
    // Soft-shoulder probe: an upper-mid neutral input (encoded 0.75) must stay strictly below 1.0 —
    // guards against the shoulder degenerating into a hard clip that pins highlights to white early.
    #expect(samples[24] < 0.999)
}

@Test(arguments: MonitorLUT.allCases)
func cubeIsFinite(look: MonitorLUT) {
    #expect(look.cube().rgb.allSatisfy { $0.isFinite })
}

@Test func log3G10ToRec709MapsMiddleGreyToRec709() {
    // Log3G10 encodes 18% scene grey at exactly 1/3 — which is a grid point when size == 4.
    let cube = MonitorLUT.log3G10Rec709.cube(size: 4)
    let grey = neutralSample(cube, 1)  // input 1/3 on each channel
    // The tone map pins scene 0.18 to 42 monitor IRE.
    for channel in grey {
        #expect(abs(channel - 0.42) < 0.01)
    }
}

@Test func nLogToRec709MatchesPublishedMathOnNeutralAxis() {
    // Input 0.375 is a grid point at size 17 (6/16). N-Log decodes it to ~0.198 reflectance
    // (≈1.1× mid grey), which through the tone map + BT.1886 encode lands at ~0.436.
    let cube = MonitorLUT.nLogRec709.cube(size: 17)
    let sample = neutralSample(cube, 6)
    for channel in sample {
        #expect(abs(channel - 0.436) < 0.01)
    }
}

@Test func sharedMonitorToneMapAnchorsGreyAndSelectedWhite() {
    for mapping in [
        ExposureSignalMapping(curve: .redLog3G10, clipNative: 145),
        ExposureSignalMapping(curve: .redLog3G10, clipNative: 215),
        ExposureSignalMapping(curve: .nikonNLog, clipNative: 200),
        ExposureSignalMapping(curve: .nikonNLog),
    ] {
        let tone = MonitorDisplayToneMap(mapping: mapping)
        let clipLinear = mapping.curve.decode(encodedValue: mapping.clipNative / 255)
        #expect(abs(tone.ire(sceneLinear: 0.18) - 42) < 0.0001)
        #expect(abs(tone.ire(sceneLinear: clipLinear) - 100) < 0.0001)
        #expect(tone.ire(sceneLinear: 0) == 0)
    }
}

@Test func logConversionsPreserveTheNeutralAxis() {
    for look in [MonitorLUT.nLogRec709, .log3G10Rec709] {
        let cube = look.cube(size: 17)
        for k in 0..<17 {
            let sample = neutralSample(cube, k)
            #expect(abs(sample[0] - sample[1]) < 0.01)
            #expect(abs(sample[1] - sample[2]) < 0.01)
        }
    }
}

@Test func logConversionsAnchorBlackToBlackAndWhiteToWhite() {
    for look in [MonitorLUT.nLogRec709, .log3G10Rec709] {
        let cube = look.cube(size: 17)
        #expect(Array(cube.rgb.prefix(3)).allSatisfy { $0 < 0.02 })
        #expect(Array(cube.rgb.suffix(3)).allSatisfy { $0 > 0.98 })
    }
}

@Test func logConversionsStayInGamutWithFullSampleCount() {
    for look in [MonitorLUT.nLogRec709, .log3G10Rec709] {
        let cube = look.cube(size: 17)
        #expect(cube.rgb.count == 17 * 17 * 17 * 3)
        #expect(cube.rgb.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}

@Test func log3G10NeutralAxisIncreasesMonotonically() {
    let cube = MonitorLUT.log3G10Rec709.cube(size: 17)
    var previous: Float = -1
    for k in 0..<17 {
        let value = neutralSample(cube, k)[1]  // green channel on the neutral axis
        #expect(value >= previous - 1e-5)
        previous = value
    }
}
