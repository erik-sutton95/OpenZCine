import Foundation
import OpenZCineCore

/// Versioned, platform-neutral wire helpers for Android's app-private LUT library.
///
/// The Android shell owns the Storage Access Framework, file lifecycle, and presentation; the
/// shared OpenCine `MonitorLutLibrary` owns names and storage. Import trust lives in the shared
/// `CubeLUT.validatedImport` gate, so this facade only packs what that gate accepts through the
/// same `FeedEffectsWire` path as built-in looks. Kotlin never parses cube text or implements LUT
/// sampling.
public enum LUTLibraryWire {
    /// Separator for the compact records returned to Android (ASCII Unit Separator).
    public static let fieldSeparator = "\u{001F}"

    /// Stable version for the compact RED policy record returned to Android. Kotlin rejects a
    /// stale or malformed JNI result before presenting an availability state.
    public static let redAvailabilityRecordVersion = "1"

    /// Validates an app-private cube through the shared import gate and converts it to the exact
    /// packed RGBA8 texture layout used by Android's feed-effects renderer. The renderer-safe
    /// table keeps a 65³ Resolve cube inside the Android 8×8 atlas and iOS `CIColorCube` (both cap
    /// at 64). The caller must reject a nil result rather than attempting a Kotlin fallback.
    public static func packedImportedLUT(utf8: [UInt8]) -> [UInt8]? {
        guard let cube = CubeLUT.validatedImport(utf8) else { return nil }
        return FeedEffectsWire.packedRGBA(cube: cube.preparedForRenderer())
    }

    /// Android's strict RED network guard. The shell supplies platform reachability and whether its
    /// active camera connection is on the local-only camera AP; `RedLUTDownloadPolicy` owns the
    /// decision and its precedence. Returns `[version, state]`, where state is 0 = available,
    /// 1 = camera AP, 2 = no internet.
    public static func redDownloadAvailability(
        hasInternetPath: Bool, isOnCameraAccessPoint: Bool
    ) -> String {
        let state: Int
        switch RedLUTDownloadPolicy.availability(
            hasInternetPath: hasInternetPath, isOnCameraAccessPoint: isOnCameraAccessPoint)
        {
        case .available: state = 0
        case .blockedOnCameraAccessPoint: state = 1
        case .blockedNoInternet: state = 2
        }
        return [redAvailabilityRecordVersion, String(state)].joined(separator: fieldSeparator)
    }
}
