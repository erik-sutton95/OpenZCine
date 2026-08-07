import Foundation
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
    // look, now that Teal/Orange is retired) then the contributed table follow.
    #expect(MonitorLUT.allCases == [.log3G10Rec709, .nLogRec709, .monochrome, .r3dNEMonitor])
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

// MARK: - The contributed, table-backed look

@Test func contributedTableMatchesItsGeneratorChecksum() {
    // `scripts/generate-builtin-lut-table.rb` prints this checksum; a truncated, hand-edited or
    // re-encoded blob changes it. Both shells decode these same bytes, so this covers iOS and
    // Android at once.
    let bytes = MonitorLUT.contributedTableBytes()
    #expect(bytes.count == 33 * 33 * 33 * 3 * 2)
    #expect(MonitorLUT.fnv1a64(bytes) == MonitorLUT.contributedTableChecksum)
}

@Test func contributedLookDecodesToAnInGamut33Cube() {
    let cube = MonitorLUT.r3dNEMonitor.cube()
    #expect(cube.size == 33)
    #expect(cube.rgb.count == 33 * 33 * 33 * 3)
    #expect(cube.rgb.allSatisfy { $0 >= 0 && $0 <= 1 })
    // A display transform, not a pass-through: black holds and encoded white lifts to near-white.
    // (This look rolls its highlight off to ~0.93 rather than clipping at 1.0, so no ≈1.0 assert.)
    #expect(Array(cube.rgb.prefix(3)).allSatisfy { $0 == 0 })
    #expect(Array(cube.rgb.suffix(3)).allSatisfy { $0 > 0.85 })
}

@Test func contributedLookAt33IsTheContributorsOwnSamples() {
    // 65 = 2·32 + 1, so the 65³ → 33³ reduction took exact source indices (stride 2, no
    // interpolation); sampling the table at its own grid then gives trilinear weights of 1. Both
    // steps together mean the picker applies the contributed numbers verbatim.
    let cube = MonitorLUT.r3dNEMonitor.cube()
    #expect(cube.rgb == MonitorLUT.contributedTableCube.rgb)

    // One asymmetric lattice point read straight out of the source .cube — an r/b transposition
    // anywhere in the generator or the decoder would survive the endpoint checks but not this.
    let flat = 8 + 16 * 33 + 24 * 33 * 33
    let sample = Array(cube.rgb[(flat * 3)..<(flat * 3 + 3)])
    #expect(abs(sample[0] - 0.020_005) < 1e-5)
    #expect(abs(sample[1] - 0.409_628) < 1e-5)
    #expect(abs(sample[2] - 0.931_960) < 1e-5)
}

@Test func contributedLookResamplesOntoOtherGridSizes() {
    // Nothing ships at another size today, but `cube(size:)` is public and the Android facade takes
    // the size over JNI, so the table has to answer for a grid it was not authored on.
    let coarse = MonitorLUT.r3dNEMonitor.cube(size: 17)
    #expect(coarse.rgb.count == 17 * 17 * 17 * 3)
    #expect(coarse.rgb.allSatisfy { $0 >= 0 && $0 <= 1 })
}

@Test func onlyTheContributedLookCarriesACreditLine() {
    #expect(MonitorLUT.r3dNEMonitor.credit == "Contributed by Wang Yuehua")
    #expect(MonitorLUT.allCases.filter { $0.credit != nil } == [.r3dNEMonitor])
}

// MARK: - 50/50 Log vs LUT comparison

@Test func splitComparisonIsOffByDefaultAndOpensVertical() {
    #expect(!OperatorPreferences.defaults.splitComparisonEnabled)
    #expect(OperatorPreferences.defaults.splitComparisonOrientation == .vertical)
}

@Test func splitComparisonNeedsBothThePreferenceAndTheLUTTool() {
    var preferences = OperatorPreferences.defaults
    #expect(LUTResolution.splitComparison(visibleTools: [.lut], preferences: preferences) == nil)

    preferences.splitComparisonEnabled = true
    preferences.splitComparisonOrientation = .horizontal
    // No grade on screen means nothing to compare — and no divider or labels either.
    #expect(
        LUTResolution.splitComparison(visibleTools: [.peaking], preferences: preferences) == nil)
    #expect(
        LUTResolution.splitComparison(visibleTools: [.lut, .peaking], preferences: preferences)
            == .horizontal)
}

@Test func splitComparisonFollowsTheCleanViewPinLikeTheLUTItself() {
    var preferences = OperatorPreferences.defaults
    preferences.splitComparisonEnabled = true
    preferences.liveViewVisibleAssistTools = [.lut]

    let live = MonitorChromePolicy.visibleTools(mode: .live, preferences: preferences)
    #expect(LUTResolution.splitComparison(visibleTools: live, preferences: preferences) != nil)

    // Clean drops the tool unless pinned, so the comparison leaves with it.
    let clean = MonitorChromePolicy.visibleTools(mode: .clean, preferences: preferences)
    #expect(LUTResolution.splitComparison(visibleTools: clean, preferences: preferences) == nil)

    preferences.cleanViewPinnedTools = [.lut]
    let pinned = MonitorChromePolicy.visibleTools(mode: .clean, preferences: preferences)
    #expect(LUTResolution.splitComparison(visibleTools: pinned, preferences: preferences) != nil)
}

@Test func theOnFeedQuickKeySurvivesItsOwnTap() {
    // The key mutes the comparison; if it followed the muted state instead of the armed one, the
    // first tap would remove the only control that undoes it.
    var preferences = OperatorPreferences.defaults
    preferences.splitComparisonEnabled = true
    let tools: Set<MonitorAssistTool> = [.lut]

    #expect(
        LUTResolution.splitComparison(visibleTools: tools, preferences: preferences, muted: false)
            == .vertical)
    #expect(
        LUTResolution.splitComparison(visibleTools: tools, preferences: preferences, muted: true)
            == nil)
    #expect(LUTResolution.showsSplitComparisonKey(visibleTools: tools, preferences: preferences))

    // Disarmed from the pop-up, or with no grade on screen, the key goes with the feature.
    preferences.splitComparisonEnabled = false
    #expect(!LUTResolution.showsSplitComparisonKey(visibleTools: tools, preferences: preferences))
    preferences.splitComparisonEnabled = true
    #expect(
        !LUTResolution.showsSplitComparisonKey(visibleTools: [.peaking], preferences: preferences))
}

@Test func splitHalvesTileTheVisibleImageRectAndMeetAtItsCentre() {
    // A pillarboxed feed: the image sits inset inside its surface, so a boundary taken from the
    // surface (or from 0) lands off-centre. The non-zero origin is the whole point of this case.
    let feed = MonitorModuleFrame(x: 120, y: 0, width: 640, height: 360)

    for orientation in SplitComparisonOrientation.allCases {
        let log = SplitComparison.logHalf(of: feed, orientation: orientation)
        let lut = SplitComparison.lutHalf(of: feed, orientation: orientation)

        #expect(log.width * log.height == feed.width * feed.height / 2)
        #expect(lut.width * lut.height == feed.width * feed.height / 2)

        switch orientation {
        case .vertical:
            #expect(log.x == feed.x)
            #expect(log.x + log.width == feed.midX)
            #expect(lut.x == feed.midX)
            #expect(lut.x + lut.width == feed.x + feed.width)
            #expect(log.height == feed.height && lut.height == feed.height)
        case .horizontal:
            #expect(log.y == feed.y)
            #expect(log.y + log.height == feed.midY)
            #expect(lut.y == feed.midY)
            #expect(lut.y + lut.height == feed.y + feed.height)
            #expect(log.width == feed.width && lut.width == feed.width)
        }
    }
}

@Test func splitBoundaryTracksTheImageRectThroughFitFillCropAndRotation() {
    // The same source presented four ways: pillarboxed in a wide viewport, letterboxed in a tall
    // one, centre-cropped by aspect fill, and the portrait (rotated) mount. In every case the
    // shells hand over the rect the image really occupies, and the boundary is its own centre —
    // never the viewport's.
    let rects = [
        MonitorModuleFrame(x: 212, y: 0, width: 1024, height: 576),  // pillarbox
        MonitorModuleFrame(x: 0, y: 132, width: 1024, height: 576),  // letterbox
        MonitorModuleFrame(x: -128, y: 0, width: 1280, height: 720),  // aspect-fill overhang
        MonitorModuleFrame(x: 0, y: 240, width: 390, height: 219),  // portrait mount
    ]
    for feed in rects {
        #expect(SplitComparison.lutHalf(of: feed, orientation: .vertical).x == feed.midX)
        #expect(SplitComparison.lutHalf(of: feed, orientation: .horizontal).y == feed.midY)
    }
}

@Test func normalizedSplitTestAgreesWithTheHalfRects() {
    // The shaders take the normalized form and the shells take the rects; they have to name the
    // same side or the divider drifts off the grade.
    let feed = MonitorModuleFrame(x: 40, y: 10, width: 200, height: 100)
    for orientation in SplitComparisonOrientation.allCases {
        let lut = SplitComparison.lutHalf(of: feed, orientation: orientation)
        for (nx, ny) in [(0.1, 0.1), (0.4, 0.9), (0.6, 0.2), (0.9, 0.8)] {
            let point = (x: feed.x + nx * feed.width, y: feed.y + ny * feed.height)
            let insideLUTHalf =
                point.x >= lut.x && point.x <= lut.x + lut.width
                && point.y >= lut.y && point.y <= lut.y + lut.height
            #expect(
                SplitComparison.isGradedSide(x: nx, y: ny, orientation: orientation)
                    == insideLUTHalf)
        }
    }
}

@Test func splitComparisonPreferencesRoundTripAndOlderBlobsDecodeToOff() throws {
    var preferences = OperatorPreferences.defaults
    preferences.splitComparisonEnabled = true
    preferences.splitComparisonOrientation = .horizontal
    let encoded = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(OperatorPreferences.self, from: encoded)
    #expect(decoded.splitComparisonEnabled)
    #expect(decoded.splitComparisonOrientation == .horizontal)

    // A blob written before the feature existed carries neither key.
    var dict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    dict.removeValue(forKey: "splitComparisonEnabled")
    dict.removeValue(forKey: "splitComparisonOrientation")
    let migrated = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONSerialization.data(withJSONObject: dict))
    #expect(!migrated.splitComparisonEnabled)
    #expect(migrated.splitComparisonOrientation == .vertical)
}

@Test func splitOrientationSurvivesSwitchingTheComparisonOff() throws {
    // "Preserve the operator's orientation preference while the feature is enabled" — which only
    // holds if the two are stored independently rather than collapsed into one tri-state.
    var preferences = OperatorPreferences.defaults
    preferences.splitComparisonEnabled = true
    preferences.splitComparisonOrientation = .horizontal
    preferences.splitComparisonEnabled = false

    let reloaded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(preferences))
    #expect(!reloaded.splitComparisonEnabled)
    #expect(reloaded.splitComparisonOrientation == .horizontal)
}

/// The movie and stills white balance are different camera settings that decode through the same
/// table. They used to share one field, last writer winning — so a stills-WB event during the
/// record burst repainted the movie readout as Auto while the camera's movie WB never moved.
@Test func aStillsWhiteBalanceEventCannotRepaintTheMovieReadout() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieWhiteBalance, data: Data(ByteCoding.uint16LE(0x8012)))
        .applying(property: .movieWBColorTemp, data: Data(ByteCoding.uint16LE(5560)))
        .applying(property: .whiteBalance, data: Data(ByteCoding.uint16LE(0x0002)))

    #expect(snapshot.wbMode == "Color temp")
    #expect(snapshot.stillWBMode == "Auto")
    // Video keeps its own; stills keeps its own.
    #expect(snapshot.activeWBMode(photography: false) == "Color temp")
    #expect(snapshot.activeWBMode(photography: true) == "Auto")

    let state = CameraDisplayState.blank.applyingCameraProperties(snapshot, photography: false)
    #expect(state.values.first { $0.label == "WB" }?.value == "5560K")
}

/// A body that has only ever reported one side still reads out — the split must not blank the
/// tile on a camera that pushes just one of the two properties.
@Test func aWhiteBalanceFromEitherSideStillShowsWhenItIsTheOnlyOne() {
    let stillsOnly = PTPCameraPropertySnapshot()
        .applying(property: .whiteBalance, data: Data(ByteCoding.uint16LE(0x0004)))
    #expect(stillsOnly.activeWBMode(photography: false) == "Sunny")

    let movieOnly = PTPCameraPropertySnapshot()
        .applying(property: .movieWhiteBalance, data: Data(ByteCoding.uint16LE(0x8011)))
    #expect(movieOnly.activeWBMode(photography: true) == "Shade")
}
