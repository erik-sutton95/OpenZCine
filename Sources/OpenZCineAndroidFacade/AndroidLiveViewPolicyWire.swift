import Foundation
import OpenZCineCore

/// Validated live-view request resolved by the shared Swift policy for the Android shell.
public struct AndroidLiveViewRequest: Equatable, Sendable {
    /// Camera JPEG preview size (`1` QVGA, `2` VGA, `3` XGA).
    public let imageSize: UInt8
    /// Camera JPEG preview compression selector.
    public let compression: UInt8
    /// Minimum interval between Android preview pulls, in monotonic nanoseconds.
    public let frameIntervalNanoseconds: UInt64

    /// Creates a Swift-owned preview request.
    public init(imageSize: UInt8, compression: UInt8, frameIntervalNanoseconds: UInt64) {
        self.imageSize = imageSize
        self.compression = compression
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
    }
}

/// Coarse Android JNI wire for shared live-view stream policy.
///
/// Kotlin supplies only its persisted choice and host thermal observation.
/// This facade resolves the Nikon byte values and applies
/// ``LiveViewLoadPolicy`` in Swift, keeping camera protocol policy out of
/// Compose. The result controls only a disposable preview stream; it never
/// changes the camera's recording configuration.
///
/// Preview pull cadence is **always** ``targetFrameRate`` (60 Hz). Thermal
/// shedding may still drop preview JPEG size; it never slows the pull target.
public enum AndroidLiveViewPolicyWire {
    /// Fixed monitor pull rate (always).
    public static let targetFrameRate = 60

    /// Preview pull interval for ``targetFrameRate`` (~16.7 ms at 60 Hz).
    public static let minimumFrameIntervalNanoseconds: UInt64 =
        1_000_000_000 / UInt64(targetFrameRate)

    /// Slowest accepted configure interval (validation only; policy never emits this).
    public static let maximumFrameIntervalNanoseconds: UInt64 = 100_000_000

    /// Always equal to the 60 Hz target interval.
    public static let standardFrameIntervalNanoseconds: UInt64 =
        minimumFrameIntervalNanoseconds

    /// Resolves a safe Android preview request, or `nil` for an unknown wire value.
    ///
    /// - Parameter recordingFrameRate: Ignored. Kept on the wire so older JNI
    ///   callers that still pass a body frame rate stay binary-compatible; the
    ///   monitor always targets ``targetFrameRate`` (60 Hz).
    public static func resolve(
        streamPresetRaw: Int,
        qualityBiasRaw: Int,
        thermalTierRaw: Int,
        isRecording: Bool,
        cameraOverheating: Bool,
        recordingFrameRate: Int? = nil
    ) -> AndroidLiveViewRequest? {
        _ = recordingFrameRate
        guard
            let streamPreset = OperatorPreferences.StreamPreset.allCases[safe: streamPresetRaw],
            let qualityBias = OperatorPreferences.QualityBias.allCases[safe: qualityBiasRaw],
            let thermalTier = ThermalTier(rawValue: thermalTierRaw)
        else { return nil }

        let imageSize = LiveViewLoadPolicy.effectiveImageSize(
            requested: imageSize(for: streamPreset),
            isRecording: isRecording,
            thermalTier: thermalTier,
            cameraOverheating: cameraOverheating)
        return AndroidLiveViewRequest(
            imageSize: imageSize,
            compression: compression(for: qualityBias),
            frameIntervalNanoseconds: frameIntervalNanoseconds())
    }

    /// Always the fixed 60 Hz pull interval.
    ///
    /// - Parameter thermalTier: Ignored. Kept so existing call sites compile;
    ///   thermal load sheds JPEG size, not cadence.
    public static func frameIntervalNanoseconds(
        thermalTier: ThermalTier = .nominal
    ) -> UInt64 {
        _ = thermalTier
        return standardFrameIntervalNanoseconds
    }

    /// Encodes the safe request as `size<TAB>compression<TAB>intervalNanos` for JNI.
    public static func encode(_ request: AndroidLiveViewRequest) -> String {
        "\(request.imageSize)\t\(request.compression)\t\(request.frameIntervalNanoseconds)"
    }

    private static func imageSize(for preset: OperatorPreferences.StreamPreset) -> UInt8 {
        switch preset {
        case .fast: 1
        case .balanced: 2
        case .quality: 3
        }
    }

    private static func compression(for bias: OperatorPreferences.QualityBias) -> UInt8 {
        switch bias {
        case .latency: 1
        case .balanced: 2
        case .detail: 3
        }
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
