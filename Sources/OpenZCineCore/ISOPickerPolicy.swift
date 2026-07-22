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
    /// Empty/unknown codec stays closed until the body reports a real file type.
    public static func showsAutoISOControl(codec: String) -> Bool {
        let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !showsDualBaseCircuits(codec: trimmed)
    }

    /// Whether movie ISO auto is active (`MovieISOAutoControl` / `MovISOAutoControl` 0xD0AD).
    ///
    /// This is independent of exposure-program Auto (P/A/S/M). Unpolled (`nil`) means manual until
    /// the body reports otherwise so the drum is not falsely locked.
    public static func isAutoISOActive(isoAuto: Bool?) -> Bool {
        isoAuto == true
    }

    /// Whether the operator may write a manual movie ISO value for this codec / mode.
    ///
    /// - **R3D NE** (dual-base): always manual ISO — the body forces dual-base circuits even in
    ///   A/S/P; exposure program does not own sensitivity.
    /// - **Other codecs**: only **M** accepts Auto Off + ISO drum writes; P/A/S/Auto keep
    ///   sensitivity camera-owned. Fail closed when the mode is unknown.
    public static func allowsManualISO(codec: String, exposureMode: String?) -> Bool {
        if showsDualBaseCircuits(codec: codec) { return true }
        return exposureMode == "M"
    }

    /// True when the ISO value drum is camera-owned (Auto On, or non-R3D mode is not M).
    ///
    /// Always `false` for R3D NE dual-base (manual circuits); recording lock is separate.
    public static func isISOValueCameraOwned(
        codec: String,
        isoAuto: Bool?,
        exposureMode: String?
    ) -> Bool {
        if showsDualBaseCircuits(codec: codec) { return false }
        return isAutoISOActive(isoAuto: isoAuto)
            || !allowsManualISO(codec: codec, exposureMode: exposureMode)
    }

    /// Label written for Auto On (`MovISOAutoControl` UINT8 = 1).
    public static let autoISOOnLabel = "ON"

    /// Label written for Auto Off (`MovISOAutoControl` UINT8 = 0).
    public static let autoISOOffLabel = "OFF"

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
    public static func pickerSubtitle(codec: String, exposureMode: String? = nil) -> String {
        if showsDualBaseCircuits(codec: codec) { return "Sensitivity · dual base" }
        if showsAutoISOControl(codec: codec) {
            if allowsManualISO(codec: codec, exposureMode: exposureMode) {
                return "Sensitivity · auto / manual"
            }
            return "Sensitivity · auto (M mode for manual)"
        }
        return "Sensitivity"
    }

    /// Mode tabs for the ISO picker.
    /// R3D NE → Low/High base; other codecs → Auto On / Auto Off (Auto Off only in M mode).
    public static func pickerModes(codec: String, exposureMode: String? = nil) -> [ISOPickerMode] {
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
            var modes = [
                ISOPickerMode(
                    title: "Auto On",
                    detail: "Camera controls ISO",
                    options: unifiedOptions,
                    base: lowBaseMarker,
                    activatesAutoISO: true
                )
            ]
            // Manual ISO / Auto Off only when the exposure dial is M (non-R3D).
            if allowsManualISO(codec: codec, exposureMode: exposureMode) {
                modes.append(
                    ISOPickerMode(
                        title: "Auto Off",
                        detail: "Manual ISO",
                        options: unifiedOptions,
                        base: lowBaseMarker,
                        activatesAutoISO: false
                    )
                )
            }
            return modes
        }
        return []
    }

    /// Options for the active ISO layout and mode tab.
    ///
    /// When Auto is driving a value outside the fixed ladder (e.g. 51200), `includingLiveISO`
    /// injects it so the locked drum can centre on the body's working sensitivity.
    public static func options(
        codec: String,
        modeIndex: Int,
        includingLiveISO: String? = nil
    ) -> [String] {
        let modes = pickerModes(codec: codec)
        var base =
            (!modes.isEmpty && modes.indices.contains(modeIndex))
            ? modes[modeIndex].options : unifiedOptions
        if let live = includingLiveISO?.trimmingCharacters(in: .whitespacesAndNewlines),
            !live.isEmpty,
            live.allSatisfy(\.isNumber),
            !base.contains(live)
        {
            let liveValue = UInt32(live) ?? 0
            if let insertAt = base.firstIndex(where: { (UInt32($0) ?? 0) > liveValue }) {
                base.insert(live, at: insertAt)
            } else {
                base.append(live)
            }
        }
        return base
    }

    /// Active mode tab for Auto ISO codecs: 0 = Auto On, 1 = Auto Off (when available).
    public static func autoISOModeIndex(
        codec: String,
        isoAuto: Bool?,
        exposureMode: String? = nil
    ) -> Int {
        // Without Auto Off (non-M on non-R3D), stay on the only tab.
        guard allowsManualISO(codec: codec, exposureMode: exposureMode) else { return 0 }
        return isAutoISOActive(isoAuto: isoAuto) ? 0 : 1
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
