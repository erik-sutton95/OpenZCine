import Foundation

/// Coarse capability tiers for Z-series bodies, used to gate stills and movie features.
///
/// Profiles are inferred from product-line capability clusters (legacy 2-byte prop
/// discovery vs extended vendor-code lists), not from hard-coded model strings alone.
/// Always prefer live `GetDeviceInfo` / vendor-code enumeration when available.
public enum ZCameraCapabilityTier: String, Equatable, Sendable, CaseIterable {
    /// Early Z bodies using `GetVendorPropCodes` (0x90CA) and 2-byte properties.
    case legacy
    /// Mid generation with `ChangeApplicationMode` (0x9435) and expanded stills.
    case gen2
    /// Extended vendor codes, Ex property lists, open capture, HLG PicCtrl.
    case extended
    /// Cinema / flagship remote surface (ZR and peers with movie-first props).
    case cinema
}

/// Static hints for known product lines. Runtime vendor-code lists override these.
public enum ZCameraCapabilityProfile: Sendable {
    /// Best-effort tier from a PTP `Model` string (e.g. from GetDeviceInfo).
    public static func tier(forModelName model: String) -> ZCameraCapabilityTier {
        let normalized = model.uppercased().replacingOccurrences(of: " ", with: "")
        if normalized.contains("ZR") { return .cinema }
        if normalized.contains("Z9") || normalized.contains("Z8") || normalized.contains("Z6III") {
            return .extended
        }
        if normalized.contains("Z5II") || normalized.contains("Z50II") || normalized.contains("ZF")
            || normalized.contains("Z6_2") || normalized.contains("Z6II")
            || normalized.contains("Z7_2") || normalized.contains("Z7II")
        {
            return .gen2
        }
        if normalized.contains("Z30") || normalized.contains("Z50") || normalized.contains("ZFC")
            || normalized.contains("Z5") || normalized.contains("Z6") || normalized.contains("Z7")
        {
            return .legacy
        }
        return .extended
    }

    /// Whether the body is expected to expose `LiveViewSelector` for photo/video chrome.
    public static func supportsLiveViewSelector(tier: ZCameraCapabilityTier) -> Bool {
        true  // Present across the Z set researched for this release.
    }

    /// Whether still capture to media (`0x9207`) is expected.
    public static func supportsCaptureRecInMedia(tier: ZCameraCapabilityTier) -> Bool {
        true
    }

    /// Whether open capture / interval tools are expected.
    public static func supportsOpenCapture(tier: ZCameraCapabilityTier) -> Bool {
        switch tier {
        case .legacy: return false
        case .gen2, .extended, .cinema: return true
        }
    }

    /// Preferred application-mode path: operation `0x9435` vs property `0xD1F0`.
    public static func prefersChangeApplicationModeOperation(
        tier: ZCameraCapabilityTier
    ) -> Bool {
        switch tier {
        case .legacy: return false
        case .gen2, .extended, .cinema: return true
        }
    }
}

extension PTPPropertyCode {
    /// Whether this property is primarily used by the photography chrome.
    public var isStillsOriented: Bool {
        switch self {
        case .liveViewSelector, .stillCaptureMode, .burstNumber, .imageSize,
            .compressionSetting, .rawCompressionType, .exposureTime, .fNumber,
            .exposureIndex, .exposureBiasCompensation, .exposureMeteringMode,
            .flashMode, .focusMode, .stillFocusMode, .stillFocusMeteringMode,
            .stillISOAutoControl, .stillShutterSpeed, .recordingMedia, .whiteBalance:
            return true
        default:
            return false
        }
    }
}
