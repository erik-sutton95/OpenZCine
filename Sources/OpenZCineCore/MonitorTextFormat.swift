import Foundation

/// Compact, wireframe-style display formatting for the live-view monitor.
///
/// Camera-native values (raw pixel dimensions, fractional frame rates) are rendered as the
/// short operator-facing labels used in the top status bar and picker menus, e.g.
/// `6K · 24p` rather than `6048 × 3402`.
public enum MonitorTextFormat {
    /// Formats a resolution + frame rate as a compact label such as `6K · 24p`. The resolution
    /// class (`8K`/`6K`/`4K`) comes from the pixel width; smaller widths fall back to the raw
    /// pixel count so the readout never inflates. The frame rate rounds to an integer `p` value.
    public static func resolutionLabel(
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Double
    ) -> String {
        let resolution = resolutionClass(pixelWidth: pixelWidth)
        let rate = Int((frameRate).rounded())
        return "\(resolution) · \(rate)p"
    }

    /// Formats a PTP camera-property `"WxH"` resolution string (`"6048x3402"`) + integer frame
    /// rate as a compact label such as `6K · 25p`. Returns `fallback` when the property is missing
    /// or unparsable so the readout never blanks out.
    public static func resolutionLabel(
        fromProperty property: String?,
        frameRate: Int,
        fallback: String = ""
    ) -> String {
        guard let property else { return fallback }
        let parts = property.split(separator: "x")
        guard parts.count == 2,
            let width = Int(parts[0]),
            let height = Int(parts[1])
        else {
            return fallback
        }
        return resolutionLabel(pixelWidth: width, pixelHeight: height, frameRate: Double(frameRate))
    }

    /// Whether a codec label names a RAW format (R3D NE, N-RAW, ProRes RAW HQ). Used to gate
    /// controls that RAW disallows — e.g. electronic VR, which the ZR can't apply to a RAW stream.
    /// Substring match on the uppercased label; works on both the raw camera string and the
    /// already-shortened `codecShortLabel` output.
    public static func isRawCodec(_ codec: String) -> Bool {
        let upper = codec.uppercased()
        return upper.contains("RAW") || upper.contains("R3D")
    }

    /// Collapses a verbose camera-reported codec name to its short family label: firmware reports
    /// e.g. `"R3D NE 10-bit R3D"` (the format repeated as a bit-depth qualifier) — this trims the
    /// redundant suffix to `"R3D NE"`. Already-short names (`"ProRes RAW HQ"`) pass through.
    public static func codecShortLabel(_ codec: String) -> String {
        let stripped = codec.trimmingCharacters(in: .whitespaces)
        // Drop a trailing `N-bit <name>` qualifier where `<name>` repeats the leading token.
        // "R3D NE 10-bit R3D" → first token group "R3D NE" + redundant "10-bit R3D".
        if let match = stripped.firstMatch(of: #/\s+\d+-bit\s+.+$/#) {
            return String(stripped[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return stripped
    }

    /// Abbreviates a codec name for tight readouts such as the top-bar pill: `ProRes` collapses
    /// to `PR` and a trailing bit-depth qualifier is dropped from H.26x names. Short names
    /// (`R3D NE`, `N-RAW`) pass through unchanged.
    public static func codecCompactLabel(_ codec: String) -> String {
        var label = codecShortLabel(codec).replacingOccurrences(of: "ProRes", with: "PR")
        if label.hasPrefix("H.26"), let match = label.firstMatch(of: #/\s+\d+-bit$/#) {
            label = String(label[..<match.range.lowerBound])
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    /// Maps a pixel width to its marketing resolution class, or the raw width when no class fits.
    private static func resolutionClass(pixelWidth: Int) -> String {
        switch pixelWidth {
        case 7680...: "8K"
        case 5000..<7680: "6K"
        case 3500..<5000: "4K"
        default: "\(pixelWidth)"
        }
    }
}
