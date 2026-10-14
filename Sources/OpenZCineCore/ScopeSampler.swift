import Foundation
import OpenCineMedia

public enum ScopeSampler {
    public static func sample(
        rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int, stride: Int = 3,
        includePoints: Bool = true
    ) -> ScopeSamples {
        OpenCineMedia.ScopeSampler.sampleRaw(
            bytes: rgba, width: width, height: height,
            bytesPerRow: bytesPerRow, transfer: .rec709, includePoints: includePoints,
            layout: .rgba, stride: stride, includeSampleCoordinates: true, requireCompleteRows: true
        )
    }
    public static func trafficLights(
        samples: ScopeSamples, curve: ExposureToneCurve, threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        trafficLights(
            samples: samples, mapping: ExposureSignalMapping(curve: curve), threshold: threshold)
    }

    public static func trafficLights(
        samples: ScopeSamples, mapping: ExposureSignalMapping, threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        OpenCineMedia.LegacyScopePolicy.trafficLights(
            samples: samples, calibration: mapping.legacyScopeCalibration, threshold: threshold)
    }
    public static func medianWaveformLevel(
        points: [ScopePoint], curve: ExposureToneCurve, channel: (ScopePoint) -> UInt8
    ) -> Double {
        medianWaveformLevel(
            points: points, mapping: ExposureSignalMapping(curve: curve), channel: channel)
    }

    public static func medianWaveformLevel(
        points: [ScopePoint], mapping: ExposureSignalMapping, channel: (ScopePoint) -> UInt8
    ) -> Double {
        OpenCineMedia.LegacyScopePolicy.medianWaveformLevel(
            points: points, calibration: mapping.legacyScopeCalibration, channel: channel)
    }
    public static func medianWaveformLevel(histogram: [Int], curve: ExposureToneCurve) -> Double {
        medianWaveformLevel(histogram: histogram, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func medianWaveformLevel(
        histogram: [Int], mapping: ExposureSignalMapping
    ) -> Double {
        OpenCineMedia.LegacyScopePolicy.medianWaveformLevel(
            histogram: histogram, calibration: mapping.legacyScopeCalibration)
    }
    public static func trafficLights(
        red: [Int], green: [Int], blue: [Int], curve: ExposureToneCurve, threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        trafficLights(
            red: red, green: green, blue: blue,
            mapping: ExposureSignalMapping(curve: curve), threshold: threshold)
    }

    public static func trafficLights(
        red: [Int], green: [Int], blue: [Int], mapping: ExposureSignalMapping,
        threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        OpenCineMedia.LegacyScopePolicy.trafficLights(
            red: red, green: green, blue: blue, calibration: mapping.legacyScopeCalibration,
            threshold: threshold)
    }
    public static func trafficClipEdge(curve: ExposureToneCurve) -> Int {
        trafficClipEdge(mapping: ExposureSignalMapping(curve: curve))
    }

    public static func trafficClipEdge(mapping: ExposureSignalMapping) -> Int {
        OpenCineMedia.LegacyScopePolicy.trafficClipEdge(calibration: mapping.legacyScopeCalibration)
    }
    public static func trafficCrushFloor(curve: ExposureToneCurve) -> Int {
        trafficCrushFloor(mapping: ExposureSignalMapping(curve: curve))
    }

    public static func trafficCrushFloor(mapping: ExposureSignalMapping) -> Int {
        OpenCineMedia.LegacyScopePolicy.trafficCrushFloor(
            calibration: mapping.legacyScopeCalibration)
    }
    public static func trafficCrushEdge(curve: ExposureToneCurve) -> Int {
        trafficCrushEdge(mapping: ExposureSignalMapping(curve: curve))
    }

    public static func trafficCrushEdge(mapping: ExposureSignalMapping) -> Int {
        OpenCineMedia.LegacyScopePolicy.trafficCrushEdge(
            calibration: mapping.legacyScopeCalibration)
    }
}

public typealias HistogramTrafficLights = OpenCineMedia.LegacyHistogramTrafficLights
