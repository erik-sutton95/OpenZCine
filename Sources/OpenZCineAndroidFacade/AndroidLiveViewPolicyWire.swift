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
/// Kotlin supplies only its persisted choice, host thermal observation, and the
/// camera-advertised recording frame rate. This facade resolves the Nikon byte
/// values and applies ``LiveViewLoadPolicy`` in Swift, keeping camera protocol
/// policy out of Compose. The result controls only a disposable preview stream;
/// it never changes the camera's recording configuration.
public enum AndroidLiveViewPolicyWire {
    /// Fallback cadence when the body has not reported a recording frame rate.
    public static let defaultRecordingFrameRate = 30

    /// Fastest preview pull the Android pump accepts (~60 fps).
    public static let minimumFrameIntervalNanoseconds: UInt64 = 16_666_667

    /// Slowest preview pull under thermal shedding (~10 fps).
    public static let maximumFrameIntervalNanoseconds: UInt64 = 100_000_000

    /// Default interval for ``defaultRecordingFrameRate`` (1_000_000_000 / 30).
    public static let standardFrameIntervalNanoseconds: UInt64 =
        1_000_000_000 / UInt64(defaultRecordingFrameRate)

    /// Resolves a safe Android preview request, or `nil` for an unknown wire value.
    ///
    /// - Parameter recordingFrameRate: Camera-advertised movie frame rate in
    ///   whole fps (e.g. 25 for 6K·25p). `nil` or non-positive values fall
    ///   back to ``defaultRecordingFrameRate``. Thermal shedding only slows
    ///   the resulting pull cadence; it never speeds it past the recording rate.
    public static func resolve(
        streamPresetRaw: Int,
        qualityBiasRaw: Int,
        thermalTierRaw: Int,
        isRecording: Bool,
        cameraOverheating: Bool,
        recordingFrameRate: Int? = nil
    ) -> AndroidLiveViewRequest? {
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
            frameIntervalNanoseconds: frameIntervalNanoseconds(
                recordingFrameRate: recordingFrameRate,
                thermalTier: thermalTier))
    }

    /// Preview pull interval for a recording frame rate, after thermal shedding.
    public static func frameIntervalNanoseconds(
        recordingFrameRate: Int?,
        thermalTier: ThermalTier = .nominal
    ) -> UInt64 {
        let fps = clampedRecordingFrameRate(recordingFrameRate)
        let baseNanos = 1_000_000_000 / UInt64(fps)
        let scaled = UInt64((Double(baseNanos) * thermalTier.cadenceMultiplier).rounded())
        return min(
            max(scaled, minimumFrameIntervalNanoseconds),
            maximumFrameIntervalNanoseconds)
    }

    /// Encodes the safe request as `size<TAB>compression<TAB>intervalNanos` for JNI.
    public static func encode(_ request: AndroidLiveViewRequest) -> String {
        "\(request.imageSize)\t\(request.compression)\t\(request.frameIntervalNanoseconds)"
    }

    private static func clampedRecordingFrameRate(_ raw: Int?) -> Int {
        guard let raw, raw > 0 else { return defaultRecordingFrameRate }
        // Cinema-body practical envelope for the disposable JPEG monitor stream.
        return min(max(raw, 1), 60)
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
