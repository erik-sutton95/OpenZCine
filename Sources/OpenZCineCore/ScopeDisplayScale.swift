import Foundation
import OpenCineMedia

public typealias ScopeDisplayScale = OpenCineMedia.LegacyScopePolicy

extension OpenCineMedia.LegacyScopePolicy {
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
    public static func waveformLevel(signalNative: Double, curve: ExposureToneCurve) -> Double {
        waveformLevel(signalNative: signalNative, mapping: ExposureSignalMapping(curve: curve))
    }
    public static func waveformLevel(
        signalNative: Double, mapping: ExposureSignalMapping
    ) -> Double {
        OpenCineMedia.LegacyScopePolicy.waveformLevel(
            signalNative: signalNative, calibration: mapping.legacyScopeCalibration)
    }
    public static func middleGrayLevel(curve: ExposureToneCurve) -> Double {
        OpenCineMedia.LegacyScopePolicy.middleGrayLevel(
            calibration: ExposureSignalMapping(curve: curve).legacyScopeCalibration)
    }
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
    public static func remapHistogram(_ histogram: [Int], curve: ExposureToneCurve) -> [Double] {
        remapHistogram(histogram, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func remapHistogram(
        _ histogram: [Int], mapping: ExposureSignalMapping
    ) -> [Double] {
        OpenCineMedia.LegacyScopePolicy.remapHistogram(
            histogram, calibration: mapping.legacyScopeCalibration)
    }
    public static var legalBlackLevel: Double { nativeCodeLevel(signalNative: legalBlackCode) }
    public static var legalWhiteLevel: Double { nativeCodeLevel(signalNative: legalWhiteCode) }
}

extension ExposureSignalMapping {
    var legacyScopeCalibration: OpenCineMedia.LegacyScopeCalibration {
        OpenCineMedia.LegacyScopeCalibration(
            blackNative: blackNative,
            middleGrayNative: curve.middleGrayNativeCode, clipNative: clipNative,
            defaultClipNative: curve.defaultClipNative,
            crushUpperNative: signalNative(monitorPercent: 2))
    }
}

extension ExposureToneCurve {
    public var middleGrayNativeCode: Double {
        encode(linearLight: 0.18) * 255
    }
}

extension ExposureSignalMapping {
    /// This mapping as the shared scope axis: each tap code at its waveform level (with the 5%
    /// crush/clip shelves), mid grey on its fixed per-curve line. Shared WAVE/PARADE/HISTO plots
    /// draw on it, so Nikon readings keep this placement.
    public var scopeLevelAxis: ScopeLevelAxis {
        ScopeLevelAxis(
            table: (0...255).map {
                Float(
                    ScopeDisplayScale.waveformLevel(signalNative: Double($0), mapping: self) * 100)
            },
            middleGrayIRE: ScopeDisplayScale.middleGrayLevel(mapping: self) * 100)
    }
}
