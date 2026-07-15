import Foundation
import OpenZCineCore

/// Versioned, platform-neutral wire helpers for Android's app-private LUT library.
///
/// The Android shell owns the Storage Access Framework, file lifecycle, and presentation. This
/// facade is deliberately the only path that accepts source bytes as a `.cube`: it decodes strict
/// UTF-8, invokes the shared `CubeLUT` parser, resolves the shared `LUTSelection.cacheKey`, and
/// packs the cube through the same `FeedEffectsWire` path as built-in looks. Kotlin never parses
/// cube text, implements LUT sampling, or derives a second identity format.
public enum LUTLibraryWire {
    /// Stable record version for `validateImportedLUT`. Fields are separated with ASCII Unit
    /// Separator so user-controlled file labels cannot be ambiguously split by a display delimiter.
    public static let validationRecordVersion = "1"
    public static let fieldSeparator = "\u{001F}"

    /// Stable version for the compact RED policy record returned to Android. It intentionally uses
    /// the same separator as the import record so Kotlin can reject a stale or malformed JNI
    /// result before presenting an availability state.
    public static let redAvailabilityRecordVersion = "1"

    /// Android category ordinals. Keep these private to the cross-platform selection mapping:
    /// 0 = Custom, 1 = RED. Built-ins never cross this import wire.
    public enum CategoryOrdinal {
        public static let custom = 0
        public static let red = 1
    }

    /// Validates an Android-proposed stored file name, strict UTF-8 source, and cube data, then
    /// returns `[version, cubeSize, LUTSelection.cacheKey]`. Nil is intentionally fail-closed: the
    /// shell must not copy any bytes into app-private storage when validation fails.
    public static func validatedImport(
        utf8: [UInt8], categoryOrdinal: Int, fileName: String
    ) -> String? {
        guard let category = category(categoryOrdinal), isSafeStoredFileName(fileName),
            utf8.count <= CubeLUT.maximumSourceBytes,
            let text = String(bytes: utf8, encoding: .utf8),
            let cube = try? CubeLUT.parse(text)
        else { return nil }
        let selection = LUTSelection.stored(category: category, fileName: fileName)
        return [validationRecordVersion, String(cube.size), selection.cacheKey]
            .joined(separator: fieldSeparator)
    }

    /// Re-validates an app-private cube and converts it to the exact packed RGBA8 texture layout
    /// used by Android's existing feed-effects renderer. The caller must reject a nil result rather
    /// than attempting a Kotlin fallback; that preserves the shared parser/colour pipeline as the
    /// sole implementation.
    public static func packedImportedLUT(utf8: [UInt8]) -> [UInt8]? {
        guard utf8.count <= CubeLUT.maximumSourceBytes,
            let text = String(bytes: utf8, encoding: .utf8),
            let cube = try? CubeLUT.parse(text)
        else { return nil }
        return FeedEffectsWire.packedRGBA(cube: cube)
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

    private static func category(_ ordinal: Int) -> LUTCategory? {
        switch ordinal {
        case CategoryOrdinal.custom: .custom
        case CategoryOrdinal.red: .red
        default: nil
        }
    }

    /// Android generates this name after sanitising the picked display label. Keep this mirror at
    /// the trust boundary as well: no `..`, slash, Unicode lookalike, or path-like value can ever
    /// turn a persisted LUT selection into a file-system traversal on either platform.
    private static func isSafeStoredFileName(_ fileName: String) -> Bool {
        guard fileName.utf8.count <= 128, fileName.lowercased().hasSuffix(".cube"),
            !fileName.hasPrefix("."), !fileName.contains("..")
        else { return false }
        return fileName.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                true
            default:
                false
            }
        }
    }
}
