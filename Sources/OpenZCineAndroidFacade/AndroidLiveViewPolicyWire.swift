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
public enum AndroidLiveViewPolicyWire {
    /// The existing Android facade live-view cadence, approximately 30 fps.
    public static let standardFrameIntervalNanoseconds: UInt64 = 33_000_000

    /// Resolves a safe Android preview request, or `nil` for an unknown wire value.
    public static func resolve(
        streamPresetRaw: Int,
        qualityBiasRaw: Int,
        thermalTierRaw: Int,
        isRecording: Bool,
        cameraOverheating: Bool
    ) -> AndroidLiveViewRequest? {
        guard
            let streamPreset = OperatorPreferences.StreamPreset.allCases[safe: streamPresetRaw],
            let qualityBias = OperatorPreferences.QualityBias.allCases[safe: qualityBiasRaw],
            let thermalTier = ThermalTier(rawValue: thermalTierRaw)
        else { return nil }

        let imageSize = LiveViewLoadPolicy.effectiveImageSize(
            requested: streamPreset.liveViewImageSize,
            isRecording: isRecording,
            thermalTier: thermalTier,
            cameraOverheating: cameraOverheating)
        let interval = UInt64(
            (Double(standardFrameIntervalNanoseconds) * thermalTier.cadenceMultiplier).rounded())
        return AndroidLiveViewRequest(
            imageSize: imageSize,
            compression: qualityBias.liveViewImageCompression,
            frameIntervalNanoseconds: max(standardFrameIntervalNanoseconds, interval))
    }

    /// Encodes the safe request as `size<TAB>compression<TAB>intervalNanos` for JNI.
    public static func encode(_ request: AndroidLiveViewRequest) -> String {
        "\(request.imageSize)\t\(request.compression)\t\(request.frameIntervalNanoseconds)"
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
