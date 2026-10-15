import Foundation
import OpenCineMedia

public typealias TrafficLightsBarSide = OpenCineMedia.LegacyTrafficLightsBarSide
public typealias TrafficLightsChannelDisplay = OpenCineMedia.LegacyTrafficLightsChannelDisplay
public typealias TrafficLightsChannelReading = OpenCineMedia.LegacyTrafficLightsChannelReading
public typealias TrafficLightsReading = OpenCineMedia.LegacyTrafficLightsReading
public typealias TrafficLightsChannel = OpenCineMedia.LegacyTrafficLightsChannel

public typealias TrafficLightsMeter = OpenCineMedia.LegacyTrafficLightsMeter

extension OpenCineMedia.LegacyTrafficLightsMeter {
    public static func measure(
        samples: ScopeSamples,
        noiseFloorCompensation: MonitorCrushClipCompensation,
        curve: ExposureToneCurve = .redLog3G10
    ) -> TrafficLightsReading {
        measure(
            samples: samples, noiseFloorCompensation: noiseFloorCompensation,
            mapping: ExposureSignalMapping(curve: curve))
    }

    public static func measure(
        samples: ScopeSamples,
        noiseFloorCompensation: MonitorCrushClipCompensation,
        mapping: ExposureSignalMapping
    ) -> TrafficLightsReading {
        OpenCineMedia.LegacyTrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: noiseFloorCompensation,
            calibration: mapping.legacyScopeCalibration)
    }
    public static func channelLevel(
        samples: ScopeSamples, channel: TrafficLightsChannel, curve: ExposureToneCurve
    ) -> Double {
        channelLevel(
            samples: samples, channel: channel, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func channelLevel(
        samples: ScopeSamples, channel: TrafficLightsChannel, mapping: ExposureSignalMapping
    ) -> Double {
        OpenCineMedia.LegacyTrafficLightsMeter.channelLevel(
            samples: samples, channel: channel, calibration: mapping.legacyScopeCalibration)
    }
    public static func channelLevel(histogram: [Int], curve: ExposureToneCurve) -> Double {
        channelLevel(histogram: histogram, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func channelLevel(
        histogram: [Int], mapping: ExposureSignalMapping
    ) -> Double {
        OpenCineMedia.LegacyTrafficLightsMeter.channelLevel(
            histogram: histogram, calibration: mapping.legacyScopeCalibration)
    }
}
