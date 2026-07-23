import Foundation

/// Rec.709 / broadcast studio-swing black and white code values (8-bit), kept as named reference
/// points for tests and any future studio-swing (non-log) feed. On the Log3G10 live-view / R3D feed
/// the app actually receives, legal black (native 16) sits *below* true black
/// (`ExposureToneCurve.blackIRE`, native ≈23), so it reads as crush — not a lifted shadow.
public enum StudioSwing {
    public static let legalBlackNative: Double = 16
    public static let legalWhiteNative: Double = 235
}

/// The log signal a measurement scale assumes, so a flat (log-encoded) live-view feed maps onto a
/// meaningful exposure scale. Both curves use scene reflectance (`0.18` == middle grey), but their
/// encoded values use different IRE conventions: Log3G10 is a normalized float signal while N-Log
/// is a 10-bit video signal with the 64–940 legal-range pedestal.
///
/// The Nikon ZR's active recording signal selects the curve automatically: R3D uses Log3G10, while
/// N-Log recording modes use N-Log. Callers must not apply N-Log math to an SDR tone mode.
public enum ExposureToneCurve: String, CaseIterable, Codable, Sendable, Identifiable {
    case redLog3G10 = "RED Log3G10"
    case nikonNLog = "Nikon N-Log"
    /// Display-referred sRGB (IEC 61966-2-1) — the stills JPEG-pipeline live-view preview in
    /// SDR tone mode. `linearLight` is display-relative: 1.0 == display white == clipping.
    case srgb = "sRGB"
    /// Display-referred HLG (ITU-R BT.2100 / ARIB STD-B67) — the stills preview in HLG tone
    /// mode. Reflectance maps per BT.2408: diffuse white at 75% signal, 18% grey at 38%.
    case hlg = "HLG"

    public var id: String { rawValue }

    /// Selects the log signal named by a camera codec/tone label. R3D is always
    /// REDWideGamutRGB/Log3G10. The fallback is N-Log for the ZR log-monitoring path; callers that
    /// can report SDR explicitly must gate log assists before using this helper.
    public static func forCameraCodec(_ codec: String) -> ExposureToneCurve {
        let upper = codec.uppercased()
        if upper.contains("R3D") || upper.contains("LOG3G10") { return .redLog3G10 }
        return .nikonNLog
    }

    /// Returns a curve only when the supplied signal label positively identifies its transfer
    /// function. Recording containers such as N-RAW, ProRes, H.265, and H.264 can carry either log
    /// or SDR/HLG, so they deliberately return `nil` until the body-reported tone mode is wired.
    public static func verifiedForCameraSignal(_ label: String) -> ExposureToneCurve? {
        let upper = label.uppercased()
        if upper.contains("R3D") || upper.contains("LOG3G10") { return .redLog3G10 }
        if upper.contains("N-LOG") || upper.contains("N LOG") || upper.contains("NLOG") {
            return .nikonNLog
        }
        return nil
    }

    /// Signal IRE at which the curve places true black (zero light). This is derived from the
    /// published transfer function: Log3G10 black is 9.155 IRE; N-Log code ≈127 is 7.22 IRE after
    /// legal-range conversion. Keeping code percentage and IRE separate avoids the former N-Log
    /// mix-up where 12.43% full code was treated as 12.43 IRE.
    /// See docs/red-log3g10-reference.md.
    // ponytail: nudge on-device only if a feed carries a small black pedestal that shifts the measured
    // floor off the white-paper value (point at true black; the waveform/histogram floor should reach
    // the very bottom and the crush light should just fire).
    public var blackIRE: Double {
        signalIRE(encodedValue: encode(linearLight: 0))
    }

    /// Signal IRE (0–100) at which the curve places 18% mid grey.
    public var middleGrayIRE: Double {
        signalIRE(encodedValue: encode(linearLight: 0.18))
    }

    /// Signal IRE (0–100) at which the assist tools treat a highlight as clipped (100% reference).
    ///
    /// For the raw Log3G10 feed this is the camera's own highlight-zebra threshold (no 3-D LUT): 18%
    /// grey sits at native ≈85 (mid IRE 33) and the highlight threshold is native ≈180 at base ISO 800
    /// → IRE ≈70.6. That threshold shifts with ISO (≈native 145 low end to ≈215 high end), so this is
    /// the base-ISO value; an ISO-driven clip is a follow-up. Do not use 100 IRE / native 255 — that
    /// is the encoding ceiling, far above where footage actually clips. Nikon's N-Log specification
    /// defines no fixed sensor clip, so its reference scale uses nominal 100 IRE instead of
    /// mislabelling diffuse white (about 63 IRE) as clipping.
    public var clipIRE: Double {
        switch self {
        case .redLog3G10: 180.0 / 2.55  // highlight zebra code ≈180 (base ISO 800) → IRE
        case .nikonNLog: 100
        // Display-referred curves clip at full code — the preview carries no headroom above it.
        case .srgb, .hlg: 100
        }
    }

    /// Decodes a canonical normalized log value to scene-linear reflectance (`0.18` == middle grey).
    public func decode(encodedValue: Double) -> Double {
        switch self {
        case .redLog3G10: Log3G10.decode(encodedValue)
        case .nikonNLog: NLog.decode(encodedValue)
        case .srgb: SRGB.decode(encodedValue)
        case .hlg: HLG.decode(encodedValue)
        }
    }

    /// Encodes scene-linear reflectance (`0.18` == middle grey) into the curve's canonical
    /// normalized code domain.
    public func encode(linearLight: Double) -> Double {
        switch self {
        case .redLog3G10: Log3G10.encode(linearLight)
        case .nikonNLog: NLog.encode(linearLight)
        case .srgb: SRGB.encode(linearLight)
        case .hlg: HLG.encode(linearLight)
        }
    }

    /// Converts a canonical normalized encoded value to raw/log signal IRE.
    ///
    /// Log3G10 directly defines normalized `0...1` as `0...100` IRE. N-Log defines canonical
    /// 10-bit code values, so IRE uses the video legal range (`64...940` == `0...100` IRE).
    public func signalIRE(encodedValue: Double) -> Double {
        switch self {
        case .redLog3G10:
            encodedValue * 100
        case .nikonNLog:
            ((encodedValue * 1023) - 64) / (940 - 64) * 100
        case .srgb, .hlg:
            // The stills preview is full-range 8-bit; normalized code is directly IRE.
            encodedValue * 100
        }
    }

    /// Inverse of ``signalIRE(encodedValue:)`` in the curve's canonical normalized code domain.
    public func encodedValue(signalIRE: Double) -> Double {
        switch self {
        case .redLog3G10:
            signalIRE / 100
        case .nikonNLog:
            (64 + (signalIRE / 100) * (940 - 64)) / 1023
        case .srgb, .hlg:
            signalIRE / 100
        }
    }
}

/// Nikon's published R3D NE highlight-warning levels on the 8-bit-equivalent code axis.
///
/// R3D NE records from either the ISO 800 or ISO 6400 base circuit. The displayed/metadata ISO does
/// not change the raw base circuit, but it does move the camera's overexposure warning. These values
/// come from Nikon's February 2026 R3D NE zebra-pattern data sheet (3D LUT off).
public enum R3DNEHighlightWarning {
    private static let lowBaseValues: [(UInt32, Double)] = [
        (200, 145), (220, 150), (250, 150), (280, 155), (320, 160), (360, 160),
        (400, 165), (450, 165), (500, 170), (560, 170), (640, 175), (720, 180),
        (800, 180), (900, 185), (1_000, 185), (1_100, 190), (1_250, 190),
        (1_400, 195), (1_600, 200), (1_800, 200), (2_000, 205), (2_200, 205),
        (2_500, 210), (2_800, 210), (3_200, 215),
    ]

    private static let highBaseValues: [(UInt32, Double)] = [
        (1_600, 145), (1_800, 150), (2_000, 150), (2_200, 155), (2_500, 160),
        (2_800, 160), (3_200, 165), (3_600, 165), (4_000, 170), (4_500, 170),
        (5_000, 175), (5_600, 180), (6_400, 180), (7_200, 185), (8_000, 185),
        (9_000, 190), (10_000, 190), (11_400, 195), (12_800, 200), (14_400, 200),
        (16_000, 205), (18_000, 205), (20_000, 210), (22_800, 210), (25_600, 215),
    ]

    /// Returns Nikon's warning code for the selected R3D base circuit and metadata ISO.
    /// Unknown/intermediate ISO values use the nearest published setting; a missing ISO uses the
    /// circuit's base-ISO warning (native 180).
    public static func nativeCode(iso: UInt32?, baseISO: String?) -> Double {
        let table =
            baseISO?.caseInsensitiveCompare("High") == .orderedSame
            ? highBaseValues : lowBaseValues
        guard let iso else { return 180 }
        return table.min { abs(Int64($0.0) - Int64(iso)) < abs(Int64($1.0) - Int64(iso)) }?.1
            ?? 180
    }
}

/// One authoritative conversion between the received log code values and OpenZCine's monitoring
/// percentage. The displayed axis deliberately expands the useful signal from log black to the
/// camera's current clipping warning across 0–100%, rather than reproducing R3D NE's compressed
/// native waveform placement.
public struct ExposureSignalMapping: Equatable, Sendable {
    /// The transfer function carried by the feed.
    public let curve: ExposureToneCurve
    /// Native 8-bit-equivalent code at which the current camera configuration clips.
    public let clipNative: Double

    /// Creates a mapping, clamping the clip endpoint above the curve's published black code.
    public init(curve: ExposureToneCurve, clipNative: Double) {
        self.curve = curve
        self.clipNative = min(255, max(curve.encode(linearLight: 0) * 255 + 1, clipNative))
    }

    /// Default mapping when camera ISO metadata is unavailable.
    public init(curve: ExposureToneCurve) {
        self.init(curve: curve, clipNative: curve.defaultClipNative)
    }

    /// Builds the log mapping for a Nikon ZR camera state. R3D gets Nikon's ISO-dependent warning;
    /// N-Log uses nominal 10-bit legal white (code 940) because Nikon publishes no fixed sensor-clip
    /// table at normal N-Log ISO values.
    public static func camera(codec: String, iso: UInt32?, baseISO: String?) -> Self {
        let curve = ExposureToneCurve.forCameraCodec(codec)
        switch curve {
        case .redLog3G10:
            return Self(
                curve: curve,
                clipNative: R3DNEHighlightWarning.nativeCode(iso: iso, baseISO: baseISO))
        case .nikonNLog:
            return Self(curve: curve, clipNative: nLogClipNative(iso: iso))
        case .srgb, .hlg:
            return Self(curve: curve)
        }
    }

    /// Mapping for the photography live view, which is a display-referred preview: HLG when the
    /// body's stills tone mode reports HLG, otherwise the sRGB JPEG-pipeline rendering. RAW
    /// on/off never changes the previewed signal — NEF headroom beyond the preview's clip is
    /// real but not visible in the feed.
    public static func stills(toneMode: String?) -> Self {
        Self(curve: toneMode == "HLG" ? .hlg : .srgb)
    }

    /// Nikon documents reduced N-Log maximum output at the ZR's extended-low ISO settings: about
    /// native 200 at Lo 2.0 (ISO 200 equivalent), and about 230 at Lo 1.0…Lo 0.3 (ISO 400…640
    /// equivalent). Normal ISO uses nominal legal white because no sensor-clip table is published.
    private static func nLogClipNative(iso: UInt32?) -> Double {
        switch iso {
        case 200: 200
        case 400, 500, 640: 230
        default: ExposureToneCurve.nikonNLog.defaultClipNative
        }
    }

    /// Native code for zero scene light according to the published transfer function.
    public var blackNative: Double { curve.encode(linearLight: 0) * 255 }

    /// Native code for 18% reflectance.
    public var middleGrayNative: Double { curve.encode(linearLight: 0.18) * 255 }

    /// Middle grey on the normalized monitoring axis.
    public var middleGrayPercent: Double { monitorPercent(signalNative: middleGrayNative) }

    /// Converts native code to the normalized black-to-clip monitoring axis.
    public func monitorPercent(signalNative: Double) -> Double {
        let percent = (signalNative - blackNative) / (clipNative - blackNative) * 100
        return min(100, max(0, percent))
    }

    /// Converts the normalized monitoring axis back to native code.
    public func signalNative(monitorPercent: Double) -> Double {
        let percent = min(100, max(0, monitorPercent))
        return blackNative + (percent / 100) * (clipNative - blackNative)
    }

    /// Places a scene stop relative to 18% grey on the normalized monitoring axis.
    public func monitorPercent(zStop: Double) -> Double {
        monitorPercent(signalNative: ExposureScale.signalNative(zStop: zStop, curve: curve))
    }
}

extension ExposureToneCurve {
    /// Default clipping code when camera-specific warning metadata is unavailable.
    public var defaultClipNative: Double {
        switch self {
        case .redLog3G10: 180
        case .nikonNLog: 940.0 / 1023.0 * 255.0
        case .srgb, .hlg: 255
        }
    }
}

/// Pure conversions between pixel code values, scene stops, and OpenZCine's normalized monitoring
/// percentage. False colour, scopes, zebras, and traffic lights share this mapping.
public enum ExposureScale {
    /// Compatibility spelling for the default normalized monitoring percentage. New camera-aware
    /// code should pass an ``ExposureSignalMapping`` and use ``monitorPercent(signalNative:mapping:)``.
    public static func referenceIRE(signalNative: Double, curve: ExposureToneCurve) -> Double {
        monitorPercent(signalNative: signalNative, mapping: ExposureSignalMapping(curve: curve))
    }

    /// Compatibility inverse using the curve's default clip endpoint.
    public static func signalNative(referenceIRE: Double, curve: ExposureToneCurve) -> Double {
        ExposureSignalMapping(curve: curve).signalNative(monitorPercent: referenceIRE)
    }

    /// Monitoring percentage to normalized scope level (0 = black, 1 = clip).
    public static func waveformLevel(referenceIRE: Double) -> Double {
        min(100, max(0, referenceIRE)) / 100
    }

    /// Native code to normalized monitoring percentage using a camera-aware mapping.
    public static func monitorPercent(
        signalNative: Double, mapping: ExposureSignalMapping
    ) -> Double {
        mapping.monitorPercent(signalNative: signalNative)
    }

    /// Monitoring percentage back to native code using a camera-aware mapping.
    public static func signalNative(
        monitorPercent: Double, mapping: ExposureSignalMapping
    ) -> Double {
        mapping.signalNative(monitorPercent: monitorPercent)
    }

    /// Reference IRE where `zStop` EV (0 == 18% mid grey) lands after the log curve and
    /// ``referenceIRE(signalNative:curve:)`` remap. Shared by false-colour Z-stop bands and tests.
    public static func referenceIRE(zStop: Double, curve: ExposureToneCurve) -> Double {
        referenceIRE(signalNative: signalNative(zStop: zStop, curve: curve), curve: curve)
    }

    /// Broadcast / signal IRE (linear native÷2.55) to a native code value for zebra band comparison.
    ///
    /// Zebra thresholds use this axis — the same mapping as the prototype's `nativeToIre` /
    /// `ireToNative` and ``ZebraThresholds`` defaults (55 signal IRE → native 140). Do not use
    /// ``signalNative(referenceIRE:curve:)`` here; that is the log-compensated reference scale
    /// shared by scopes (18 = mid grey, 100 = clip).
    public static func zebraSignalNative(signalIRE: Double) -> Double {
        min(255, max(0, signalIRE * 2.55))
    }

    /// Native code value for `zStop` EV relative to 18% grey on `curve`.
    public static func signalNative(zStop: Double, curve: ExposureToneCurve) -> Double {
        let targetLinear = 0.18 * pow(2.0, zStop)
        let encoded = curve.encode(linearLight: targetLinear)
        return min(255, max(0, encoded * 255.0))
    }

    /// Exposure in stops relative to 18% grey for an 8-bit-normalized log code value.
    public static func zStop(signalNative: Double, curve: ExposureToneCurve) -> Double {
        let encoded = min(255, max(0, signalNative)) / 255
        let linear = curve.decode(encodedValue: encoded)
        guard linear > 0 else { return -.infinity }
        return log2(linear / 0.18)
    }
}

// MARK: - Log decode/encode for Z-stop placement (matches ``MonitorLUT`` transfer functions)

enum Log3G10 {
    static func decode(_ encoded: Double) -> Double {
        let x = encoded
        let a = 0.224282
        let b = 155.975327
        let c = 0.01
        let g = 15.1927
        return x < 0 ? (x / g) - c : (pow(10.0, x / a) - 1.0) / b - c
    }

    static func encode(_ linear: Double) -> Double {
        let b = 155.975327
        let c = 0.01
        let g = 15.1927
        let a = 0.224282
        if linear <= -c { return (linear + c) * g }
        return a * log10((linear + c) * b + 1.0)
    }
}

enum NLog {
    static func decode(_ codeValue: Double) -> Double {
        let code = codeValue * 1023
        return code < 452 ? pow(code / 650, 3.0) - 0.0075 : exp((code - 619) / 150)
    }

    static func encode(_ linear: Double) -> Double {
        if linear < 0.328 {
            return 650 * pow(max(0, linear + 0.0075), 1.0 / 3.0) / 1023
        }
        return (150 * log(linear) + 619) / 1023
    }
}

/// IEC 61966-2-1 sRGB transfer function. Display-referred: linear 1.0 == display white, and
/// values above it clip (the JPEG preview carries no highlight headroom). 18% grey encodes to
/// ≈0.4614 (native ≈118).
enum SRGB {
    static func decode(_ encoded: Double) -> Double {
        let e = min(1, max(0, encoded))
        return e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
    }

    static func encode(_ linear: Double) -> Double {
        let l = min(1, max(0, linear))
        return l <= 0.003_130_8 ? 12.92 * l : 1.055 * pow(l, 1.0 / 2.4) - 0.055
    }
}

/// ITU-R BT.2100 HLG OETF (ARIB STD-B67). The curve API's `linearLight` contract is scene
/// reflectance (1.0 == diffuse white), so values are scaled onto the HLG scene-linear axis per
/// ITU-R BT.2408: diffuse white at 75% signal (scene E ≈ 0.265), which lands 18% grey at ≈38%.
enum HLG {
    private static let a = 0.178_832_77
    private static let b = 0.284_668_92
    private static let c = 0.559_910_73
    /// Scene-linear value of diffuse white: inverse OETF of the BT.2408 75% signal level.
    private static let diffuseWhite = 0.264_96

    static func decode(_ encoded: Double) -> Double {
        let e = min(1, max(0, encoded))
        let scene = e <= 0.5 ? e * e / 3 : (exp((e - c) / a) + b) / 12
        return scene / diffuseWhite
    }

    static func encode(_ linear: Double) -> Double {
        let scene = min(1, max(0, linear * diffuseWhite))
        return scene <= 1.0 / 12.0 ? sqrt(3 * scene) : a * log(12 * scene - b) + c
    }
}
