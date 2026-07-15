// Flat wire format for one scope tick crossing the JNI seam.
//
// Like `MonitorZoneMapWire`, this file compiles on every platform so the
// payloads are exercised by `just native-check` on macOS against the exact
// core scope math the iOS shell consumes (`ScopeSampler`, `ScopeDisplayScale`,
// `VectorscopeSampler`). The Kotlin mirror lives in
// `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/bridge/ScopeWire.kt`.

import Foundation
import OpenZCineCore

/// Core-driven scope payloads for the Compose shell: the MATH (anchor axis
/// placement, curve mapping, chroma binning, tone-mapped vectorscope) runs in
/// the shared Swift core; Kotlin only draws the returned records.
///
/// All display levels use the 3-anchor axis (`ScopeDisplayScale.waveformLevel`):
/// the curve's log-black floor lands on the crush line 5% up, mid grey sits at
/// its FIXED per-curve level (never moved by ISO/exposure), and the ISO
/// clip-warning code lands on the clip line 5% down from the top.
public enum ScopeFrameWire {
    /// Floats per point record in ``traces``: `x, luma, red, green, blue`
    /// (x is 0…1 across the frame; the rest are anchored display levels 0…1).
    public static let pointStride = 5

    /// Bins per remapped histogram channel (display-axis buckets).
    public static let histogramBins = 256

    /// Vectorscope density grid axis (matches the iOS panels).
    public static let vectorBinCount = 128

    /// Sampling step in pixels — the iOS live tap's `ScopeAssistSampling.pointStride`.
    public static let sampleStride = 2

    /// Additive `traces` trailer marker. Current Kotlin shells continue to
    /// accept the exact pre-trailer payload from an older core binary, and
    /// require this marker before rendering a Swift-derived Traffic Lights
    /// result.
    public static let trafficTrailerMagic: Float = 31_415

    /// Additive `traces` trailer format version.
    public static let trafficTrailerVersion: Float = 1

    /// Floats per RGB Traffic Lights channel in the additive trailer:
    /// `level, clip, crush, side, fill`.
    public static let trafficChannelStride = 5

    /// Total floats in the Traffic Lights trailer: marker, version, and
    /// three RGB channel records.
    public static let trafficTrailerFloatCount = 2 + 3 * trafficChannelStride

    /// `ExposureToneCurve` for a wire ordinal: 0 = RED Log3G10 (the ZR live-view
    /// default and the iOS fallback), 1 = Nikon N-Log.
    static func curve(ordinal: Int) -> ExposureToneCurve {
        ordinal == 1 ? .nikonNLog : .redLog3G10
    }

    /// Decodes Android's persisted raw compensation selector with the same
    /// safety policy as the core's Codable migration: exact current values
    /// win, older values above the 1-stop ceiling clamp high, and other
    /// malformed values clamp low.
    private static func crushClipCompensation(
        rawValue: Int
    ) -> AssistConfiguration.CrushClipCompensation {
        AssistConfiguration.CrushClipCompensation(rawValue: rawValue)
            ?? (rawValue > AssistConfiguration.CrushClipCompensation.one.rawValue ? .one : .zero)
    }

    /// Fixed axis anchors and graticule constants for one curve:
    /// `[crushLine, middleGrayLevel, clipLine]` followed by six `(cb, cr)`
    /// pairs — the 75% R/Mg/B/Cy/G/Yl vectorscope targets from the core's
    /// BT.709 chroma matrix, each component in −0.5…+0.5.
    ///
    /// Mid grey is per-curve and deliberately independent of ISO/exposure:
    /// `ScopeDisplayScale.middleGrayLevel(curve:)` pins it where 18% grey sits
    /// at the curve's published base-ISO clip. Only the highlight segment
    /// re-stretches when the camera's clip warning moves.
    public static func anchors(curveOrdinal: Int) -> [Float] {
        let curve = curve(ordinal: curveOrdinal)
        var out: [Float] = [
            Float(ScopeDisplayScale.crushLineLevel),
            Float(ScopeDisplayScale.middleGrayLevel(curve: curve)),
            Float(ScopeDisplayScale.clipLineLevel),
        ]
        // 75% colour-bar targets (191 = 0.75 × 255) — same values the iOS
        // graticule feeds through `VectorscopeSampler.chroma`.
        let targets: [(red: UInt8, green: UInt8, blue: UInt8)] = [
            (191, 0, 0), (191, 0, 191), (0, 0, 191),
            (0, 191, 191), (0, 191, 0), (191, 191, 0),
        ]
        for target in targets {
            let (cb, cr) = VectorscopeSampler.chroma(
                red: target.red, green: target.green, blue: target.blue)
            out.append(Float(cb))
            out.append(Float(cr))
        }
        return out
    }

    /// Samples one downsampled RGBA frame for the waveform / parade / histogram
    /// scopes and returns the flattened payload:
    ///
    /// `[N, (x, luma, red, green, blue) × N, 256 luma bins, 256 red, 256 green, 256 blue,
    /// traffic trailer]`
    ///
    /// Point levels and histogram buckets are already on the anchored display
    /// axis, so the shell places pixels without re-deriving any curve math.
    /// The additive traffic trailer contains the shared core's existing
    /// ``TrafficLightsMeter`` reading, never a Kotlin remeasurement:
    /// `[magic, version, (level, clip, crush, side, fill) × RGB]`. `side` is
    /// 0 = neutral, 1 = over, 2 = under; `fill` is the core's normalized
    /// goal-post fill. Invalid buffer geometry yields `[0]`, four empty
    /// histograms, and the core's empty-sample reading.
    ///
    /// - Parameter crushClipCompensationRaw: Raw value for the persisted
    ///   shared-core `CrushClipCompensation` selector. It defaults to iOS's
    ///   `.quarter` migration default for direct Swift callers.
    public static func traces(
        rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int, curveOrdinal: Int,
        crushClipCompensationRaw: Int = AssistConfiguration.CrushClipCompensation.quarter.rawValue
    ) -> [Float] {
        let mapping = ExposureSignalMapping(curve: curve(ordinal: curveOrdinal))
        let samples = ScopeSampler.sample(
            rgba: rgba, width: width, height: height, bytesPerRow: bytesPerRow,
            stride: sampleStride)
        var out = [Float]()
        out.reserveCapacity(
            1 + samples.points.count * pointStride + 4 * histogramBins
                + trafficTrailerFloatCount)
        out.append(Float(samples.points.count))
        func level(_ native: UInt8) -> Float {
            Float(
                ScopeDisplayScale.waveformLevel(
                    signalNative: Double(native), mapping: mapping))
        }
        for point in samples.points {
            out.append(Float(point.xRatio))
            out.append(level(point.luma))
            out.append(level(point.red))
            out.append(level(point.green))
            out.append(level(point.blue))
        }
        let histograms = [
            samples.histogramLuma, samples.histogramRed,
            samples.histogramGreen, samples.histogramBlue,
        ]
        for histogram in histograms {
            let remapped = ScopeDisplayScale.remapHistogram(histogram, mapping: mapping)
            for bin in remapped {
                out.append(Float(bin))
            }
        }
        appendTrafficLights(
            samples: samples,
            mapping: mapping,
            crushClipCompensation: crushClipCompensation(rawValue: crushClipCompensationRaw),
            to: &out)
        return out
    }

    /// Appends the UI-only goal-post records generated by the shared core.
    /// Android receives the display direction and fill already resolved so it
    /// cannot accidentally drift from iOS's `TrafficLightsMeter` math.
    private static func appendTrafficLights(
        samples: ScopeSamples,
        mapping: ExposureSignalMapping,
        crushClipCompensation: AssistConfiguration.CrushClipCompensation,
        to out: inout [Float]
    ) {
        let reading = TrafficLightsMeter.measure(
            samples: samples,
            noiseFloorCompensation: crushClipCompensation,
            mapping: mapping)
        out.append(trafficTrailerMagic)
        out.append(trafficTrailerVersion)
        for channel in [reading.red, reading.green, reading.blue] {
            let display = TrafficLightsMeter.channelDisplay(for: channel)
            let side: Float =
                switch display.side {
                case .neutral: 0
                case .over: 1
                case .under: 2
                }
            out.append(Float(channel.level))
            out.append(channel.clip ? 1 : 0)
            out.append(channel.crush ? 1 : 0)
            out.append(side)
            out.append(Float(display.barFill))
        }
    }

    /// Built-in monitor looks for the vectorscope's tone-mapped domain, built
    /// once — the same `MonitorLUT` cubes the iOS shell falls back to when no
    /// operator LUT is active.
    private static let log3G10MonitorCube = MonitorLUT.log3G10Rec709.cube()
    private static let nLogMonitorCube = MonitorLUT.nLogRec709.cube()

    /// Samples one downsampled RGBA frame for the vectorscope and returns the
    /// 128×128 premultiplied-RGBA density image (row 0 at +Cr, ready to blit).
    ///
    /// The clean log points are pushed through the built-in display tone map
    /// (`MonitorLUT` — v1 has no operator LUTs on Android, matching the iOS
    /// no-LUT fallback), binned by BT.709 CbCr, then rasterized with the same
    /// log-density ramp and trace tint as the iOS shell's
    /// `VectorscopeDensityRasterizer` at default brightness. Empty when the
    /// frame yields no samples.
    public static func vectorPixels(
        rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int, curveOrdinal: Int
    ) -> [UInt8] {
        let samples = ScopeSampler.sample(
            rgba: rgba, width: width, height: height, bytesPerRow: bytesPerRow,
            stride: sampleStride)
        let cube = curveOrdinal == 1 ? nLogMonitorCube : log3G10MonitorCube
        let monitorPoints = VectorscopeSampler.monitorPoints(samples.points, through: cube)
        let bins = VectorscopeSampler.accumulate(
            points: monitorPoints, binCount: vectorBinCount, gain: 1)
        let n = bins.binCount
        guard n > 0, bins.peak > 0 else { return [] }
        let peak = Double(bins.peak)
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for index in 0..<bins.counts.count {
            let count = bins.counts[index]
            guard count > 0 else { continue }
            // Logarithmic density ramp (phosphor-style) — keeps single-pixel
            // chroma readable while dense regions still glow.
            let density = log(1 + Double(count)) / log(1 + peak)
            let alpha = min(1, max(0, 0.4 + 0.6 * density))
            let tint = bins.averageColor(at: index).traceTint
            // Flip rows so +Cr renders upward (bins store row 0 at −Cr).
            let row = n - 1 - index / n
            let column = index % n
            let offset = (row * n + column) * 4
            pixels[offset] = UInt8(255 * tint.red * alpha)
            pixels[offset + 1] = UInt8(255 * tint.green * alpha)
            pixels[offset + 2] = UInt8(255 * tint.blue * alpha)
            pixels[offset + 3] = UInt8(255 * alpha)
        }
        return pixels
    }
}
