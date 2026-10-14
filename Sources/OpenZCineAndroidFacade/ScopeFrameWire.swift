// Flat wire format for the Nikon-owned parts of one scope tick crossing the JNI seam.
//
// Sampling, plots and the vectorscope are the shared OpenCine scopes on the
// Kotlin side (`ScopeView.kt`). This file carries only what the camera owns:
// its anchored level axis and the core Traffic Lights meter. It compiles on
// every platform so `just native-check` exercises it on macOS.

import Foundation
import OpenZCineCore

import enum OpenCineMedia.MonitorCrushClipCompensation

public enum ScopeFrameWire {
    /// Bins per histogram channel in ``trafficLights``.
    public static let histogramBins = 256

    /// Floats per channel in ``trafficLights``: `level, clip, crush`.
    public static let trafficChannelStride = 3

    /// `ExposureToneCurve` for a wire ordinal, mirroring `FeedEffectsWire.curve`:
    /// 0 = RED Log3G10 (the ZR live-view default and the iOS fallback),
    /// 1 = Nikon N-Log, 2 = sRGB and 3 = HLG (the stills previews).
    static func curve(ordinal: Int) -> ExposureToneCurve {
        switch ordinal {
        case 1: .nikonNLog
        case 2: .srgb
        case 3: .hlg
        default: .redLog3G10
        }
    }

    /// The camera mapping for a curve and the camera-resolved clip warning
    /// endpoint; a missing or non-finite clip falls back to the curve default.
    static func mapping(curveOrdinal: Int, clipNative: Double?) -> ExposureSignalMapping {
        let curve = curve(ordinal: curveOrdinal)
        let clip = clipNative.flatMap { $0.isFinite ? $0 : nil } ?? curve.defaultClipNative
        return ExposureSignalMapping(curve: curve, clipNative: clip)
    }

    /// Decodes Android's persisted raw compensation selector with the same
    /// safety policy as the core's Codable migration: exact current values
    /// win, older values above the 1-stop ceiling clamp high, and other
    /// malformed values clamp low.
    private static func crushClipCompensation(
        rawValue: Int
    ) -> MonitorCrushClipCompensation {
        MonitorCrushClipCompensation.fromRaw(rawValue)
    }

    /// The shared scopes' level axis for this camera: `[256 code-to-IRE
    /// levels, middle-grey IRE]`, from `ExposureSignalMapping.scopeLevelAxis`.
    /// Black lands on the crush line, mid grey at its fixed per-curve level and
    /// the ISO clip warning on the clip line, exactly as on iOS.
    public static func levelAxis(curveOrdinal: Int, clipNative: Double? = nil) -> [Float] {
        let axis = mapping(curveOrdinal: curveOrdinal, clipNative: clipNative).scopeLevelAxis
        return axis.table + [Float(axis.middleGrayIRE)]
    }

    /// The core ``TrafficLightsMeter`` reading for the shared sampler's four
    /// 256-bin histograms (luma, red, green, blue, concatenated), as
    /// `(level, clip, crush) × RGB`. Any other input length reads as an empty
    /// frame.
    ///
    /// - Parameter crushClipCompensationRaw: Raw value for the persisted
    ///   shared `MonitorCrushClipCompensation` selector. It defaults to
    ///   `.quarter` for direct Swift callers; Android always passes its stored value.
    public static func trafficLights(
        histograms: [Int], curveOrdinal: Int, clipNative: Double? = nil,
        crushClipCompensationRaw: Int = MonitorCrushClipCompensation.quarter.rawValue
    ) -> [Float] {
        let samples: ScopeSamples
        if histograms.count == 4 * histogramBins {
            func channel(_ index: Int) -> [Int] {
                Array(histograms[(index * histogramBins)..<((index + 1) * histogramBins)])
            }
            samples = ScopeSamples(
                histogramLuma: channel(0), histogramRed: channel(1),
                histogramGreen: channel(2), histogramBlue: channel(3), points: [])
        } else {
            samples = .empty
        }
        let reading = TrafficLightsMeter.measure(
            samples: samples,
            noiseFloorCompensation: crushClipCompensation(rawValue: crushClipCompensationRaw),
            mapping: mapping(curveOrdinal: curveOrdinal, clipNative: clipNative))
        return [reading.red, reading.green, reading.blue].flatMap {
            [Float($0.level), $0.clip ? 1 : 0, $0.crush ? 1 : 0]
        }
    }
}
