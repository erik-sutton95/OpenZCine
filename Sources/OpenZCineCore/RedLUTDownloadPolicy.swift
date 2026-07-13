import Foundation

/// Whether the in-app RED LUT download can run right now, and why not when it can't.
///
/// The download pulls RED's IPP2 preset zip from the public internet. It is unreachable when the
/// phone is joined to the camera's local-only Wi‑Fi access point (no WAN route) or has no network
/// path at all, so the entry point must be blocked with a clear reason rather than presenting a
/// broken/black download screen.
public enum RedLUTDownloadAvailability: Equatable, Sendable {
    /// A usable internet path exists — the download may be entered/attempted.
    case available
    /// Blocked because the phone is on the camera's Wi‑Fi AP, which carries no internet route.
    case blockedOnCameraAccessPoint
    /// Blocked because the OS reports no usable network path at all.
    case blockedNoInternet

    /// Whether the download may proceed.
    public var isAvailable: Bool { self == .available }

    /// User-facing explanation for a blocked state, or `nil` when available.
    public var blockedReason: String? {
        switch self {
        case .available:
            return nil
        case .blockedOnCameraAccessPoint:
            return "Connect to the internet to download RED LUTs — you're on the camera's Wi‑Fi, "
                + "which has no internet."
        case .blockedNoInternet:
            return "Connect to the internet to download RED LUTs — no internet connection is "
                + "available right now."
        }
    }
}

/// Pure decision policy for whether the RED IPP2 LUT download may be entered or attempted.
///
/// Kept UI-free and portable so it can be unit-tested and reused by both platform shells. The
/// SwiftUI shell feeds it a reachability signal (`NWPathMonitor`) and whether the live camera
/// session is running over the camera's Wi‑Fi AP.
public enum RedLUTDownloadPolicy {
    /// Resolves availability from an OS reachability signal (`hasInternetPath` = satisfied network
    /// path) and whether the phone is joined to the camera's local-only Wi‑Fi AP.
    public static func availability(
        hasInternetPath: Bool,
        isOnCameraAccessPoint: Bool
    ) -> RedLUTDownloadAvailability {
        // The camera AP reports a *satisfied* path but has no WAN, so it must be checked first —
        // and named specifically — before the generic "no network path" case.
        if isOnCameraAccessPoint { return .blockedOnCameraAccessPoint }
        if !hasInternetPath { return .blockedNoInternet }
        return .available
    }

    /// Convenience Boolean for call sites that only need to gate on availability.
    public static func canDownloadLUTs(
        hasInternetPath: Bool,
        isOnCameraAccessPoint: Bool
    ) -> Bool {
        availability(hasInternetPath: hasInternetPath, isOnCameraAccessPoint: isOnCameraAccessPoint)
            .isAvailable
    }
}
