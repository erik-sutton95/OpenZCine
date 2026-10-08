import Foundation
import OpenCineRelay

@_exported import struct OpenCineRelay.RelayEncodeLane
@_exported import enum OpenCineRelay.RelayEncoderProfile

/// Existing source-specific camera feed facts, supplied to the common threshold calculation.
public enum RelayCameraStarvePolicy {
    public static let absoluteFloorFPS: Double = 15
    public static let baselineFraction: Double = 0.72
    private static let policy = RelayCameraStarvationPolicy(
        absoluteFloorFPS: absoluteFloorFPS, baselineFraction: baselineFraction)

    public static func starveThresholdFPS(soloBaselineFPS: Double) -> Double {
        policy.threshold(soloBaselineFPS: soloBaselineFPS)
    }
}

/// Stored API shape over the existing shared adaptation state; no copied moving-window policy.
public struct RelayBitrateAdaptation: Equatable, Sendable {
    private static let policy = RelayBitratePolicy()
    public static let ladder = policy.ladder
    public static let maxFrameQPLadder = policy.maxFrameQPLadder
    public static let stepDownSaturation = policy.stepDownSaturation
    public static let stepUpSaturation = policy.stepUpSaturation
    public static let windowSeconds = policy.windowSeconds
    public static let stepUpAfterCleanSeconds = policy.stepUpAfterCleanSeconds
    private var adaptation: WatcherRelayBitrate
    public var rungIndex: Int { adaptation.rungIndex }
    public var bitsPerSecond: Int { adaptation.bitsPerSecond }
    public var maxFrameQP: Int { adaptation.maxFrameQP }

    public init(now: TimeInterval = 0) {
        adaptation = WatcherRelayBitrate(now: now, policy: Self.policy)
    }
    public mutating func recordTick(saturated: Bool, now: TimeInterval) -> Int? {
        adaptation.recordTick(saturated: saturated, cameraStarving: false, now: now)
    }
}
