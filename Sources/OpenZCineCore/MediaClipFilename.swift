import Foundation

/// Filename helpers for pairing Nikon ZR proxy MP4/MOV clips with sibling R3D masters.
public enum MediaClipFilename {
    /// Returns `filename` only when it is a single filesystem-safe basename supplied by a camera.
    ///
    /// PTP object names are untrusted network input. Reject path components and control characters
    /// before the app stores, opens, or removes media using the name.
    public static func safeCameraBasename(_ filename: String) -> String? {
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        guard !filename.contains("/"), !filename.contains("\\") else { return nil }
        guard
            !filename.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        guard (filename as NSString).lastPathComponent == filename else { return nil }
        return filename
    }

    /// Lowercased path extension without the dot.
    public static func fileExtension(of filename: String) -> String {
        (filename as NSString).pathExtension.lowercased()
    }

    /// Case-insensitive filename stem used to pair `A002_C046_0630SB.R3D` with `A002_C046_0630SB.MP4`.
    public static func stem(of filename: String) -> String {
        (filename as NSString).deletingPathExtension.uppercased()
    }

    /// True for `.r3d` / `.R3D` cinema masters.
    public static func isR3D(_ filename: String) -> Bool {
        fileExtension(of: filename) == "r3d"
    }

    /// Lowercased extensions treated as still images in the Media browser.
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heif", "heic", "nef", "nrw", "tif", "tiff", "dng", "png",
    ]

    /// True for still-image files (JPEG, HEIF, Nikon RAW, etc.).
    public static func isPhoto(_ filename: String) -> Bool {
        photoExtensions.contains(fileExtension(of: filename))
    }

    /// True for playable proxy containers shown in the Videos tab.
    public static func isPlayableProxy(_ filename: String) -> Bool {
        ["mov", "mp4", "m4v"].contains(fileExtension(of: filename))
    }

    /// True for any browsable media object (video proxy or still).
    public static func isBrowsableMedia(_ filename: String) -> Bool {
        isPlayableProxy(filename) || isPhoto(filename) || isR3D(filename)
    }

    /// R3D masters are hidden when a playable proxy with the same stem exists.
    public static func shouldShowInMediaBrowser(
        filename: String,
        playableProxyStems: Set<String>
    ) -> Bool {
        guard isR3D(filename) else { return true }
        return !playableProxyStems.contains(stem(of: filename))
    }

    /// Stems of all playable proxy filenames in a clip list.
    public static func playableProxyStems(in filenames: [String]) -> Set<String> {
        Set(
            filenames.compactMap { name in
                isPlayableProxy(name) ? stem(of: name) : nil
            })
    }
}

/// PTP object-format partitions used to scope the camera media listing to a sidebar category
/// (`GetObjectHandles` accepts an object-format filter parameter). Codes are the standard PTP/MTP
/// container formats (libgphoto2 ptp.h); how the ZR actually tags its files — and whether it
/// honours specification-by-format at all — is [ZR-only · verify-on-HW], so callers must treat
/// these as a *prioritisation* hint with a graceful fallback, never a hard exclusion (a wrong
/// guess would otherwise blank the tab). NEF/HEIF/R3D use vendor codes we haven't mapped; those
/// clips simply fall outside both partitions.
public enum MediaObjectFormats {
    /// Movie containers: QT/MOV `0x300D`, MTP MP4 `0xB982`, AVI `0x300A`, MPEG `0x300B`.
    public static let video: [UInt32] = [0x300D, 0xB982, 0x300A, 0x300B]
    /// Stills: EXIF JPEG `0x3801`, TIFF `0x380D`, DNG `0x3811`, PNG `0x380B`.
    public static let photo: [UInt32] = [0x3801, 0x380D, 0x3811, 0x380B]
}
