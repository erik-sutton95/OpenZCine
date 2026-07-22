/// ISO picker layout and recording-lock rules for Nikon ZR dual-base sensitivity.
///
/// R3D NE exposes separate low/high base ISO circuits in the UI; other codecs keep dual-base
/// hardware but auto-switch the circuit, so the operator sees one drum with native-base markers.
public enum ISOPickerPolicy: Sendable {
    /// Low-base ISO steps (200–3200).
    public static let lowBaseOptions: [String] = [
        "200", "250", "320", "400", "500", "640", "800", "1000", "1250", "1600",
        "2000", "2500", "3200",
    ]

    /// High-base ISO steps (1600–25600).
    public static let highBaseOptions: [String] = [
        "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000",
        "12800", "16000", "20000", "25600",
    ]

    /// Native low-base ISO flagged in the drum.
    public static let lowBaseMarker = "800"

    /// Native high-base ISO flagged in the drum.
    public static let highBaseMarker = "6400"

    /// Single-drum ISO steps for codecs that auto-switch base circuits (union of both ranges).
    public static let unifiedOptions: [String] = {
        var seen = Set<String>()
        var merged: [String] = []
        for value in lowBaseOptions + highBaseOptions where seen.insert(value).inserted {
            merged.append(value)
        }
        return merged
    }()

    /// Whether the active codec is R3D NE (accepts raw or shortened camera labels).
    public static func isR3DNECodec(_ codec: String) -> Bool {
        MonitorTextFormat.codecShortLabel(codec) == "R3D NE"
    }

    /// R3D NE keeps separate LOW/HIGH base drums; every other codec uses a unified drum.
    public static func showsDualBaseCircuits(codec: String) -> Bool {
        isR3DNECodec(codec)
    }

    /// Non-R3D NE codecs use Auto On/Off tabs instead of dual-base circuits.
    public static func showsAutoISOControl(codec: String) -> Bool {
        !showsDualBaseCircuits(codec: codec)
    }

    /// Exposure modes where the body typically owns ISO (auto ISO). Manual ISO is free in `M`.
    public static func isAutoISOActive(exposureMode: String?) -> Bool {
        guard let mode = exposureMode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty
        else { return false }
        switch mode {
        case "Auto", "P", "A", "S":
            return true
        default:
            // U1–U3 and M are treated as operator-controlled ISO unless the body reports Auto.
            return mode.localizedCaseInsensitiveContains("auto")
        }
    }

    /// Exposure-mode label that enables auto ISO (full Auto program).
    public static let autoISOOnExposureMode = "Auto"

    /// Exposure-mode label that releases ISO for the drum (manual movie exposure).
    public static let autoISOOffExposureMode = "M"

    /// ISO cannot be changed while recording in R3D NE; other codecs allow mid-roll ISO changes.
    public static func blocksISOChangeWhileRecording(codec: String, isRecording: Bool) -> Bool {
        isR3DNECodec(codec) && isRecording
    }

    /// Star markers for the active layout. Dual-base marks one native base per circuit tab;
    /// unified / Auto ISO marks both native bases on the single drum.
    public static func markedValues(codec: String, modeIndex: Int) -> Set<String> {
        if showsDualBaseCircuits(codec: codec) {
            guard modeIndex == 0 || modeIndex == 1 else { return [] }
            return [modeIndex == 0 ? lowBaseMarker : highBaseMarker]
        }
        return [lowBaseMarker, highBaseMarker]
    }

    /// Subtitle shown under the ISO picker header.
    public static func pickerSubtitle(codec: String) -> String {
        if showsDualBaseCircuits(codec: codec) { return "Sensitivity · dual base" }
        if showsAutoISOControl(codec: codec) { return "Sensitivity · auto / manual" }
        return "Sensitivity"
    }

    /// Mode tabs for the ISO picker.
    /// R3D NE → Low/High base; other codecs → Auto On / Auto Off; never empty for ZR movie codecs.
    public static func pickerModes(codec: String) -> [ISOPickerMode] {
        if showsDualBaseCircuits(codec: codec) {
            return [
                ISOPickerMode(
                    title: "Low Base",
                    detail: "\(lowBaseMarker) · 200-3200",
                    options: lowBaseOptions,
                    base: lowBaseMarker
                ),
                ISOPickerMode(
                    title: "High Base",
                    detail: "\(highBaseMarker) · 1600-25600",
                    options: highBaseOptions,
                    base: highBaseMarker
                ),
            ]
        }
        if showsAutoISOControl(codec: codec) {
            return [
                ISOPickerMode(
                    title: "Auto On",
                    detail: "Camera controls ISO",
                    options: unifiedOptions,
                    base: lowBaseMarker,
                    activatesAutoISO: true
                ),
                ISOPickerMode(
                    title: "Auto Off",
                    detail: "Manual ISO",
                    options: unifiedOptions,
                    base: lowBaseMarker,
                    activatesAutoISO: false
                ),
            ]
        }
        return []
    }

    /// Options for the active ISO layout and mode tab.
    public static func options(codec: String, modeIndex: Int) -> [String] {
        let modes = pickerModes(codec: codec)
        guard !modes.isEmpty, modes.indices.contains(modeIndex) else { return unifiedOptions }
        return modes[modeIndex].options
    }

    /// Active mode tab for Auto ISO codecs: 0 = Auto On, 1 = Auto Off.
    public static func autoISOModeIndex(exposureMode: String?) -> Int {
        isAutoISOActive(exposureMode: exposureMode) ? 0 : 1
    }
}

/// One segmented mode under the ISO picker (LOW/HIGH base or Auto On/Off).
public struct ISOPickerMode: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let options: [String]
    public let base: String
    /// When non-nil, selecting this tab should switch camera auto-ISO on (`true`) or off (`false`).
    public let activatesAutoISO: Bool?

    public init(
        title: String,
        detail: String? = nil,
        options: [String],
        base: String,
        activatesAutoISO: Bool? = nil
    ) {
        self.title = title
        self.detail = detail
        self.options = options
        self.base = base
        self.activatesAutoISO = activatesAutoISO
    }
}
