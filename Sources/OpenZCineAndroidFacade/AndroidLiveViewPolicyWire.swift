import Foundation
import OpenCineNikonAndroid
import OpenZCineCore

/// The app half of the Android live-view wire: resolving the operator's persisted stream choices
/// (`OperatorPreferences`) and the host thermal tier. The request type, the 60 Hz pull constants
/// and `encode` live in OpenCineNikonAndroid with the session that applies them.
extension AndroidLiveViewPolicyWire {
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
            let streamPreset = LiveViewStreamPreset.allCases[safe: streamPresetRaw],
            let qualityBias = LiveViewQualityBias.allCases[safe: qualityBiasRaw],
            let thermalTier = ThermalTier(rawValue: thermalTierRaw)
        else { return nil }

        // The operator's preset is honoured unconditionally; no thermal or recording step-down.
        return AndroidLiveViewRequest(
            imageSize: imageSize(for: streamPreset),
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

    private static func imageSize(for preset: LiveViewStreamPreset) -> UInt8 {
        preset.liveViewImageSize
    }

    private static func compression(for bias: LiveViewQualityBias) -> UInt8 {
        bias.liveViewImageCompression
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
