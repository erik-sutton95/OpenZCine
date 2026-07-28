import Foundation

/// The source categories the LUT picker groups looks under.
public enum LUTCategory: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case builtIn = "Built-in"
    case red = "RED"
    case custom = "Custom"

    public var id: String { rawValue }
}

/// A selectable monitor look applied to the live view as a 3D LUT.
///
/// No proprietary assets are bundled. The creative look (Mono) comes from simple in-gamut math;
/// the log→display conversions (N-Log and Log3G10 → Rec.709) are generated from their published
/// transfer functions and gamut matrices, so operators who don't want a vendor's official LUTs
/// still get an accurate monitoring image. `R3D NE Monitor` is the one look that is a table rather
/// than a formula: it was contributed for inclusion here (see ``credit`` and
/// `THIRD-PARTY-NOTICES.md`) and travels as a base64 UInt16 blob in the shared core, so both
/// shells decode the same numbers with no per-platform resource plumbing. There is no "none"
/// look — the LUT is switched off via the assist-bar toggle, not a menu entry.
public enum MonitorLUT: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case log3G10Rec709 = "Log3G10→709"
    case nLogRec709 = "N-Log→709"
    case monochrome = "Mono"
    case r3dNEMonitor = "R3D NE Monitor"

    public var id: String { rawValue }

    /// Who contributed this look, credited beside it in the picker — `nil` for the looks generated
    /// from published math in this repo. The drum is one narrow line, so the shells render this as
    /// a caption under it rather than lengthening the label.
    public var credit: String? {
        switch self {
        case .log3G10Rec709, .nLogRec709, .monochrome: nil
        case .r3dNEMonitor: "Contributed by Wang Yuehua"
        }
    }

    /// Generates the look as a `size³` red-fastest cube (`index = r + g·size + b·size²`).
    ///
    /// The default 33³ grid matches the professional `.cube` standard (and RED's own presets): a
    /// coarser grid under-samples the steep log→Rec.709 toe and shows visible contour banding once
    /// the trilinear interpolation stretches the shadows.
    public func cube(size: Int = 33) -> CubeLUT {
        precondition(size >= 2, "A 3D LUT needs at least a 2×2×2 grid.")
        var rgb = [Float]()
        rgb.reserveCapacity(size * size * size * 3)
        let denominator = Float(size - 1)
        // Red-fastest: r is the innermost loop.
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let mapped = map(
                        Float(r) / denominator,
                        Float(g) / denominator,
                        Float(b) / denominator
                    )
                    rgb.append(mapped.0)
                    rgb.append(mapped.1)
                    rgb.append(mapped.2)
                }
            }
        }
        return CubeLUT(size: size, rgb: rgb)
    }

    /// Maps one input RGB sample (each in `[0, 1]`) to its graded output.
    private func map(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        switch self {
        case .log3G10Rec709:
            return Self.logToRec709(
                r, g, b, decode: Self.log3G10ToLinear, matrix: Self.redWideGamutToRec709)
        case .nLogRec709:
            return Self.logToRec709(r, g, b, decode: Self.nLogToLinear, matrix: Self.nGamutToRec709)
        case .monochrome:
            let y = Self.luma(r, g, b)
            return (y, y, y)
        case .r3dNEMonitor:
            // Sampling the embedded table here (rather than special-casing `cube(size:)`) keeps one
            // generation path for every look. At the table's own 33³ grid the lattice coordinates
            // are exact integers, so the trilinear weights collapse to 1 and `cube()` reproduces
            // the contributor's samples verbatim; any other size resamples from them.
            let mapped = Self.contributedTableCube.map(red: r, green: g, blue: b)
            return (mapped.red, mapped.green, mapped.blue)
        }
    }

    private static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Log → Rec.709 conversion math
    //
    // Generated from published transfer functions and gamut matrices — no proprietary assets:
    //   • Nikon "N-Log Specification Document" v1.0.0 — the N-Log curve; N-Gamut ≡ BT.2020.
    //   • RED "REDWideGamutRGB and Log3G10" white paper, Rev B — Log3G10 curve + RWG→Rec.709 matrix.
    //   • ITU-R BT.1886 — the display EOTF (its inverse is the encode below).

    /// Nikon N-Log (normalized 10-bit code value) → scene-linear reflectance (0.18 == middle grey).
    private static func nLogToLinear(_ codeValue: Float) -> Float {
        let x = Double(codeValue)
        let a = 650.0 / 1023.0
        let c = 150.0 / 1023.0
        let d = 619.0 / 1023.0
        let threshold = 452.0 / 1023.0
        let linear = x < threshold ? pow(x / a, 3.0) - 0.0075 : exp((x - d) / c)
        return Float(linear)
    }

    /// RED Log3G10 (encoded) → scene-linear (0.18 == middle grey); v2/v3 form with the linear toe.
    private static func log3G10ToLinear(_ encoded: Float) -> Float {
        let x = Double(encoded)
        let a = 0.224282
        let b = 155.975327
        let c = 0.01
        let g = 15.1927
        let linear = x < 0 ? (x / g) - c : (pow(10.0, x / a) - 1.0) / b - c
        return Float(linear)
    }

    /// N-Gamut (≡ BT.2020, D65) → Rec.709 linear RGB, row-major 3×3.
    private static let nGamutToRec709: [Float] = [
        1.660491, -0.587641, -0.072850,
        -0.124550, 1.132900, -0.008349,
        -0.018151, -0.100579, 1.118730,
    ]

    /// REDWideGamutRGB → Rec.709 linear RGB, row-major 3×3 (published directly by RED).
    private static let redWideGamutToRec709: [Float] = [
        1.981880, -0.900388, -0.081540,
        -0.178143, 1.500467, -0.322325,
        -0.101811, -0.535343, 1.637304,
    ]

    /// The shared monitor pipeline: decode the log signal, rotate to Rec.709 primaries with the 3×3
    /// gamut matrix (in scene-linear), apply the anchored filmic tone map per channel, then encode
    /// with BT.1886 and clamp to the display range.
    private static func logToRec709(
        _ r: Float, _ g: Float, _ b: Float,
        decode: (Float) -> Float, matrix m: [Float]
    ) -> (Float, Float, Float) {
        let lr = decode(r)
        let lg = decode(g)
        let lb = decode(b)
        let outR = max(0, m[0] * lr + m[1] * lg + m[2] * lb)
        let outG = max(0, m[3] * lr + m[4] * lg + m[5] * lb)
        let outB = max(0, m[6] * lr + m[7] * lg + m[8] * lb)
        // Per-format white point from the decode function's own scene white — no blind literal.
        let tone = MonitorDisplayToneMap(sceneWhite: Double(decode(1.0)))
        return (encode(tone, outR), encode(tone, outG), encode(tone, outB))
    }

    /// Tone-map one scene-linear channel and BT.1886-encode it to a display code value.
    private static func encode(_ tone: MonitorDisplayToneMap, _ sceneLinear: Float) -> Float {
        Float(tone.displayCode(sceneLinear: Double(sceneLinear)))
    }
}

/// What the operator has selected to apply when the LUT tool is on: a generated built-in look or a
/// stored file (custom import; downloaded RED / Nikon later).
public enum LUTSelection: Equatable, Codable, Sendable {
    case builtIn(MonitorLUT)
    case stored(category: LUTCategory, fileName: String)

    /// A stable key identifying this selection, for caching the rendered filter.
    public var cacheKey: String {
        switch self {
        case .builtIn(let look): "builtIn:\(look.rawValue)"
        case .stored(let category, let fileName): "stored:\(category.rawValue):\(fileName)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case builtIn, stored
    }

    /// Matches the synthesized shape for a single unlabeled associated value: `{"_0": <value>}`.
    private enum BuiltInCodingKeys: String, CodingKey {
        case _0
    }

    private enum StoredCodingKeys: String, CodingKey {
        case category, fileName
    }

    /// Custom decode (replacing synthesis) so a removed built-in look's raw value falls back to the
    /// default selection instead of throwing. This matters beyond this type: `AssistConfiguration`
    /// is loaded via `try?` (`PreferencesStore.loadAssistConfiguration`), so a throwing
    /// `LUTSelection` decode would silently reset the operator's entire assist configuration — the
    /// fallback has to happen here, inside the decoder, not at any call site.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.builtIn) {
            let inner = try container.nestedContainer(
                keyedBy: BuiltInCodingKeys.self, forKey: .builtIn)
            let rawValue = try inner.decode(String.self, forKey: ._0)
            self = .builtIn(MonitorLUT(rawValue: rawValue) ?? .log3G10Rec709)
        } else if container.contains(.stored) {
            let inner = try container.nestedContainer(
                keyedBy: StoredCodingKeys.self, forKey: .stored)
            let category = try inner.decode(LUTCategory.self, forKey: .category)
            let fileName = try inner.decode(String.self, forKey: .fileName)
            self = .stored(category: category, fileName: fileName)
        } else {
            self = .builtIn(.log3G10Rec709)
        }
    }

    /// Mirrors the synthesized encode shape exactly (verified against a compiled probe), so stored
    /// selections keep round-tripping and existing persisted data stays readable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let look):
            var inner = container.nestedContainer(keyedBy: BuiltInCodingKeys.self, forKey: .builtIn)
            try inner.encode(look.rawValue, forKey: ._0)
        case .stored(let category, let fileName):
            var inner = container.nestedContainer(keyedBy: StoredCodingKeys.self, forKey: .stored)
            try inner.encode(category, forKey: .category)
            try inner.encode(fileName, forKey: .fileName)
        }
    }
}

/// Resolves the selection to apply, from the assist-bar on/off state and the operator's choice.
public enum LUTResolution {
    /// The selection to apply, or `nil` when the `.lut` tool is off. On/off is the bar toggle alone.
    public static func active(
        visibleTools: Set<MonitorAssistTool>,
        selected: LUTSelection
    ) -> LUTSelection? {
        visibleTools.contains(.lut) ? selected : nil
    }

    /// The 50/50 Log-vs-LUT comparison to render, or `nil` when it is switched off or there is no
    /// grade to compare against.
    ///
    /// Resolved once, here, for the same reason ``active(visibleTools:selected:)`` is: a shell that
    /// tested the preference on its own would eventually show the divider and the half labels over
    /// a frame with no LUT in it, or keep the split alive in a DISP mode that dropped the tool.
    /// `visibleTools` is already the mode-filtered set (`MonitorChromePolicy.visibleTools`), so
    /// clean view carries the comparison exactly when the operator pinned the LUT into it.
    /// - Parameter muted: the on-feed quick key's session state — see
    ///   ``showsSplitComparisonKey(visibleTools:preferences:)``. Not a preference: an A/B while
    ///   judging a look should not survive the take.
    public static func splitComparison(
        visibleTools: Set<MonitorAssistTool>,
        preferences: OperatorPreferences,
        muted: Bool = false
    ) -> SplitComparisonOrientation? {
        guard preferences.splitComparisonEnabled, !muted, visibleTools.contains(.lut) else {
            return nil
        }
        return preferences.splitComparisonOrientation
    }

    /// Whether the on-feed 50/50 quick key mounts.
    ///
    /// Judging a look is an A/B the operator repeats, and reopening the LUT pop-up for each flip
    /// defeats the feature — so the key lives on the feed once the comparison is armed. It follows
    /// the *armed* preference, not the muted state, or the first tap would delete the only control
    /// that undoes it. Like the divider and the labels it rides the LUT tool's own visibility, so
    /// clean view carries it exactly where the operator pinned the tool.
    public static func showsSplitComparisonKey(
        visibleTools: Set<MonitorAssistTool>,
        preferences: OperatorPreferences
    ) -> Bool {
        preferences.splitComparisonEnabled && visibleTools.contains(.lut)
    }
}

/// How a 50/50 Log-vs-LUT comparison divides the monitor image.
public enum SplitComparisonOrientation: String, CaseIterable, Codable, Equatable, Sendable,
    Identifiable
{
    /// Vertical boundary — Log on the left, LUT on the right.
    case vertical = "Left / Right"
    /// Horizontal boundary — Log on the top, LUT on the bottom.
    case horizontal = "Top / Bottom"

    public var id: String { rawValue }
}

/// The 50/50 Log-vs-LUT split — an immediate before/after for judging a monitoring look without
/// toggling the LUT off and on.
///
/// **The boundary is the centre of the visible image rectangle**, never the centre of the surface:
/// letterbox, pillarbox and monitor chrome are all outside it. Every renderer already establishes
/// that rectangle before the grade runs — iOS bakes a centred crop of the source at the drawable's
/// aspect (`MetalFeedFrameBaker.bakeSize`), Android sets the GL viewport to `liveFeedContentRect`
/// and the Vulkan viewport to the letterboxed content rect — so each one splits in its own feed
/// space at the halfway line and inherits a correct boundary through fit/fill, de-squeeze, crop
/// and orientation changes for free. Fit and fill both centre the image, so the halfway line of
/// the feed and the halfway line of what the operator sees are the same line.
///
/// Monitor-only: the split lives in the display pipeline and never reaches the camera or recorded
/// media.
public enum SplitComparison {
    /// Edge label for the ungraded half.
    public static let logLabel = "LOG"
    /// Edge label for the graded half.
    public static let lutLabel = "LUT"

    /// Whether a point in normalized feed space is on the graded side.
    ///
    /// `x`/`y` run `0...1` across the **visible image rectangle**, origin at its top-left. This is
    /// the definition each fragment shader transcribes; the shells' rect-based helpers below agree
    /// with it by construction.
    public static func isGradedSide(
        x: Double, y: Double, orientation: SplitComparisonOrientation
    ) -> Bool {
        switch orientation {
        case .vertical: x >= 0.5
        case .horizontal: y >= 0.5
        }
    }

    /// The graded (LUT) half of the visible image rectangle, in the shell's own top-left space.
    public static func lutHalf(
        of feed: MonitorModuleFrame, orientation: SplitComparisonOrientation
    ) -> MonitorModuleFrame {
        switch orientation {
        case .vertical:
            MonitorModuleFrame(
                x: feed.midX, y: feed.y, width: feed.width / 2, height: feed.height)
        case .horizontal:
            MonitorModuleFrame(
                x: feed.x, y: feed.midY, width: feed.width, height: feed.height / 2)
        }
    }

    /// The ungraded (Log) half — the exact complement of ``lutHalf(of:orientation:)``.
    public static func logHalf(
        of feed: MonitorModuleFrame, orientation: SplitComparisonOrientation
    ) -> MonitorModuleFrame {
        switch orientation {
        case .vertical:
            MonitorModuleFrame(x: feed.x, y: feed.y, width: feed.width / 2, height: feed.height)
        case .horizontal:
            MonitorModuleFrame(x: feed.x, y: feed.y, width: feed.width, height: feed.height / 2)
        }
    }
}
