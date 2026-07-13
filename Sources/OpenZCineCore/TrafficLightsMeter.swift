import Foundation

/// Which half of a goal-post column shows level fill — exposure balance reads from centre gray.
public enum TrafficLightsBarSide: Equatable, Sendable {
    /// Within the balance dead-zone around mid grey — no directional fill.
    case neutral
    /// Level sits above centre — highlight / over-exposure lean.
    case over
    /// Level sits below centre — shadow / under-exposure lean.
    case under
}

/// Directional bar fill derived from a channel level relative to mid grey (0.5).
public struct TrafficLightsChannelDisplay: Equatable, Sendable {
    /// Which half of the post carries the level bar.
    public let side: TrafficLightsBarSide
    /// Normalized fill within the active half-post (0 = none, 1 = full half).
    public let barFill: Double

    public init(side: TrafficLightsBarSide, barFill: Double) {
        self.side = side
        self.barFill = min(1, max(0, barFill))
    }

    public static let neutral = TrafficLightsChannelDisplay(side: .neutral, barFill: 0)
}

/// Per-channel readout for the RED-style Traffic Lights goal-post meter.
public struct TrafficLightsChannelReading: Equatable, Sendable {
    /// Normalized reference-IRE level 0…1 on the waveform axis (0.5 = mid grey).
    public let level: Double
    /// Whether the channel piles up at the clip (highlight) edge.
    public let clip: Bool
    /// Whether the channel piles up at the crush (shadow/noise floor) edge.
    public let crush: Bool

    public init(level: Double, clip: Bool, crush: Bool) {
        self.level = min(1, max(0, level))
        self.clip = clip
        self.crush = crush
    }
}

/// RGB traffic-light measurement from one sampled frame.
public struct TrafficLightsReading: Equatable, Sendable {
    public let red: TrafficLightsChannelReading
    public let green: TrafficLightsChannelReading
    public let blue: TrafficLightsChannelReading

    public init(
        red: TrafficLightsChannelReading,
        green: TrafficLightsChannelReading,
        blue: TrafficLightsChannelReading
    ) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let empty = TrafficLightsReading(
        red: TrafficLightsChannelReading(level: 0, clip: false, crush: false),
        green: TrafficLightsChannelReading(level: 0, clip: false, crush: false),
        blue: TrafficLightsChannelReading(level: 0, clip: false, crush: false))
}

/// RGB channel selector for ``TrafficLightsMeter`` level readouts.
public enum TrafficLightsChannel: Sendable {
    case red, green, blue
}

/// Standalone RED-style RGB goal-post meter — reuses ``ScopeSampler/trafficLights(_:green:blue:curve:threshold:)``
/// for per-channel clip/crush dots and derives bar fill from the same ``ScopeDisplayScale/waveformLevel``
/// mapping as the waveform and parade scopes.
public enum TrafficLightsMeter {
    /// Measures per-channel levels and clip/crush flags from scope samples.
    public static func measure(
        samples: ScopeSamples,
        noiseFloorCompensation: AssistConfiguration.CrushClipCompensation,
        curve: ExposureToneCurve = .redLog3G10
    ) -> TrafficLightsReading {
        measure(
            samples: samples, noiseFloorCompensation: noiseFloorCompensation,
            mapping: ExposureSignalMapping(curve: curve))
    }

    public static func measure(
        samples: ScopeSamples,
        noiseFloorCompensation: AssistConfiguration.CrushClipCompensation,
        mapping: ExposureSignalMapping
    ) -> TrafficLightsReading {
        let threshold = noiseFloorCompensation.pixelFractionThreshold
        let lights = ScopeSampler.trafficLights(
            samples: samples, mapping: mapping, threshold: threshold)
        return TrafficLightsReading(
            red: channelReading(
                samples: samples, channel: .red, clip: lights.clipRed, crush: lights.crushRed,
                mapping: mapping),
            green: channelReading(
                samples: samples, channel: .green, clip: lights.clipGreen,
                crush: lights.crushGreen, mapping: mapping),
            blue: channelReading(
                samples: samples, channel: .blue, clip: lights.clipBlue, crush: lights.crushBlue,
                mapping: mapping))
    }

    /// Reference-IRE level 0…1 for one channel — median of sampled pixels on the waveform axis.
    public static func channelLevel(
        samples: ScopeSamples, channel: TrafficLightsChannel, curve: ExposureToneCurve
    ) -> Double {
        channelLevel(
            samples: samples, channel: channel, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func channelLevel(
        samples: ScopeSamples, channel: TrafficLightsChannel, mapping: ExposureSignalMapping
    ) -> Double {
        let histogram = histogram(for: channel, in: samples)
        if histogram.contains(where: { $0 > 0 }) {
            return channelLevel(histogram: histogram, mapping: mapping)
        }
        if !samples.points.isEmpty {
            let level = ScopeSampler.medianWaveformLevel(
                points: samples.points, mapping: mapping, channel: nativeValue(for: channel))
            return balanceLevel(level, mapping: mapping)
        }
        return 0
    }

    /// Reference-IRE level 0…1 from a channel histogram's median native code (GPU histogram path).
    public static func channelLevel(histogram: [Int], curve: ExposureToneCurve) -> Double {
        channelLevel(histogram: histogram, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func channelLevel(
        histogram: [Int], mapping: ExposureSignalMapping
    ) -> Double {
        balanceLevel(
            ScopeSampler.medianWaveformLevel(histogram: histogram, mapping: mapping),
            mapping: mapping)
    }

    /// Goal-post meters remain centered on 18% grey while sharing the scopes' anchored display
    /// axis. This is a display transform only; clip/crush decisions still use native codes.
    private static func balanceLevel(
        _ scopeLevel: Double, mapping: ExposureSignalMapping
    ) -> Double {
        let middle = ScopeDisplayScale.middleGrayLevel(mapping: mapping)
        if scopeLevel <= middle {
            return middle > 0 ? (scopeLevel / middle) * 0.5 : 0
        }
        let upperSpan = max(1 - middle, .leastNonzeroMagnitude)
        return 0.5 + ((scopeLevel - middle) / upperSpan) * 0.5
    }

    private static func channelReading(
        samples: ScopeSamples, channel: TrafficLightsChannel, clip: Bool, crush: Bool,
        mapping: ExposureSignalMapping
    ) -> TrafficLightsChannelReading {
        TrafficLightsChannelReading(
            level: channelLevel(samples: samples, channel: channel, mapping: mapping),
            clip: clip,
            crush: crush)
    }

    private static func histogram(for channel: TrafficLightsChannel, in samples: ScopeSamples)
        -> [Int]
    {
        switch channel {
        case .red: samples.histogramRed
        case .green: samples.histogramGreen
        case .blue: samples.histogramBlue
        }
    }

    private static func nativeValue(for channel: TrafficLightsChannel) -> (ScopePoint) -> UInt8 {
        switch channel {
        case .red: { $0.red }
        case .green: { $0.green }
        case .blue: { $0.blue }
        }
    }

    /// Reference level for a balanced exposure on the waveform / goal-post axis.
    public static let balanceCenter = 0.5

    /// Levels within this distance of ``balanceCenter`` render as neutral (no directional bar).
    public static let balanceDeadZone = 0.03

    /// Maps a channel level to a single-sided goal-post fill — over fills upward from centre,
    /// under fills downward, balanced stays neutral.
    public static func channelDisplay(
        for reading: TrafficLightsChannelReading,
        balanceCenter center: Double = balanceCenter,
        deadZone: Double = balanceDeadZone
    ) -> TrafficLightsChannelDisplay {
        let deviation = reading.level - center
        if abs(deviation) <= deadZone {
            return .neutral
        }
        if deviation > 0 {
            let span = max(1 - center, .leastNonzeroMagnitude)
            return TrafficLightsChannelDisplay(
                side: .over, barFill: min(1, deviation / span))
        }
        let span = max(center, .leastNonzeroMagnitude)
        return TrafficLightsChannelDisplay(
            side: .under, barFill: min(1, abs(deviation) / span))
    }
}
