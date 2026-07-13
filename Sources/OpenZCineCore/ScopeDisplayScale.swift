import Foundation

/// Scope traces anchor the signal's useful range to fixed safe-border lines: the curve's log-black
/// floor lands exactly on the crush line 5% up from the bottom, and the ISO-dependent overexposure
/// warning code lands exactly on the clip line 5% down from the top. The borders themselves never
/// move — ISO changes re-stretch the signal between them, so "on the crush line" always means
/// "at true black" and "on the clip line" always means "the camera will clip here". Sub-black and
/// super-clip codes keep their gradation in the 5% margins beyond the lines instead of piling up.
public enum ScopeDisplayScale {
    public static let legalBlackCode: Double = 16
    public static let legalWhiteCode: Double = 235

    /// Fixed display positions of the safe-border lines (fraction of plot height from the bottom).
    public static let crushLineLevel = 0.05
    public static let clipLineLevel = 0.95

    public static func middleGrayCode(curve: ExposureToneCurve) -> Double {
        curve.middleGrayNativeCode
    }

    public static func clipWarningCode(curve: ExposureToneCurve) -> Double {
        ExposureSignalMapping(curve: curve).clipNative
    }

    public static func clipWarningCode(mapping: ExposureSignalMapping) -> Double {
        mapping.clipNative
    }

    public static func logBlackFloorCode(curve: ExposureToneCurve) -> Double {
        curve.encode(linearLight: 0) * 255
    }

    /// Raw native code position (0…255 → 0…1), kept for diagnostics.
    public static func nativeCodeLevel(signalNative: Double) -> Double {
        min(255, max(0, signalNative)) / 255.0
    }

    public static func waveformLevel(signalNative: Double, curve: ExposureToneCurve) -> Double {
        waveformLevel(signalNative: signalNative, mapping: ExposureSignalMapping(curve: curve))
    }

    /// The waveform/parade y for a native code — piecewise with THREE fixed anchors:
    /// `[0…blackFloor] → [0…crushLine]`, `[blackFloor…midGray] → [crushLine…middleGrayLevel]`,
    /// `[midGray…clipWarning] → [middleGrayLevel…clipLine]`, `[clipWarning…255] → [clipLine…1]`.
    /// Middle grey NEVER moves with ISO or any exposure change — its display position is fixed per
    /// curve (``middleGrayLevel(curve:)``); an ISO shift of the clip-warning code only re-stretches
    /// the segment above mid grey. Monotonic across the full native range.
    public static func waveformLevel(
        signalNative: Double, mapping: ExposureSignalMapping
    ) -> Double {
        let native = min(255, max(0, signalNative))
        let black = mapping.blackNative
        let mid = mapping.curve.middleGrayNativeCode
        let clip = max(mapping.clipNative, mid + 1)
        let midLevel = middleGrayLevel(curve: mapping.curve)
        if native < black {
            guard black > 0 else { return crushLineLevel }
            return native / black * crushLineLevel
        }
        if native <= mid {
            return crushLineLevel + (native - black) / (mid - black)
                * (midLevel - crushLineLevel)
        }
        if native <= clip {
            return midLevel + (native - mid) / (clip - mid) * (clipLineLevel - midLevel)
        }
        let headroom = 255 - clip
        guard headroom > 0 else { return clipLineLevel }
        return clipLineLevel + (native - clip) / headroom * (1 - clipLineLevel)
    }

    public static var legalBlackLevel: Double { nativeCodeLevel(signalNative: legalBlackCode) }
    public static var legalWhiteLevel: Double { nativeCodeLevel(signalNative: legalWhiteCode) }

    /// Mid grey's FIXED display position per curve — where 18% grey sits when the clip warning is
    /// at the curve's published default (base ISO). Exposure/ISO changes never move it: the axis
    /// pins it here and re-stretches only the highlight segment above.
    public static func middleGrayLevel(curve: ExposureToneCurve) -> Double {
        let black = curve.encode(linearLight: 0) * 255
        let mid = curve.middleGrayNativeCode
        let defaultClip = max(curve.defaultClipNative, mid + 1)
        return crushLineLevel + (mid - black) / (defaultClip - black)
            * (clipLineLevel - crushLineLevel)
    }

    /// Convenience for callers holding a mapping — the level depends only on the curve.
    public static func middleGrayLevel(mapping: ExposureSignalMapping) -> Double {
        middleGrayLevel(curve: mapping.curve)
    }

    public static func middleGrayNativeLevel(curve: ExposureToneCurve) -> Double {
        nativeCodeLevel(signalNative: middleGrayCode(curve: curve))
    }

    public static func clipWarningNativeLevel(curve: ExposureToneCurve) -> Double {
        nativeCodeLevel(signalNative: clipWarningCode(curve: curve))
    }

    public static func logBlackFloorNativeLevel(curve: ExposureToneCurve) -> Double {
        nativeCodeLevel(signalNative: logBlackFloorCode(curve: curve))
    }

    /// Redistributes native histogram bins onto the anchored display axis so the histogram lines
    /// up column-for-column with the waveform.
    public static func remapHistogram(_ histogram: [Int], curve: ExposureToneCurve) -> [Double] {
        remapHistogram(histogram, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func remapHistogram(
        _ histogram: [Int], mapping: ExposureSignalMapping
    ) -> [Double] {
        var out = [Double](repeating: 0, count: 256)
        guard histogram.count == 256 else { return out }
        for native in 0..<256 {
            let level = waveformLevel(signalNative: Double(native), mapping: mapping)
            let bucket = min(255, max(0, Int((level * 255).rounded())))
            out[bucket] += Double(histogram[native])
        }
        return out
    }
}

extension ExposureToneCurve {
    public var middleGrayNativeCode: Double {
        encode(linearLight: 0.18) * 255
    }
}
