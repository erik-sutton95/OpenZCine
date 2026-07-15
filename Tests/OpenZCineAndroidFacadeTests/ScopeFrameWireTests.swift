import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

/// The scope wire must carry the core's anchored axis math value-for-value —
/// the Compose shell draws straight off these payloads with no curve math of
/// its own.
struct ScopeFrameWireTests {
    // MARK: - Anchors

    @Test func anchorsCarryFixedSafeBorderLines() {
        for ordinal in [0, 1] {
            let anchors = ScopeFrameWire.anchors(curveOrdinal: ordinal)
            #expect(anchors.count == 3 + 6 * 2)
            #expect(anchors[0] == Float(ScopeDisplayScale.crushLineLevel))
            #expect(anchors[2] == Float(ScopeDisplayScale.clipLineLevel))
            #expect(anchors[0] < anchors[1] && anchors[1] < anchors[2])
        }
    }

    @Test func midGrayAnchorMatchesCoreAndIgnoresISO() {
        let anchors = ScopeFrameWire.anchors(curveOrdinal: 0)
        // The wire's mid-grey anchor is the per-curve fixed level — the same
        // value regardless of any ISO-driven clip shift, by construction: it
        // derives from the curve's PUBLISHED default clip, never the live one.
        #expect(anchors[1] == Float(ScopeDisplayScale.middleGrayLevel(curve: .redLog3G10)))
        let shiftedISO = ExposureSignalMapping(curve: .redLog3G10, clipNative: 215)
        #expect(
            Float(ScopeDisplayScale.middleGrayLevel(mapping: shiftedISO)) == anchors[1])
    }

    @Test func vectorTargetsMatchCoreChromaMatrix() {
        let anchors = ScopeFrameWire.anchors(curveOrdinal: 0)
        // First target is 75% red: positive Cr, negative Cb, inside ±0.5.
        let (cb, cr) = VectorscopeSampler.chroma(red: 191, green: 0, blue: 0)
        #expect(anchors[3] == Float(cb))
        #expect(anchors[4] == Float(cr))
        for value in anchors[3...] {
            #expect(value >= -0.5 && value <= 0.5)
        }
    }

    // MARK: - Traces

    /// A 2×8 buffer whose stride-2 sweep samples exactly one pixel per value
    /// band: black, mid grey (Log3G10 18% grey code), clip warning, white.
    private func syntheticBuffer() -> ([UInt8], Int, Int) {
        let mid = UInt8(ExposureToneCurve.redLog3G10.middleGrayNativeCode.rounded())
        let clip = UInt8(ExposureToneCurve.redLog3G10.defaultClipNative.rounded())
        var rgba = [UInt8]()
        for value in [UInt8(0), mid, clip, 255] {
            // Two rows per band, two pixels per row — stride 2 hits row 0, col 0.
            for _ in 0..<4 {
                rgba.append(contentsOf: [value, value, value, 255])
            }
        }
        return (rgba, 2, 8)
    }

    /// Exactly one sampled white pixel among 100 mid-grey samples. It clears
    /// the 0-stop edge threshold but remains below iOS's quarter-stop default.
    private func sparseClipBuffer() -> ([UInt8], Int, Int) {
        let side = 20
        let mid = UInt8(ExposureToneCurve.redLog3G10.middleGrayNativeCode.rounded())
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        for pixel in 0..<(side * side) {
            let value: UInt8 = pixel == 0 ? .max : mid
            let offset = pixel * 4
            rgba[offset] = value
            rgba[offset + 1] = value
            rgba[offset + 2] = value
            rgba[offset + 3] = .max
        }
        return (rgba, side, side)
    }

    private func trafficClipFlags(_ flat: [Float]) -> [Float] {
        let pointCount = Int(flat[0])
        let start =
            1 + pointCount * ScopeFrameWire.pointStride
            + 4 * ScopeFrameWire.histogramBins
            + 2
        return (0..<3).map { channel in
            flat[start + channel * ScopeFrameWire.trafficChannelStride + 1]
        }
    }

    private func trafficTrailer(_ flat: [Float]) -> ArraySlice<Float> {
        let pointCount = Int(flat[0])
        let start = 1 + pointCount * ScopeFrameWire.pointStride + 4 * ScopeFrameWire.histogramBins
        return flat[start...]
    }

    @Test func tracesPayloadIsWellFormed() {
        let (rgba, width, height) = syntheticBuffer()
        let flat = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0)
        let count = Int(flat[0])
        // stride-2 sweep over 4×4 → 2×2 points.
        #expect(count == 4)
        #expect(
            flat.count
                == 1 + count * ScopeFrameWire.pointStride + 4 * ScopeFrameWire.histogramBins
                + ScopeFrameWire.trafficTrailerFloatCount)
        let allFinite = flat.allSatisfy { $0.isFinite }
        #expect(allFinite)
    }

    @Test func pointLevelsSitOnTheAnchoredAxis() {
        let (rgba, width, height) = syntheticBuffer()
        let flat = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0)
        let count = Int(flat[0])
        let anchors = ScopeFrameWire.anchors(curveOrdinal: 0)
        var levels = [Float]()
        for index in 0..<count {
            levels.append(flat[1 + index * ScopeFrameWire.pointStride + 1])  // luma level
        }
        levels.sort()
        // Black row (native 0) sits below the crush line; the mid-grey row sits
        // exactly on the fixed mid-grey anchor; the clip-warning row lands on
        // the clip line (±1 code of quantisation).
        #expect(levels[0] < anchors[0])
        #expect(abs(levels[1] - anchors[1]) < 0.01)
        #expect(abs(levels[2] - anchors[2]) < 0.01)
        #expect(levels[3] > anchors[2])
    }

    @Test func tracesUseTheCameraResolvedClipEndpoint() {
        let (rgba, width, height) = syntheticBuffer()
        let clip: Double = 215
        let mapping = ExposureSignalMapping(curve: .redLog3G10, clipNative: clip)
        let flat = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0, clipNative: clip)
        let count = Int(flat[0])
        let levels = (0..<count).map { flat[1 + $0 * ScopeFrameWire.pointStride + 1] }.sorted()
        let expected = Float(
            ScopeDisplayScale.waveformLevel(
                signalNative: ExposureToneCurve.redLog3G10.defaultClipNative,
                mapping: mapping))
        // The synthetic clip code is now below the higher camera warning;
        // the core remaps it below the fixed clip line rather than Kotlin
        // applying a stale Log3G10 endpoint.
        #expect(abs(levels[2] - expected) < 0.01)
        #expect(levels[2] < ScopeFrameWire.anchors(curveOrdinal: 0)[2])
    }

    @Test func histogramsCarryEverySampledPixel() {
        let (rgba, width, height) = syntheticBuffer()
        let flat = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0)
        let count = Int(flat[0])
        let start = 1 + count * ScopeFrameWire.pointStride
        for channel in 0..<4 {
            let bins = flat[
                (start + channel * ScopeFrameWire.histogramBins)..<(start + (channel + 1)
                    * ScopeFrameWire.histogramBins)
            ]
            #expect(Int(bins.reduce(0, +).rounded()) == count)
        }
    }

    @Test func histogramOnlyPayloadOmitsScatterPoints() {
        let (rgba, width, height) = syntheticBuffer()
        let flat = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0, includePoints: false)

        #expect(flat[0] == 0)
        #expect(
            flat.count
                == 1 + 4 * ScopeFrameWire.histogramBins
                + ScopeFrameWire.trafficTrailerFloatCount)
        let histogramTotal = flat[1..<(1 + ScopeFrameWire.histogramBins)].reduce(0, +)
        #expect(histogramTotal > 0)
    }

    @Test func invalidBufferYieldsEmptyPayload() {
        let flat = ScopeFrameWire.traces(
            rgba: [0, 0, 0], width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0)
        #expect(flat[0] == 0)
        #expect(
            flat.count
                == 1 + 4 * ScopeFrameWire.histogramBins
                + ScopeFrameWire.trafficTrailerFloatCount)
    }

    @Test func tracesTrailerCarriesCoreTrafficLightsDisplay() {
        let (rgba, width, height) = syntheticBuffer()
        let flat = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0)
        let count = Int(flat[0])
        let start = 1 + count * ScopeFrameWire.pointStride + 4 * ScopeFrameWire.histogramBins
        #expect(flat[start] == ScopeFrameWire.trafficTrailerMagic)
        #expect(flat[start + 1] == ScopeFrameWire.trafficTrailerVersion)

        for channel in 0..<3 {
            let offset = start + 2 + channel * ScopeFrameWire.trafficChannelStride
            let level = flat[offset]
            let clip = flat[offset + 1]
            let crush = flat[offset + 2]
            let side = flat[offset + 3]
            let fill = flat[offset + 4]
            #expect(level >= 0 && level <= 1)
            #expect(clip == 0 || clip == 1)
            #expect(crush == 0 || crush == 1)
            #expect(side == 0 || side == 1 || side == 2)
            #expect(fill >= 0 && fill <= 1)
        }

        let samples = ScopeSampler.sample(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            stride: ScopeFrameWire.sampleStride)
        let expected = TrafficLightsMeter.measure(
            samples: samples,
            noiseFloorCompensation: AssistConfiguration.CrushClipCompensation.quarter,
            mapping: ExposureSignalMapping(curve: .redLog3G10))
        let expectedChannels = [expected.red, expected.green, expected.blue]
        for channel in expectedChannels.indices {
            let expectedChannel = expectedChannels[channel]
            let expectedDisplay = TrafficLightsMeter.channelDisplay(for: expectedChannel)
            let expectedSide: Float =
                switch expectedDisplay.side {
                case .neutral: 0
                case .over: 1
                case .under: 2
                }
            let offset = start + 2 + channel * ScopeFrameWire.trafficChannelStride
            #expect(flat[offset] == Float(expectedChannel.level))
            #expect(flat[offset + 1] == (expectedChannel.clip ? 1 : 0))
            #expect(flat[offset + 2] == (expectedChannel.crush ? 1 : 0))
            #expect(flat[offset + 3] == expectedSide)
            #expect(flat[offset + 4] == Float(expectedDisplay.barFill))
        }
    }

    @Test func tracesWirePassesSelectedCrushClipCompensationToCoreMeter() {
        let (rgba, width, height) = sparseClipBuffer()
        let zero = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0,
            crushClipCompensationRaw: AssistConfiguration.CrushClipCompensation.zero.rawValue)
        let quarter = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0,
            crushClipCompensationRaw: AssistConfiguration.CrushClipCompensation.quarter.rawValue)
        let defaulted = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0)
        let one = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0,
            crushClipCompensationRaw: AssistConfiguration.CrushClipCompensation.one.rawValue)
        let legacyHigh = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0,
            crushClipCompensationRaw: 15)
        let legacyLow = ScopeFrameWire.traces(
            rgba: rgba, width: width, height: height, bytesPerRow: width * 4,
            curveOrdinal: 0,
            crushClipCompensationRaw: -1)

        #expect(trafficClipFlags(zero) == [1, 1, 1])
        #expect(trafficClipFlags(quarter) == [0, 0, 0])
        #expect(trafficTrailer(defaulted) == trafficTrailer(quarter))
        #expect(trafficTrailer(legacyHigh) == trafficTrailer(one))
        #expect(trafficTrailer(legacyLow) == trafficTrailer(zero))
    }

    // MARK: - Vectorscope

    @Test func vectorPixelsArePremultipliedRGBA() {
        // A saturated two-colour frame so the tone-mapped chroma spreads into
        // more than one bin.
        var rgba = [UInt8]()
        for index in 0..<16 {
            rgba.append(contentsOf: index % 2 == 0 ? [200, 40, 40, 255] : [40, 40, 200, 255])
        }
        let pixels = ScopeFrameWire.vectorPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0)
        let n = ScopeFrameWire.vectorBinCount
        #expect(pixels.count == n * n * 4)
        var occupied = 0
        for offset in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            if alpha > 0 { occupied += 1 }
            // Premultiplied: no channel may exceed its alpha.
            #expect(pixels[offset] <= alpha)
            #expect(pixels[offset + 1] <= alpha)
            #expect(pixels[offset + 2] <= alpha)
        }
        #expect(occupied > 0)
    }

    @Test func vectorDisplayPayloadCarriesGaussianSoftThenCrispImages() {
        let rgba = Array(repeating: [UInt8](arrayLiteral: 200, 40, 40, 255), count: 16)
            .flatMap { $0 }
        let crisp = ScopeFrameWire.vectorPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0)
        let display = ScopeFrameWire.vectorDisplayPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0)
        #expect(display.count == crisp.count * 2)
        #expect(Array(display.suffix(crisp.count)) == crisp)
        let soft = Array(display.prefix(crisp.count))
        #expect(soft != crisp)
        for offset in Swift.stride(from: 0, to: soft.count, by: 4) {
            let alpha = soft[offset + 3]
            #expect(soft[offset] <= alpha)
            #expect(soft[offset + 1] <= alpha)
            #expect(soft[offset + 2] <= alpha)
        }
    }

    @Test func vectorGaussianPreservesConstantsAndSpreadsPremultipliedDensity() {
        let constant = [UInt8](repeating: 64, count: 5 * 5 * 4)
        #expect(
            ScopeFrameWire.gaussianBlurredPremultipliedRGBA(constant, side: 5) == constant)

        var impulse = [UInt8](repeating: 0, count: 5 * 5 * 4)
        let centre = (2 * 5 + 2) * 4
        impulse[centre] = 255
        impulse[centre + 3] = 255
        let soft = ScopeFrameWire.gaussianBlurredPremultipliedRGBA(impulse, side: 5)
        let centreRed = soft[centre]
        let neighbourRed = soft[centre + 4]
        #expect(centreRed > 0 && centreRed < 255)
        #expect(neighbourRed > 0 && neighbourRed < centreRed)
        #expect(soft[centre + 3] == centreRed)
        #expect(soft[centre + 1] == 0)
    }

    @Test func emptyFrameYieldsEmptyVectorImage() {
        let pixels = ScopeFrameWire.vectorPixels(
            rgba: [], width: 0, height: 0, bytesPerRow: 0, curveOrdinal: 0)
        #expect(pixels.isEmpty)
    }

    @Test func vectorBrightnessIsAppliedBeforePremultipliedUpload() {
        let rgba = Array(repeating: [UInt8](arrayLiteral: 200, 40, 40, 255), count: 16)
            .flatMap { $0 }
        let dim = ScopeFrameWire.vectorPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0,
            brightnessPercent: 50)
        let boosted = ScopeFrameWire.vectorPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0,
            brightnessPercent: 200)
        let dimAlpha = Swift.stride(from: 3, to: dim.count, by: 4).reduce(0) { $0 + Int(dim[$1]) }
        let boostedAlpha = Swift.stride(from: 3, to: boosted.count, by: 4).reduce(0) {
            $0 + Int(boosted[$1])
        }

        #expect(boostedAlpha > dimAlpha)
    }

    @Test func invalidVectorscopeZoomFailsClosed() {
        let pixels = ScopeFrameWire.vectorPixels(
            rgba: [255, 0, 0, 255], width: 1, height: 1, bytesPerRow: 4,
            curveOrdinal: 0, zoomOrdinal: 9)
        #expect(pixels.isEmpty)
    }

    @Test func registeredBuiltInMonoChangesTheVectorscopeMonitorDomain() {
        let rgba = Array(repeating: [UInt8](arrayLiteral: 220, 25, 40, 255), count: 16)
            .flatMap { $0 }
        let fallback = ScopeFrameWire.vectorPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0)
        let handle = ScopeFrameWire.registerVectorCube(lookOrdinal: 2)
        #expect(handle != nil)
        let mono = ScopeFrameWire.vectorPixels(
            rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0,
            lutHandle: handle ?? -1)
        ScopeFrameWire.unregisterVectorCube(handle: handle ?? -1)

        #expect(!mono.isEmpty)
        #expect(mono != fallback)
        #expect(
            ScopeFrameWire.vectorPixels(
                rgba: rgba, width: 4, height: 4, bytesPerRow: 16, curveOrdinal: 0,
                lutHandle: handle ?? -1
            ).isEmpty)
    }

    @Test func packedStoredCubeRegistersOnceAndRejectsMalformedGeometry() {
        let identity = CubeLUT(
            size: 2,
            rgb: [
                0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0,
                0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1,
            ])
        let packed = FeedEffectsWire.packedRGBA(cube: identity)
        let decoded = ScopeFrameWire.unpackedVectorCube(packedRGBA: packed, size: 2)
        #expect(decoded == identity)

        let handle = ScopeFrameWire.registerVectorCube(
            lookOrdinal: -1, packedRGBA: packed, size: 2)
        #expect(handle != nil)
        ScopeFrameWire.unregisterVectorCube(handle: handle ?? -1)
        #expect(
            ScopeFrameWire.registerVectorCube(
                lookOrdinal: -1, packedRGBA: Array(packed.dropLast()), size: 2) == nil)
        #expect(
            ScopeFrameWire.registerVectorCube(
                lookOrdinal: -1, packedRGBA: packed, size: 65) == nil)
    }
}
