import Foundation

/// The browser action authorized by the portable camera-media policy.
public enum MediaContentKind: String, Equatable, Sendable {
    /// A MOV, MP4, or M4V proxy that can enter the progressive player.
    case playableProxy = "proxy"

    /// A still image that can enter the Android/iOS photo viewer.
    case stillPhoto = "still"

    /// An unpaired RED master that remains intentionally non-previewable.
    case r3dMaster = "r3d"

    /// A media-library object with no supported browser action yet.
    case unsupported = "unsupported"
}

/// The safe decoding path for a still image on a platform shell.
public enum MediaStillPreviewStrategy: String, Equatable, Sendable {
    /// JPEG and PNG may be decoded while their object cache is still growing.
    case progressive = "progressive"

    /// HEIF and TIFF must wait for an atomically published complete cache.
    case completeFile = "complete"

    /// The platform must retain the camera thumbnail instead of claiming a full preview.
    case thumbnailOnly = "thumbnail"
}

/// The platform-neutral preview policy for one supported still-image format.
public struct MediaStillPreview: Equatable, Sendable {
    /// Operator-facing media format name, for example `JPEG` or `NEF`. This is also the token
    /// the JNI listing wire carries, so Android decodes the browser's FORMAT chip from it
    /// instead of re-deriving the format from the filename extension.
    public let formatLabel: String

    /// The only safe decoder path for this format.
    public let strategy: MediaStillPreviewStrategy
}

/// One value the Media browser can offer in its FORMAT chip row.
///
/// Video containers and still formats share a single enum because a tab shows whichever chips
/// its own listing can produce — the Photos tab derives JPEG/HEIF/NEF, the Videos tab derives
/// MOV/MP4, and neither hardcodes a list that the other tab's media can never match.
///
/// The raw values are the operator-facing chip titles, and for stills they are exactly the
/// `MediaStillPreview.formatLabel` token the JNI listing wire already carries.
public enum MediaFormatChip: String, CaseIterable, Codable, Sendable {
    case mov = "MOV"
    case mp4 = "MP4"
    case jpeg = "JPEG"
    case heif = "HEIF"
    /// Nikon RAW (`.NEF`, and the `.NRW` / `.DNG` variants that share its handling).
    case nef = "NEF"
    case tiff = "TIFF"
    case png = "PNG"
}

/// Shared media-browser presentation classification for a sanitized camera filename.
public struct MediaContentClassification: Equatable, Sendable {
    /// The shell action authorized for this media object.
    public let kind: MediaContentKind

    /// Still-only decoding policy; absent for proxies, R3D masters, and unknown objects.
    public let stillPreview: MediaStillPreview?

    init(kind: MediaContentKind, stillPreview: MediaStillPreview? = nil) {
        self.kind = kind
        self.stillPreview = stillPreview
    }
}

/// Filename helpers and portable media-browser policy for Nikon ZR camera objects.
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

    private static let jpegPhotoExtensions: Set<String> = ["jpg", "jpeg", "jpe"]
    /// `.HIF` is Nikon's own HEIF extension — the one a Z body actually writes. Without it a
    /// HEIF still classified as `.unsupported` and never reached either browser at all.
    private static let heifPhotoExtensions: Set<String> = ["hif", "heif", "heic"]
    private static let rawPhotoExtensions: Set<String> = ["nef", "nrw", "dng"]
    private static let tiffPhotoExtensions: Set<String> = ["tif", "tiff"]

    /// Lowercased extensions treated as still images in the Media browser.
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "hif", "heif", "heic", "nef", "nrw", "tif", "tiff", "dng", "png",
    ]

    /// True for still-image files (JPEG, HEIF, Nikon RAW, etc.).
    public static func isPhoto(_ filename: String) -> Bool {
        mediaClassification(for: filename).kind == .stillPhoto
    }

    /// True for playable proxy containers shown in the Videos tab.
    public static func isPlayableProxy(_ filename: String) -> Bool {
        ["mov", "mp4", "m4v"].contains(fileExtension(of: filename))
    }

    /// Produces the single shared media-browser policy used by iOS, Android, and facade wires.
    ///
    /// Platform shells must consume this result rather than reclassifying camera filenames locally.
    public static func mediaClassification(for filename: String) -> MediaContentClassification {
        if isPlayableProxy(filename) {
            return MediaContentClassification(kind: .playableProxy)
        }
        if isR3D(filename) {
            return MediaContentClassification(kind: .r3dMaster)
        }

        let fileExtension = fileExtension(of: filename)
        let stillPreview: MediaStillPreview?
        switch fileExtension {
        case let ext where jpegPhotoExtensions.contains(ext):
            stillPreview = MediaStillPreview(formatLabel: "JPEG", strategy: .progressive)
        case "png":
            stillPreview = MediaStillPreview(formatLabel: "PNG", strategy: .progressive)
        case let ext where heifPhotoExtensions.contains(ext):
            stillPreview = MediaStillPreview(formatLabel: "HEIF", strategy: .completeFile)
        case let ext where rawPhotoExtensions.contains(ext):
            stillPreview = MediaStillPreview(formatLabel: "NEF", strategy: .thumbnailOnly)
        case let ext where tiffPhotoExtensions.contains(ext):
            stillPreview = MediaStillPreview(formatLabel: "TIFF", strategy: .completeFile)
        default:
            stillPreview = nil
        }

        guard let stillPreview else {
            return MediaContentClassification(kind: .unsupported)
        }
        return MediaContentClassification(kind: .stillPhoto, stillPreview: stillPreview)
    }

    /// The FORMAT filter chip a camera filename belongs to.
    ///
    /// Nil when no chip covers the object — an unpaired `.R3D` master or an unrecognised
    /// extension is simply never offered a format chip rather than being given a wrong one.
    public static func formatChip(for filename: String) -> MediaFormatChip? {
        switch fileExtension(of: filename) {
        case "mov", "m4v": .mov
        case "mp4": .mp4
        case let ext where jpegPhotoExtensions.contains(ext): .jpeg
        case let ext where heifPhotoExtensions.contains(ext): .heif
        case let ext where rawPhotoExtensions.contains(ext): .nef
        case let ext where tiffPhotoExtensions.contains(ext): .tiff
        case "png": .png
        default: nil
        }
    }

    /// True for any browsable media object (video proxy or still).
    public static func isBrowsableMedia(_ filename: String) -> Bool {
        mediaClassification(for: filename).kind != .unsupported
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
