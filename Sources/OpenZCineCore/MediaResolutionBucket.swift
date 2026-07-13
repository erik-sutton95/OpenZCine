import Foundation

/// Resolution buckets for the Media browser filter chips (HD, 4K, 5.4K, 6K).
public enum MediaResolutionBucket: String, CaseIterable, Codable, Sendable {
    case hd = "HD"
    case fourK = "4K"
    case fiveFourK = "5.4K"
    case sixK = "6K"

    /// Classifies a horizontal pixel width into a bucket.
    public static func from(pixelWidth: UInt32) -> MediaResolutionBucket? {
        guard pixelWidth > 0 else { return nil }
        switch pixelWidth {
        case 6_000...: return .sixK
        case 5_300..<6_000: return .fiveFourK
        case 3_500..<5_300: return .fourK
        case 1_000..<3_500: return .hd
        default: return nil
        }
    }

    /// Best-effort bucket from filename tokens when metadata is missing.
    public static func fromFilename(_ filename: String) -> MediaResolutionBucket? {
        let upper = filename.uppercased()
        if upper.contains("6K") { return .sixK }
        if upper.contains("5.4K") || upper.contains("54K") { return .fiveFourK }
        if upper.contains("4K") || upper.contains("UHD") { return .fourK }
        if upper.contains("HD") || upper.contains("1080") { return .hd }
        return nil
    }

    /// Chooses a bucket from R3D source dimensions when linked, else proxy/clip pixels, then filename.
    public static func classify(
        filename: String,
        pixelWidth: UInt32?,
        sourcePixelWidth: UInt32?
    ) -> MediaResolutionBucket? {
        if let sourcePixelWidth {
            return from(pixelWidth: sourcePixelWidth)
        }
        if let pixelWidth {
            return from(pixelWidth: pixelWidth)
        }
        return fromFilename(filename)
    }
}
