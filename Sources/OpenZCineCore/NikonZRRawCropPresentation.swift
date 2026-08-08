import Foundation

/// Nikon ZR RAW image area is selected by the camera's frame-size mode, not a separate writable
/// crop property. These labels make that camera-provided meaning visible only for documented,
/// exact ZR RAW modes; every other advertised mode keeps its generic resolution/rate label.
///
/// Shared by the iOS shell and the Android facade so both platforms present the same operator-facing
/// `[FX]` / `[DX]` tags on R3D NE / N-RAW while still writing the exact packed `MovScreenSize` raw.
public enum NikonZRRawCropPresentation {
    /// RAW codec short labels that use FX/DX semantics on the ZR (Nikon's RAW frame-size table).
    public static let rawCodecsWithImageArea: Set<String> = ["N-RAW", "R3D NE"]

    /// Presentation label for one camera-advertised screen-size mode.
    ///
    /// - Parameters:
    ///   - mode: Exact camera-advertised mode (label + packed raw).
    ///   - currentCodec: Active codec short or long label (e.g. `"R3D NE"` or `"R3D NE 12-bit R3D"`).
    ///   - isNikonZR: Whether the connected body is a Nikon ZR. Other models keep generic labels.
    public static func label(
        for mode: PTPCameraScreenSizeMode,
        currentCodec: String?,
        isNikonZR: Bool
    ) -> String {
        guard isNikonZR,
            let currentCodec,
            rawCodecsWithImageArea.contains(MonitorTextFormat.codecShortLabel(currentCodec)),
            let imageArea = imageArea(for: mode.raw)
        else {
            return mode.label
        }
        return "[\(imageArea)] \(mode.label)"
    }

    /// Adds an FX/DX prefix to a compact base label when the packed raw is a documented ZR RAW
    /// image area. Used for live readouts built from property width/height rather than a mode list.
    public static func label(
        baseLabel: String,
        rawScreenSize: UInt64?,
        currentCodec: String?,
        isNikonZR: Bool
    ) -> String {
        guard isNikonZR,
            let rawScreenSize,
            let currentCodec,
            rawCodecsWithImageArea.contains(MonitorTextFormat.codecShortLabel(currentCodec)),
            let imageArea = imageArea(for: rawScreenSize)
        else {
            return baseLabel
        }
        // Strip an existing crop prefix only — keep the operator-facing middot spacing intact.
        var bare = baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.hasPrefix("["), let close = bare.firstIndex(of: "]") {
            bare = String(bare[bare.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return bare.isEmpty ? baseLabel : "[\(imageArea)] \(bare)"
    }

    /// Documented ZR RAW image area for a packed `MovScreenSize` value, if any.
    public static func imageArea(for rawScreenSize: UInt64) -> String? {
        let size = PTPCameraPropertyDecoders.screenSize(rawScreenSize)
        switch (size.width, size.height) {
        case (6_048, 3_402), (4_032, 2_268):
            return "FX"
        case (3_984, 2_240):
            return "DX"
        default:
            return nil
        }
    }

    /// Which advertised mode a picked picker label refers to, or nil when none does.
    ///
    /// Precedence across the WHOLE list, and that is the entire point. The match used to be one
    /// `first(where:)` with three OR'd comparisons, so it returned the first mode matching ANY of
    /// them — and the loosest comparison strips the `[FX]`/`[DX]` tag from both sides. Picking
    /// `[DX] 4K · 25p` therefore landed on the FX mode listed above it: the tag that distinguishes
    /// the two was discarded by the very clause that matched (field-reported).
    ///
    /// So: exact presentation label first, over every mode. Then the bare camera label. The
    /// crop-insensitive fallback runs only when the picked label carries NO tag — if it does, that
    /// tag is the operator's choice and dropping it is never a valid interpretation.
    ///
    /// - Parameters:
    ///   - value: The label the operator tapped.
    ///   - presentationLabels: Each mode's operator-facing label, in advertised order.
    ///   - modeLabels: Each mode's bare camera label, same order and count.
    public static func pickedModeIndex(
        for value: String,
        presentationLabels: [String],
        modeLabels: [String]
    ) -> Int? {
        guard presentationLabels.count == modeLabels.count else { return nil }
        if let exact = presentationLabels.firstIndex(of: value) { return exact }
        if let camera = modeLabels.firstIndex(of: value) { return camera }
        guard !carriesCropTag(value) else { return nil }
        let bare = bareLabel(value)
        return modeLabels.firstIndex { bareLabel($0) == bare }
    }

    /// Whether a label carries an explicit `[FX]`/`[DX]` crop tag.
    public static func carriesCropTag(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
    }

    /// Strips a leading `[FX]` / `[DX]` crop prefix and normalizes middle-dot spacing.
    public static func bareLabel(_ label: String) -> String {
        var value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            value = String(value[value.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return
            value
            .replacingOccurrences(of: #"\s*·\s*"#, with: "·", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
