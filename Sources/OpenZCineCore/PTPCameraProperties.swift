import Foundation

/// Camera controls currently backed by known Nikon movie property writes.
///
/// `.codec` and `.resolution` never use label-based encoding: the picker writes the camera's own
/// advertised raw value back via `screenSize(raw:)` / `fileType(raw:)` — never a hand-packed
/// guess. Writes go through the standard `SetDevicePropValue` (0x1016) during live view via the
/// safe-point write queue, surfacing a clear message on rejection. [verify-on-HW]
public enum PTPCameraControl: Equatable, Sendable {
    case iso
    case shutter
    case iris
    case whiteBalanceKelvin
    case codec
    case resolution
    case focusMode
    case focusArea
    case focusSubject
    case exposureMode
    case audioSensitivity
    case audioInput
    case windFilter
    case attenuator
    case audio32BitFloat
}

extension PTPPropertyCode {
    /// One-at-a-time property polling order used between live-view frame requests.
    public static let liveMonitorPollOrder: [PTPPropertyCode] = [
        .movieISOSensitivity,
        .movieBaseISO,
        .movieShutterMode,
        .movieTVLockSetting,
        .movieShutterAngle,
        .movieShutterSpeed,
        .movieFNumber,
        .movieWhiteBalance,
        .movieWBColorTemp,
        .movieRecordScreenSize,
        .movieFileType,
        .exposureProgramMode,
        .batteryLevel,
        .acPower,
        .warningStatus,
        .focalLength,
        .lensFocalMin,
        .lensFocalMax,
        .lensApertureMin,
        .movieFocusMode,
        .movieFocusMeteringMode,
        .movieAFSubjectDetection,
        // Command-monitor extras (audio / stabilisation). The ZR-documented sound properties are
        // written by the command Audio tiles; the libgphoto2-era mic codes stay as read fallbacks.
        .movMicrophone,
        .movRecordMicrophoneLevelValue,
        .movWindNoiseReduction,
        .movieAttenuator,
        .audioInputSelection,
        .movieAudioInputSensitivity,
        .movie32BitFloatAudioRecording,
        .gridDisplay,
        .movieVibrationReduction,
        .electronicVR,
    ]

    /// The compact health set used during a take. Recording state, timecode, and virtual horizon
    /// already arrive in each LiveViewObject header, so repeatedly reading exposure, lens, audio,
    /// and picker properties during recording only heats the camera radio without improving the
    /// monitor. Battery/power/warning status remain visible for safety.
    public static let recordingMonitorPollOrder: [PTPPropertyCode] = [
        .batteryLevel,
        .acPower,
        .warningStatus,
    ]

    /// Chooses the appropriate monitor polling set for the current camera state.
    public static func monitorPollOrder(isRecording: Bool) -> [PTPPropertyCode] {
        isRecording ? recordingMonitorPollOrder : liveMonitorPollOrder
    }
}

/// Cadence rules for non-frame monitor traffic. Keeping these pure and portable lets every shell
/// use the same conservative camera-load budget.
public enum CameraMonitorPollPolicy {
    /// Re-read free space during a take often enough for a useful remaining-time estimate, but not
    /// on every monitor round trip.
    public static let storageRefreshInterval: TimeInterval = 15
    /// Lens/mode descriptors are static in normal operation; only refresh them periodically when
    /// not recording (and immediately after a fresh connection).
    public static let descriptorRefreshInterval: TimeInterval = 60
    /// Maximum rate for one of the compact health-property reads during a take.
    public static let recordingPropertyPollInterval: TimeInterval = 2

    /// True if no refresh has run yet or the given interval has elapsed.
    public static func isDue(
        lastRefreshAt: Date?,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= interval
    }
}

/// One encoded `SetDevicePropValueEx` request.
public struct PTPCameraPropertyWrite: Equatable, Sendable {
    public init(property: PTPPropertyCode, data: Data) {
        self.property = property
        self.data = data
    }

    public let property: PTPPropertyCode
    public let data: Data

    /// Builds a property write from a control label.
    public static func request(control: PTPCameraControl, label: String) -> PTPCameraPropertyWrite?
    {
        switch control {
        case .iso:
            guard let iso = UInt32(label.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return PTPCameraPropertyWrite(
                property: .movieISOSensitivity,
                data: Data(ByteCoding.uint32LE(iso))
            )
        case .shutter:
            return shutterWrite(label: label)
        case .iris:
            guard let fNumber = scaledDouble(label: label, prefix: "f/") else { return nil }
            return PTPCameraPropertyWrite(
                property: .movieFNumber,
                data: Data(ByteCoding.uint16LE(UInt16((fNumber * 100).rounded())))
            )
        case .whiteBalanceKelvin:
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let kelvin = UInt16(trimmed.replacingOccurrences(of: "K", with: "")) {
                return PTPCameraPropertyWrite(
                    property: .movieWBColorTemp,
                    data: Data(ByteCoding.uint16LE(kelvin))
                )
            }
            // A named preset (Auto, Cloudy, …) writes the white-balance MODE property instead.
            // Unverified against hardware — Nikon may reject WB-mode writes during live view, like
            // codec/resolution.
            if let code = PTPCameraPropertyDecoders.wbModeCode(for: trimmed) {
                return PTPCameraPropertyWrite(
                    property: .movieWhiteBalance,
                    data: Data(ByteCoding.uint16LE(code))
                )
            }
            return nil
        case .focusMode:
            guard let code = PTPCameraPropertyDecoders.movieFocusModeCode(for: label) else {
                return nil
            }
            return PTPCameraPropertyWrite(property: .movieFocusMode, data: Data([code]))
        case .focusArea:
            guard let code = PTPCameraPropertyDecoders.movieFocusAreaCode(for: label) else {
                return nil
            }
            return PTPCameraPropertyWrite(
                property: .movieFocusMeteringMode, data: Data(ByteCoding.uint16LE(code)))
        case .focusSubject:
            guard let code = PTPCameraPropertyDecoders.movieAFSubjectCode(for: label) else {
                return nil
            }
            return PTPCameraPropertyWrite(property: .movieAFSubjectDetection, data: Data([code]))
        case .exposureMode:
            // UINT16, written via the standard SetDevicePropValue (0x500E is 2-byte).
            // [verify-on-HW: the ZR's physical mode dial owns this; confirm the write is accepted.]
            guard let code = PTPCameraPropertyDecoders.exposureProgramCode(for: label) else {
                return nil
            }
            return PTPCameraPropertyWrite(
                property: .exposureProgramMode, data: Data(ByteCoding.uint16LE(code)))
        case .audioSensitivity:
            // INT8 property; 0xFF (Auto) or 1…20 rides in one byte either way.
            guard let code = PTPCameraPropertyDecoders.audioInputSensitivityCode(for: label)
            else { return nil }
            return PTPCameraPropertyWrite(
                property: .movieAudioInputSensitivity, data: Data([code]))
        case .audioInput:
            guard let code = PTPCameraPropertyDecoders.audioInputSelectionCode(for: label) else {
                return nil
            }
            return PTPCameraPropertyWrite(property: .audioInputSelection, data: Data([code]))
        case .windFilter:
            guard let code = PTPCameraPropertyDecoders.onOffCode(for: label) else { return nil }
            return PTPCameraPropertyWrite(property: .movWindNoiseReduction, data: Data([code]))
        case .attenuator:
            guard let code = PTPCameraPropertyDecoders.onOffCode(for: label) else { return nil }
            return PTPCameraPropertyWrite(property: .movieAttenuator, data: Data([code]))
        case .audio32BitFloat:
            guard let code = PTPCameraPropertyDecoders.onOffCode(for: label) else { return nil }
            return PTPCameraPropertyWrite(
                property: .movie32BitFloatAudioRecording, data: Data([code]))
        case .codec, .resolution:
            // Label-based encoding is intentionally unsupported: the picker writes the camera's
            // exact advertised raw value directly via `screenSize(raw:)` / `fileType(raw:)`
            // instead of routing through here (see `applyPickerValue`).
            return nil
        }
    }

    /// Builds a property write from a control label, given a snapshot for context. `.codec` and
    /// `.resolution` return `nil` here too — the picker writes their raw values directly.
    public static func request(
        control: PTPCameraControl,
        label: String,
        snapshot: PTPCameraPropertySnapshot
    ) -> PTPCameraPropertyWrite? {
        request(control: control, label: label)
    }

    /// All property writes a picker selection should send — usually one, but a **Kelvin** white
    /// balance needs **two**: switch into colour-temperature mode (`MovieWhiteBalance` = "Color
    /// temp") *then* set `MovieWBColorTemp`. Writing only the temperature leaves the body in its
    /// current preset mode and the Kelvin never takes effect.
    public static func requests(
        control: PTPCameraControl,
        label: String,
        snapshot: PTPCameraPropertySnapshot
    ) -> [PTPCameraPropertyWrite] {
        if control == .whiteBalanceKelvin {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let kelvin = UInt16(trimmed.replacingOccurrences(of: "K", with: "")),
                let colorTempMode = PTPCameraPropertyDecoders.wbModeCode(for: "Color temp")
            {
                return [
                    PTPCameraPropertyWrite(
                        property: .movieWhiteBalance,
                        data: Data(ByteCoding.uint16LE(colorTempMode))),
                    PTPCameraPropertyWrite(
                        property: .movieWBColorTemp, data: Data(ByteCoding.uint16LE(kelvin))),
                ]
            }
        }
        return request(control: control, label: label, snapshot: snapshot).map { [$0] } ?? []
    }

    /// A `MovScreenSize` write for an exact camera-advertised mode value (from the descriptor enum).
    public static func screenSize(raw: UInt64) -> PTPCameraPropertyWrite {
        PTPCameraPropertyWrite(
            property: .movieRecordScreenSize, data: Data(ByteCoding.uint64LE(raw)))
    }

    /// A `MovFileType` write for an exact camera-advertised codec value (from the descriptor enum).
    public static func fileType(raw: UInt32) -> PTPCameraPropertyWrite {
        PTPCameraPropertyWrite(property: .movieFileType, data: Data(ByteCoding.uint32LE(raw)))
    }

    public static func shutterMode(_ mode: ShutterDisplayMode) -> PTPCameraPropertyWrite {
        PTPCameraPropertyWrite(
            property: .movieShutterMode,
            data: Data([PTPCameraPropertyDecoders.shutterModeCode(mode)])
        )
    }

    /// Writes the movie shutter speed/angle lock (`MovieTVLockSetting` 0x0001_D00F).
    public static func movieTVLock(unlocked: Bool) -> PTPCameraPropertyWrite {
        PTPCameraPropertyWrite(
            property: .movieTVLockSetting,
            data: Data([unlocked ? 0 : 1])
        )
    }

    /// Movie VR write (`MovieVibrationReduction` 0xD1F9, UINT8). 2-byte prop → standard 0x1016
    /// path in the session. [verify-on-HW]
    public static func vibrationReduction(label: String) -> PTPCameraPropertyWrite? {
        guard let code = PTPCameraPropertyDecoders.movieVibrationReductionCode(for: label) else {
            return nil
        }
        return PTPCameraPropertyWrite(property: .movieVibrationReduction, data: Data([code]))
    }

    /// Electronic VR toggle (`ElectronicVR` 0xD314, UINT8 on/off). [verify-on-HW]
    public static func electronicVR(on: Bool) -> PTPCameraPropertyWrite {
        PTPCameraPropertyWrite(property: .electronicVR, data: Data([on ? 1 : 0]))
    }

    /// Encodes a shutter label to a write: a `"N°"` angle to `movieShutterAngle`, or an `"N/D"`
    /// speed fraction to `movieShutterSpeed`.
    private static func shutterWrite(label: String) -> PTPCameraPropertyWrite? {
        if let degrees = scaledDouble(label: label, suffix: "°") {
            return PTPCameraPropertyWrite(
                property: .movieShutterAngle,
                data: Data(ByteCoding.int32LE(Int32((degrees * 100).rounded())))
            )
        }

        let parts = label.split(separator: "/")
        guard parts.count == 2,
            let numerator = UInt32(parts[0]),
            let denominator = UInt32(parts[1]),
            numerator <= UInt32(UInt16.max),
            denominator <= UInt32(UInt16.max)
        else {
            return nil
        }
        let raw = numerator << 16 | denominator
        return PTPCameraPropertyWrite(
            property: .movieShutterSpeed,
            data: Data(ByteCoding.uint32LE(raw))
        )
    }

    private static func scaledDouble(
        label: String,
        prefix: String = "",
        suffix: String = ""
    ) -> Double? {
        var value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            guard value.hasPrefix(prefix) else { return nil }
            value.removeFirst(prefix.count)
        }
        if !suffix.isEmpty {
            guard value.hasSuffix(suffix) else { return nil }
            value.removeLast(suffix.count)
        }
        return Double(value)
    }
}

/// Decoded `MovieRecordScreenSize` value.
public struct PTPCameraScreenSize: Equatable, Sendable {
    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    public let width: Int
    public let height: Int
    public let fps: Int

    public var label: String {
        "\(width)x\(height)"
    }
}

/// One recording mode the camera advertises in its `MovScreenSize` descriptor: the exact packed
/// value to write, plus a display label ("6K · 25p"). Writing only camera-advertised values avoids
/// the invalid combinations (e.g. 6K@60) that make the ZR close the connection.
public struct PTPCameraScreenSizeMode: Equatable, Sendable {
    public init(raw: UInt64, label: String) {
        self.raw = raw
        self.label = label
    }
    /// The exact packed `MovScreenSize` value to write back.
    public let raw: UInt64
    /// Display label, e.g. "6K · 25p".
    public let label: String
}

/// One codec the camera advertises in its `MovFileType` descriptor: the exact packed value to
/// write, plus a short label ("H.265", "R3D NE"). Same rationale as the screen-size modes — write
/// only advertised values so we never send an unsupported codec/depth/container combination.
public struct PTPCameraFileTypeMode: Equatable, Sendable {
    public init(raw: UInt32, label: String) {
        self.raw = raw
        self.label = label
    }
    /// The exact packed `MovFileType` value to write back.
    public let raw: UInt32
    /// Short display label, e.g. "H.265".
    public let label: String
}

/// Whether the camera's shutter readout is in angle (°) or speed (1/x) mode.
public enum ShutterDisplayMode: String, Equatable, Sendable { case angle, speed }

/// Pure decoders for Nikon camera-property values used by the monitor overlay.
public enum PTPCameraPropertyDecoders {
    /// Decodes an f-number from raw value, trimming a trailing `.0` (`f/4`). Used for lens
    /// descriptors, where the marked maximum aperture reads conventionally (`24-120mm f/4`).
    public static func fNumber(_ raw: UInt16) -> String {
        if raw == UInt16.max { return "—" }
        return "f/\(trimmedDecimal(Double(raw) / 100))"
    }

    /// Decodes an f-number for the IRIS readout, always to one decimal place (`f/2.0`, never
    /// `f/2`), so the live aperture matches the camera's IRIS option list and never jumps width.
    public static func irisFNumber(_ raw: UInt16) -> String {
        if raw == UInt16.max { return "—" }
        return String(format: "f/%.1f", Double(raw) / 100)
    }

    /// The third-stop aperture ladder (widest to narrowest) the IRIS picker falls back to when the
    /// camera hasn't enumerated its own f-numbers yet. Third stops so values like f/3.2 / f/3.5
    /// appear, matching how the camera steps aperture.
    private static let apertureLadder: [Double] = [
        1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10.0,
        11.0, 13.0, 14.0, 16.0, 18.0, 20.0, 22.0,
    ]

    /// Maps a camera-reported f-number enumeration (raw ×100 values from `GetDevicePropDesc`) to
    /// IRIS option strings, dropping the "no value" sentinel. This is the *authoritative* aperture
    /// list — the camera only enumerates stops valid for the lens currently mounted.
    public static func apertureList(fromEnum rawValues: [UInt32]) -> [String] {
        rawValues
            .map { irisFNumber(UInt16(truncatingIfNeeded: $0)) }
            .filter { $0 != "—" }
    }

    /// The apertures the *mounted lens* can select, as the third-stop f-number ladder from the
    /// lens's marked maximum aperture (smallest f-number) up to f/22 — so an f/2.8 lens never offers
    /// f/1.4 or f/2.0. The lens's own widest aperture leads the list even when it sits between stops
    /// (e.g. f/1.8). Parsed from a lens descriptor such as `"24-70mm f/2.8"`; falls back to the full
    /// ladder when no aperture is present. Used until the camera enumerates its real f-numbers.
    public static func availableApertures(forLens lensDescriptor: String?) -> [String] {
        let format: (Double) -> String = { String(format: "f/%.1f", $0) }
        guard let widest = wideAperture(fromLens: lensDescriptor) else {
            return apertureLadder.map(format)
        }
        var stops = apertureLadder.filter { $0 >= widest - 0.05 }
        if let first = stops.first {
            if abs(first - widest) > 0.05 { stops.insert(widest, at: 0) }
        } else {
            stops = [widest]
        }
        return stops.map(format)
    }

    /// Extracts the marked maximum aperture (the f-number after `f/`) from a lens descriptor.
    static func wideAperture(fromLens lensDescriptor: String?) -> Double? {
        guard let lensDescriptor,
            let range = lensDescriptor.range(
                of: #"f/\d+(\.\d+)?"#, options: .regularExpression)
        else { return nil }
        return Double(lensDescriptor[range].dropFirst(2))
    }

    /// Decodes shutter speed from raw value.
    public static func shutterSpeed(_ raw: UInt32) -> String {
        let numerator = (raw >> 16) & 0xFFFF
        let denominator = raw & 0xFFFF
        if denominator == 0 { return "—" }
        if denominator == 1 { return "\(numerator)s" }
        if numerator == 1 { return "1/\(denominator)" }
        return "\(numerator)/\(denominator)"
    }

    /// Decodes shutter angle from raw value.
    public static func shutterAngle(_ raw: Int32) -> String {
        "\(trimmedDecimal(Double(raw) / 100))°"
    }

    /// Decodes focal length from raw value.
    public static func focalLengthMillimeters(_ raw: UInt32) -> String {
        "\(trimmedDecimal(Double(raw) / 100)) mm"
    }

    /// Decodes screen size from raw value.
    public static func screenSize(_ raw: UInt64) -> PTPCameraScreenSize {
        PTPCameraScreenSize(
            width: Int((raw >> 48) & 0xFFFF),
            height: Int((raw >> 32) & 0xFFFF),
            fps: Int((raw >> 16) & 0xFF)
        )
    }

    /// Extracts the enumerated `MovScreenSize` modes from a DevicePropDesc — the exact 8-byte values
    /// the camera will accept. Each is decoded to a "6K · 25p"-style label (matching the picker).
    /// Implausible entries are dropped so a wrongly anchored parse can't surface a value we'd write.
    public static func screenSizeModes(fromDescriptor data: Data) -> [PTPCameraScreenSizeMode] {
        let bytes = [UInt8](data)
        // Enumeration form: FormFlag 0x02, UINT16 count, then count × 8-byte values. Prefer an
        // exact flush-to-end fit (standard DevicePropDesc), but also accept a trailing padding
        // tail some Nikon Ex responses append after the enum block.
        var best: [PTPCameraScreenSizeMode] = []
        for index in bytes.indices where bytes[index] == 0x02 {
            guard index + 3 <= bytes.count else { continue }
            let count = Int(ByteCoding.readUInt16LE(bytes, at: index + 1))
            let start = index + 3
            let payloadBytes = count * 8
            guard count > 0, count <= 256, start + payloadBytes <= bytes.count else { continue }
            let trailing = bytes.count - (start + payloadBytes)
            // Exact fit, or a short padding/name tail (not another full enum).
            guard trailing == 0 || trailing <= 64 else { continue }
            var modes: [PTPCameraScreenSizeMode] = []
            for slot in 0..<count {
                let raw = ByteCoding.readUInt64LE(bytes, at: start + slot * 8)
                let size = screenSize(raw)
                guard size.width >= 640, size.width <= 8192, size.height >= 360,
                    size.height <= 5000, size.fps >= 1, size.fps <= 240
                else { continue }
                modes.append(
                    PTPCameraScreenSizeMode(
                        raw: raw,
                        label: MonitorTextFormat.resolutionLabel(
                            pixelWidth: size.width, pixelHeight: size.height,
                            frameRate: Double(size.fps))))
            }
            if modes.count > best.count {
                best = modes
                if trailing == 0 { return best }
            }
        }
        return best
    }

    /// Decodes file type from raw value.
    public static func fileType(_ raw: UInt32) -> String {
        let codec = codecNames[(raw >> 16) & 0xFF] ?? hex((raw >> 16) & 0xFF)
        let depth = (raw >> 8) & 0xFF
        let container = containerNames[raw & 0xFF] ?? hex(raw & 0xFF)
        return "\(codec) \(depth)-bit \(container)"
    }

    /// Maps the camera's advertised `MovFileType` enum values to codec modes — the exact value to
    /// write plus a short label ("H.265") matching the bar. Deduped by label (the picker shows one
    /// row per codec family); only values whose codec is recognised are kept.
    public static func fileTypeModes(fromEnum values: [UInt32]) -> [PTPCameraFileTypeMode] {
        var seen = Set<String>()
        var modes: [PTPCameraFileTypeMode] = []
        for raw in values {
            guard codecNames[(raw >> 16) & 0xFF] != nil else { continue }
            let label = MonitorTextFormat.codecShortLabel(fileType(raw))
            if seen.insert(label).inserted {
                modes.append(PTPCameraFileTypeMode(raw: raw, label: label))
            }
        }
        return modes
    }

    /// Decodes white balance mode from raw value.
    public static func whiteBalanceMode(_ raw: UInt16) -> String {
        wbModeNames[raw] ?? hex(UInt32(raw))
    }

    /// Encodes a white-balance preset label back to its raw mode value (inverse of
    /// `whiteBalanceMode`). Returns nil for labels that aren't named presets (e.g. Kelvin readouts).
    public static func wbModeCode(for label: String) -> UInt16? {
        wbModeNames.first { $0.value == label }?.key
    }

    /// Decodes base ISO from raw value.
    public static func baseISO(_ raw: UInt8) -> String {
        switch raw {
        case 1: "Low"
        case 2: "High"
        default: hex(UInt32(raw))
        }
    }

    /// Decodes `ExposureProgramMode` (`0x500E`, UINT16) into a compact MODE-tile label.
    /// Values from libgphoto2 `config.c:4110` (`exposure_program_modes`): standard P/S/A/M plus
    /// the Nikon auto/scene/U1–U3 user modes. Unknown values fall back to the hex so a body that
    /// reports an undocumented mode still shows something meaningful rather than "L".
    /// [verify-on-HW: confirm the ZR's movie mode dial reports through this stills property.]
    public static func exposureProgramShort(_ raw: UInt16) -> String {
        switch raw {
        case 0x0001: "M"
        case 0x0002: "P"
        case 0x0003: "A"
        case 0x0004: "S"
        case 0x8010: "Auto"
        case 0x8011: "Portrait"
        case 0x8012: "Landscape"
        case 0x8013: "Macro"
        case 0x8014: "Sports"
        case 0x8015: "Night"
        case 0x8016: "Night LS"
        case 0x8017: "Kids"
        case 0x8018: "Auto (NF)"
        case 0x8050: "U1"
        case 0x8051: "U2"
        case 0x8052: "U3"
        default: hex(UInt32(raw))
        }
    }

    /// Inverse of `exposureProgramShort` for the writable ladder (Auto/P/A/S/M/U1–U3). The scene
    /// modes are intentionally omitted — the MODE picker only offers the P/A/S/M + auto/user set.
    /// Returns nil for a label that isn't one of those (the write is then a no-op).
    public static func exposureProgramCode(for label: String) -> UInt16? {
        switch label {
        case "M": 0x0001
        case "P": 0x0002
        case "A": 0x0003
        case "S": 0x0004
        case "Auto": 0x8010
        case "U1": 0x8050
        case "U2": 0x8051
        case "U3": 0x8052
        default: nil
        }
    }

    /// Decodes `MovieShutterMode` (`0x0001_D074`, UINT8):
    /// `1` = shutter speed, `2` = shutter angle.
    public static func shutterMode(_ raw: UInt8) -> ShutterDisplayMode {
        switch raw {
        case 1: .speed
        case 2: .angle
        default: .angle
        }
    }
    public static func shutterModeCode(_ mode: ShutterDisplayMode) -> UInt8 {
        switch mode {
        case .speed: 1
        case .angle: 2
        }
    }

    // MARK: - Movie AF (MovieFocusMode / MovieFocusMeteringMode / MovieAFSubjectDetection)
    //
    // Value tables from observed ZR behavior. The labels match the FOCUS picker's
    // drum options so they round-trip cleanly.

    /// Picker labels for `MovieFocusMode` (0xD1FA). Always offered even when the body temporarily
    /// restricts its descriptor enum to MF-only after a lens focus-ring override.
    public static let movieFocusModePickerOptions: [String] = ["AF-S", "AF-C", "AF-F", "MF"]

    /// `MovieFocusMode` (0xD1FA, UINT8) raw → label.
    ///
    /// Raw values: `0` AF-S · `1` AF-C · `2` AF-F · `3` MF fixed (lens-ring
    /// override) · `4` MF selected (menu/app MF).
    public static func movieFocusMode(_ raw: UInt8) -> String {
        switch raw {
        case 0: "AF-S"
        case 1: "AF-C"
        case 2: "AF-F"
        case 3, 4: "MF"
        default: hex(UInt32(raw))
        }
    }

    /// Merges the camera's advertised focus-mode enum with the full picker list so AF modes stay
    /// selectable after a lens focus-ring override narrows the descriptor to MF-only.
    public static func mergedMovieFocusModeOptions(advertised: [String]) -> [String] {
        var seen = Set<String>()
        return (movieFocusModePickerOptions + advertised).filter { seen.insert($0).inserted }
    }

    /// Whether a decoded `MovieFocusMode` label is any MF variant (lens-ring or menu-selected).
    public static func isMovieFocusManual(_ label: String?) -> Bool {
        label == "MF"
    }

    /// Inverse of `movieFocusMode`, for encoding a picker selection.
    public static func movieFocusModeCode(for label: String) -> UInt8? {
        switch label {
        case "AF-S": 0
        case "AF-C": 1
        case "AF-F": 2
        case "MF": 4
        default: nil
        }
    }

    /// `MovieFocusMeteringMode` (0xD1F8, UINT16, the AF-area mode) raw → label.
    public static func movieFocusArea(_ raw: UInt16) -> String {
        switch raw {
        case 0x8010: "Single"
        case 0x8011: "Auto"
        case 0x8018: "Wide-S"
        case 0x8019: "Wide-L"
        case 0x801E: "Wide-C1"
        case 0x801F: "Wide-C2"
        case 0x8033: "Subject"
        default: hex(UInt32(raw))
        }
    }

    /// Inverse of `movieFocusArea`.
    public static func movieFocusAreaCode(for label: String) -> UInt16? {
        switch label {
        case "Single": 0x8010
        case "Auto": 0x8011
        case "Wide-S": 0x8018
        case "Wide-L": 0x8019
        case "Wide-C1": 0x801E
        case "Wide-C2": 0x801F
        case "Subject": 0x8033
        default: nil
        }
    }

    /// `MovieAFSubjectDetection` (0x0001D006, UINT8) raw → label. Singular labels match the picker.
    public static func movieAFSubject(_ raw: UInt8) -> String {
        switch raw {
        case 0: "Off"
        case 1: "Auto"
        case 2: "People"
        case 3: "Animal"
        case 4: "Vehicle"
        case 5: "Bird"
        case 6: "Airplane"
        default: hex(UInt32(raw))
        }
    }

    /// Inverse of `movieAFSubject`.
    public static func movieAFSubjectCode(for label: String) -> UInt8? {
        switch label {
        case "Off": 0
        case "Auto": 1
        case "People": 2
        case "Animal": 3
        case "Vehicle": 4
        case "Bird": 5
        case "Airplane": 6
        default: nil
        }
    }

    /// `MovMicrophone` (0xD0A2, UINT8) raw → label. Table from libgphoto2 `nikon_microphone`
    /// (config.c:6915).
    public static func movMicrophone(_ raw: UInt8) -> String {
        switch raw {
        case 0: "Auto"
        case 1: "High"
        case 2: "Medium"
        case 3: "Low"
        case 4: "Off"
        default: hex(UInt32(raw))
        }
    }

    /// UINT8 on/off properties (wind filter, attenuator, electronic VR, e-shutter) → label.
    public static func onOffLabel(_ raw: UInt8) -> String {
        raw == 0 ? "OFF" : "ON"
    }

    /// Inverse of `onOffLabel`, for encoding a picker selection.
    public static func onOffCode(for label: String) -> UInt8? {
        switch label.uppercased() {
        case "OFF": 0
        case "ON": 1
        default: nil
        }
    }

    /// `AudioInputSelection` (0x0001D04D, UINT8) raw → label. The external
    /// mic/line input switch. [verify-on-HW]
    public static func audioInputSelection(_ raw: UInt8) -> String {
        switch raw {
        case 1: "Microphone"
        case 2: "Line"
        default: hex(UInt32(raw))
        }
    }

    /// Inverse of `audioInputSelection`, for encoding a picker selection.
    public static func audioInputSelectionCode(for label: String) -> UInt8? {
        switch label {
        case "Microphone": 1
        case "Line": 2
        default: nil
        }
    }

    /// `MovieAudioInputSensitivity` (0x0001D070, INT8) raw → label:
    /// `0xFF` Auto, 0…20 manual steps. [verify-on-HW]
    public static func audioInputSensitivity(_ raw: UInt8) -> String {
        raw == 0xFF ? "Auto" : String(raw)
    }

    /// Inverse of `audioInputSensitivity`, for encoding a picker selection. Manual steps offered
    /// to the operator are 1…20 — the body refuses writes of zero.
    public static func audioInputSensitivityCode(for label: String) -> UInt8? {
        if label == "Auto" { return 0xFF }
        guard let value = UInt8(label), (1...20).contains(value) else { return nil }
        return value
    }

    /// `MovieVibrationReduction` (0xD1F9, UINT8) raw → label. Value table
    /// [ZR-only · verify-on-HW]: libgphoto2 has the code but no config.c table.
    public static func movieVibrationReduction(_ raw: UInt8) -> String {
        switch raw {
        case 0: "OFF"
        case 1: "ON"
        case 2: "SPORT"
        default: hex(UInt32(raw))
        }
    }

    /// Inverse of `movieVibrationReduction`, for encoding a picker selection.
    public static func movieVibrationReductionCode(for label: String) -> UInt8? {
        switch label {
        case "OFF": 0
        case "ON": 1
        case "SPORT": 2
        default: nil
        }
    }

    /// Non-zero when the body's movie shutter speed/angle control lock is engaged.
    public static func controlLockEnabled(_ raw: UInt8) -> Bool {
        raw != 0
    }

    /// Manual microphone recording level (`MovRecordMicrophoneLevelValue` 0xD0A8).
    public static func microphoneLevel(_ raw: UInt8) -> String {
        String(raw)
    }

    /// Short label for the command grid's dual-base ISO circuit ("L" / "H").
    public static func baseISOCircuitShort(_ label: String?) -> String? {
        switch label {
        case "Low": "L"
        case "High": "H"
        default: nil
        }
    }

    /// Command-monitor stabilisation summary: movie VR (0xD1F9) + electronic VR (0xD314).
    /// The stills-only e-front-curtain-shutter (0xD20D) is deliberately NOT part of this —
    /// it is meaningless on a video monitor.
    public static func stabilizationSummary(
        vibrationReduction: String?,
        electronicVR: String?
    ) -> String? {
        switch (vibrationReduction, electronicVR) {
        case (nil, nil): nil
        case (let vr?, nil): vr
        case (nil, let evr?): evr
        case (let vr?, let evr?) where vr == evr: vr
        case (let vr?, let evr?): "\(vr)/\(evr)"
        }
    }

    /// Infers the automatic tone/gamma label used by exposure assists from the reported codec.
    public static func toneLabel(fromCodec codec: String) -> String? {
        guard !codec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ExposureToneCurve.forCameraCodec(codec) == .redLog3G10 ? "Log3G10" : "N-Log"
    }

    /// Builds a lens description from focal length and aperture values.
    public static func lens(
        focalMinX100: UInt32?,
        focalMaxX100: UInt32?,
        apertureMinX100: UInt16?
    ) -> String? {
        guard let focalMinX100, let focalMaxX100 else { return nil }
        if focalMinX100 == 0 && focalMaxX100 == 0 { return nil }
        let lo = trimmedDecimal(Double(focalMinX100) / 100)
        let hi = trimmedDecimal(Double(focalMaxX100) / 100)
        let range = lo == hi ? "\(lo)mm" : "\(lo)-\(hi)mm"
        guard let apertureMinX100, apertureMinX100 != 0 else { return range }
        return "\(range) \(fNumber(apertureMinX100))"
    }

    /// Extracts enum values from a DevicePropDesc dataset. Handles 1-byte (UINT8), 2-byte (UINT16)
    /// and 4-byte (UINT32) value widths — UINT8 covers movie-AF properties like `MovieFocusMode`.
    public static func devicePropDescEnumValues(data: Data, valueByteCount: Int) -> [UInt32] {
        let bytes = Array(data)
        guard valueByteCount == 1 || valueByteCount == 2 || valueByteCount == 4 else { return [] }
        for index in 0..<max(bytes.count - 2, 0) {
            guard bytes[index] == 0x02 else { continue }
            let count = Int(ByteCoding.readUInt16LE(bytes, at: index + 1))
            let start = index + 3
            guard count > 0, start + count * valueByteCount == bytes.count else { continue }
            return (0..<count).map { item in
                let offset = start + item * valueByteCount
                switch valueByteCount {
                case 1: return UInt32(bytes[offset])
                case 2: return UInt32(ByteCoding.readUInt16LE(bytes, at: offset))
                default: return ByteCoding.readUInt32LE(bytes, at: offset)
                }
            }
        }
        return []
    }

    /// Maps a property's advertised descriptor-enum values to picker option labels, decoding each
    /// through the *same* table the live snapshot uses so the options round-trip with the writes the
    /// pickers send back. Values the decoder doesn't recognise (hex placeholders), the "no value"
    /// sentinel, and shutter speeds the encoder can't parse are dropped; duplicates collapse, order
    /// is preserved. Returns `[]` for properties without a picker mapping (the caller keeps its
    /// hardcoded fallback). Enables driving the AF / shutter / WB-preset wheels from any body that
    /// enumerates these properties — not just the ZR.
    public static func optionLabels(for property: PTPPropertyCode, rawValues: [UInt32]) -> [String]
    {
        var seen = Set<String>()
        return rawValues.compactMap { raw -> String? in
            let label: String
            switch property {
            case .movieShutterAngle:
                label = shutterAngle(Int32(bitPattern: raw))
            case .movieShutterSpeed:
                let speed = shutterSpeed(raw)
                // Only fractional / whole-second speeds the `shutterWrite` encoder parses back; a
                // bare "Ns" form has no "/" and couldn't be written, so don't offer it.
                guard speed.contains("/") else { return nil }
                label = speed
            case .movieWhiteBalance:
                label = whiteBalanceMode(UInt16(truncatingIfNeeded: raw))
            case .movieFocusMode:
                label = movieFocusMode(UInt8(truncatingIfNeeded: raw))
            case .movieFocusMeteringMode:
                label = movieFocusArea(UInt16(truncatingIfNeeded: raw))
            case .movieAFSubjectDetection:
                label = movieAFSubject(UInt8(truncatingIfNeeded: raw))
            case .movieVibrationReduction:
                label = movieVibrationReduction(UInt8(truncatingIfNeeded: raw))
            default:
                return nil
            }
            guard !label.hasPrefix("0x"), label != "—" else { return nil }
            return seen.insert(label).inserted ? label : nil
        }
    }

    private static let codecNames: [UInt32: String] = [
        0x00: "H.264",
        0x01: "H.265",
        0x02: "N-RAW",
        0x10: "ProRes 422 HQ",
        0x11: "ProRes RAW HQ",
        0x31: "R3D NE",
    ]

    private static let containerNames: [UInt32: String] = [
        0: "MOV",
        1: "MP4",
        2: "NEV",
        3: "R3D",
    ]

    private static let wbModeNames: [UInt16: String] = [
        0x0002: "Auto",
        0x0004: "Sunny",
        0x0005: "Fluorescent",
        0x0006: "Incandescent",
        0x0007: "Flash",
        0x8010: "Cloudy",
        0x8011: "Shade",
        0x8012: "Color temp",
        0x8013: "Preset",
        0x8016: "Natural auto",
    ]

    private static func trimmedDecimal(_ value: Double) -> String {
        let string = String(format: "%.1f", value)
        return string.hasSuffix(".0") ? String(string.dropLast(2)) : string
    }

    private static func hex(_ value: UInt32) -> String {
        "0x\(String(value, radix: 16))"
    }
}

/// Accumulated camera-property values from the live monitor's round-robin polling.
public struct PTPCameraPropertySnapshot: Equatable, Sendable {
    public init(
        iso: UInt32? = nil,
        baseISO: String? = nil,
        exposureMode: String? = nil,
        shutterMode: ShutterDisplayMode? = nil,
        shutterLocked: Bool? = nil,
        shutterSpeed: String? = nil,
        shutterAngle: String? = nil,
        fNumber: String? = nil,
        wbMode: String? = nil,
        wbKelvin: UInt16? = nil,
        resolution: String? = nil,
        fps: Int? = nil,
        rawScreenSize: UInt64? = nil,
        fileType: String? = nil,
        batteryPercent: Int? = nil,
        onExternalPower: Bool? = nil,
        warningRaw: UInt8? = nil,
        focalLength: String? = nil,
        focalMinX100: UInt32? = nil,
        focalMaxX100: UInt32? = nil,
        apertureMinX100: UInt16? = nil,
        focusMode: String? = nil,
        focusArea: String? = nil,
        focusSubject: String? = nil,
        microphoneSensitivity: String? = nil,
        microphoneLevel: String? = nil,
        windNoiseReduction: String? = nil,
        inputAttenuator: String? = nil,
        audioInput: String? = nil,
        audioSensitivity: String? = nil,
        audio32BitFloat: String? = nil,
        vibrationReduction: String? = nil,
        electronicVR: String? = nil,
        gridDisplay: String? = nil
    ) {
        self.iso = iso
        self.baseISO = baseISO
        self.exposureMode = exposureMode
        self.shutterMode = shutterMode
        self.shutterLocked = shutterLocked
        self.shutterSpeed = shutterSpeed
        self.shutterAngle = shutterAngle
        self.fNumber = fNumber
        self.wbMode = wbMode
        self.wbKelvin = wbKelvin
        self.resolution = resolution
        self.fps = fps
        self.rawScreenSize = rawScreenSize
        self.fileType = fileType
        self.batteryPercent = batteryPercent
        self.onExternalPower = onExternalPower
        self.warningRaw = warningRaw
        self.focalLength = focalLength
        self.focalMinX100 = focalMinX100
        self.focalMaxX100 = focalMaxX100
        self.apertureMinX100 = apertureMinX100
        self.focusMode = focusMode
        self.focusArea = focusArea
        self.focusSubject = focusSubject
        self.microphoneSensitivity = microphoneSensitivity
        self.microphoneLevel = microphoneLevel
        self.windNoiseReduction = windNoiseReduction
        self.inputAttenuator = inputAttenuator
        self.audioInput = audioInput
        self.audioSensitivity = audioSensitivity
        self.audio32BitFloat = audio32BitFloat
        self.vibrationReduction = vibrationReduction
        self.electronicVR = electronicVR
        self.gridDisplay = gridDisplay
    }

    // Exposure.
    public let iso: UInt32?
    public let baseISO: String?
    public let exposureMode: String?  // Auto/P/S/A/M/U1–U3, decoded from 0x500E
    public let shutterMode: ShutterDisplayMode?
    public let shutterLocked: Bool?  // movie shutter speed/angle lock (MovieTVLockSetting)
    public let shutterSpeed: String?
    public let shutterAngle: String?
    public let fNumber: String?

    // White balance + recording format.
    public let wbMode: String?
    public let wbKelvin: UInt16?
    public let resolution: String?
    public let fps: Int?
    /// The camera's raw packed `MovScreenSize` (0xD0A0) value, kept verbatim so a frame-rate change
    /// can edit only the fps byte and preserve every other bit the body encodes. `nil` until polled.
    public let rawScreenSize: UInt64?
    public let fileType: String?

    // Body health.
    public let batteryPercent: Int?  // 1–100, from MTP BatteryLevel (0x5001)
    /// Whether the camera is on external / USB power (Nikon ACPower 0xD101) — drives the charging
    /// indicator. `nil` until first polled.
    public let onExternalPower: Bool?
    /// Raw `WarningStatus` (0xD102) aggregate warning bitfield, verbatim. `nil` until first polled.
    /// Interpret via `CameraWarningStatus` — the individual bit positions are runtime-enumerated by
    /// the body and verify-on-HW, so this stays raw rather than a set of guessed booleans.
    public let warningRaw: UInt8?
    /// Decoded warning flags (temperature / battery / card), from `warningRaw`. Empty when unpolled
    /// or when the body reports no warnings.
    public var warningStatus: CameraWarningStatus { CameraWarningStatus(raw: warningRaw) }

    // Lens (raw values are ×100).
    public let focalLength: String?
    public let focalMinX100: UInt32?
    public let focalMaxX100: UInt32?
    public let apertureMinX100: UInt16?

    // Movie AF.
    public let focusMode: String?  // MF / AF-S / AF-C / AF-F
    public let focusArea: String?  // Single / Auto / Wide-S / …
    public let focusSubject: String?  // Auto / People / Animal / …

    // Audio.
    public let microphoneSensitivity: String?  // Auto / High / Medium / Low / Off
    public let microphoneLevel: String?  // manual level, 0–20 on ZR [verify-on-HW]
    public let windNoiseReduction: String?
    public let inputAttenuator: String?
    public let audioInput: String?  // AudioInputSelection 0x0001D04D: Microphone / Line
    public let audioSensitivity: String?  // MovieAudioInputSensitivity 0x0001D070: Auto / 1–20
    public let audio32BitFloat: String?  // Movie32BitFloatAudioRecording 0x0001D065

    // Stabilisation + display.
    public let vibrationReduction: String?  // movie VR (lens/in-body)
    public let electronicVR: String?
    public let gridDisplay: String?  // GridDisplay 0xD16C, for the command Monitor tile

    /// Command-monitor stabilisation summary (movie VR + electronic VR).
    public var stabilizationSummary: String? {
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: vibrationReduction,
            electronicVR: electronicVR
        )
    }

    /// Computed lens description.
    public var lens: String? {
        PTPCameraPropertyDecoders.lens(
            focalMinX100: focalMinX100,
            focalMaxX100: focalMaxX100,
            apertureMinX100: apertureMinX100
        )
    }

    /// Returns a new snapshot with the specified property updated.
    public func applying(property: PTPPropertyCode, data: Data) -> PTPCameraPropertySnapshot {
        let bytes = Array(data)
        switch property {
        case .movieISOSensitivity where bytes.count >= 4:
            return replacing(iso: ByteCoding.readUInt32LE(bytes, at: 0))
        case .movieBaseISO where bytes.count >= 1:
            return replacing(baseISO: PTPCameraPropertyDecoders.baseISO(bytes[0]))
        case .exposureProgramMode where bytes.count >= 2:
            return replacing(
                exposureMode: PTPCameraPropertyDecoders.exposureProgramShort(
                    ByteCoding.readUInt16LE(bytes, at: 0)))
        case .movieShutterMode where bytes.count >= 1:
            return replacing(shutterMode: PTPCameraPropertyDecoders.shutterMode(bytes[0]))
        case .movieTVLockSetting where bytes.count >= 1:
            return replacing(
                shutterLocked: PTPCameraPropertyDecoders.controlLockEnabled(bytes[0]))
        case .movieShutterAngle where bytes.count >= 4:
            return replacing(
                shutterAngle: PTPCameraPropertyDecoders.shutterAngle(
                    ByteCoding.readInt32LE(bytes, at: 0)))
        case .movieShutterSpeed where bytes.count >= 4:
            return replacing(
                shutterSpeed: PTPCameraPropertyDecoders.shutterSpeed(
                    ByteCoding.readUInt32LE(bytes, at: 0)))
        case .movieFNumber where bytes.count >= 2:
            return replacing(
                fNumber: PTPCameraPropertyDecoders.irisFNumber(
                    ByteCoding.readUInt16LE(bytes, at: 0)))
        case .movieWhiteBalance where bytes.count >= 2:
            return replacing(
                wbMode: PTPCameraPropertyDecoders.whiteBalanceMode(
                    ByteCoding.readUInt16LE(bytes, at: 0)))
        case .movieWBColorTemp where bytes.count >= 2:
            return replacing(wbKelvin: ByteCoding.readUInt16LE(bytes, at: 0))
        case .movieRecordScreenSize where bytes.count >= 8:
            let raw = ByteCoding.readUInt64LE(bytes, at: 0)
            let screen = PTPCameraPropertyDecoders.screenSize(raw)
            return replacing(resolution: screen.label, fps: screen.fps, rawScreenSize: raw)
        case .movieFileType where bytes.count >= 4:
            return replacing(
                fileType: PTPCameraPropertyDecoders.fileType(
                    ByteCoding.readUInt32LE(bytes, at: 0)))
        case .batteryLevel where bytes.count >= 1:
            // MTP BatteryLevel is a UINT8 percentage (0–100).
            return replacing(batteryPercent: Int(min(100, bytes[0])))
        case .acPower where bytes.count >= 1:
            // Nikon ACPower (0xD101): non-zero = on external/USB power → charging indicator.
            return replacing(onExternalPower: bytes[0] != 0)
        case .warningStatus where bytes.count >= 1:
            // Nikon WarningStatus (0xD102): UINT8 aggregate warning bitfield, kept raw for
            // `CameraWarningStatus` to interpret (bit positions verify-on-HW).
            return replacing(warningRaw: bytes[0])
        case .focalLength where bytes.count >= 4:
            return replacing(
                focalLength: PTPCameraPropertyDecoders.focalLengthMillimeters(
                    ByteCoding.readUInt32LE(bytes, at: 0)))
        case .lensFocalMin where bytes.count >= 4:
            return replacing(focalMinX100: ByteCoding.readUInt32LE(bytes, at: 0))
        case .lensFocalMax where bytes.count >= 4:
            return replacing(focalMaxX100: ByteCoding.readUInt32LE(bytes, at: 0))
        case .lensApertureMin where bytes.count >= 2:
            return replacing(apertureMinX100: ByteCoding.readUInt16LE(bytes, at: 0))
        case .movieFocusMode where bytes.count >= 1:
            return replacing(focusMode: PTPCameraPropertyDecoders.movieFocusMode(bytes[0]))
        case .movieFocusMeteringMode where bytes.count >= 2:
            return replacing(
                focusArea: PTPCameraPropertyDecoders.movieFocusArea(
                    ByteCoding.readUInt16LE(bytes, at: 0)))
        case .movieAFSubjectDetection where bytes.count >= 1:
            return replacing(focusSubject: PTPCameraPropertyDecoders.movieAFSubject(bytes[0]))
        case .movMicrophone where bytes.count >= 1:
            return replacing(
                microphoneSensitivity: PTPCameraPropertyDecoders.movMicrophone(bytes[0]))
        case .movRecordMicrophoneLevelValue where bytes.count >= 1:
            return replacing(
                microphoneLevel: PTPCameraPropertyDecoders.microphoneLevel(bytes[0]))
        case .movWindNoiseReduction where bytes.count >= 1:
            return replacing(
                windNoiseReduction: PTPCameraPropertyDecoders.onOffLabel(bytes[0]))
        case .movieAttenuator where bytes.count >= 1:
            return replacing(inputAttenuator: PTPCameraPropertyDecoders.onOffLabel(bytes[0]))
        case .audioInputSelection where bytes.count >= 1:
            return replacing(audioInput: PTPCameraPropertyDecoders.audioInputSelection(bytes[0]))
        case .movieAudioInputSensitivity where bytes.count >= 1:
            return replacing(
                audioSensitivity: PTPCameraPropertyDecoders.audioInputSensitivity(bytes[0]))
        case .movie32BitFloatAudioRecording where bytes.count >= 1:
            return replacing(audio32BitFloat: PTPCameraPropertyDecoders.onOffLabel(bytes[0]))
        case .gridDisplay where bytes.count >= 1:
            return replacing(gridDisplay: PTPCameraPropertyDecoders.onOffLabel(bytes[0]))
        case .movieVibrationReduction where bytes.count >= 1:
            return replacing(
                vibrationReduction: PTPCameraPropertyDecoders.movieVibrationReduction(bytes[0]))
        case .electronicVR where bytes.count >= 1:
            return replacing(electronicVR: PTPCameraPropertyDecoders.onOffLabel(bytes[0]))
        default:
            return self
        }
    }

    private func replacing(
        iso: UInt32? = nil,
        baseISO: String? = nil,
        exposureMode: String? = nil,
        shutterMode: ShutterDisplayMode? = nil,
        shutterLocked: Bool? = nil,
        shutterSpeed: String? = nil,
        shutterAngle: String? = nil,
        fNumber: String? = nil,
        wbMode: String? = nil,
        wbKelvin: UInt16? = nil,
        resolution: String? = nil,
        fps: Int? = nil,
        rawScreenSize: UInt64? = nil,
        fileType: String? = nil,
        batteryPercent: Int? = nil,
        onExternalPower: Bool? = nil,
        warningRaw: UInt8? = nil,
        focalLength: String? = nil,
        focalMinX100: UInt32? = nil,
        focalMaxX100: UInt32? = nil,
        apertureMinX100: UInt16? = nil,
        focusMode: String? = nil,
        focusArea: String? = nil,
        focusSubject: String? = nil,
        microphoneSensitivity: String? = nil,
        microphoneLevel: String? = nil,
        windNoiseReduction: String? = nil,
        inputAttenuator: String? = nil,
        audioInput: String? = nil,
        audioSensitivity: String? = nil,
        audio32BitFloat: String? = nil,
        vibrationReduction: String? = nil,
        electronicVR: String? = nil,
        gridDisplay: String? = nil
    ) -> PTPCameraPropertySnapshot {
        PTPCameraPropertySnapshot(
            iso: iso ?? self.iso,
            baseISO: baseISO ?? self.baseISO,
            exposureMode: exposureMode ?? self.exposureMode,
            shutterMode: shutterMode ?? self.shutterMode,
            shutterLocked: shutterLocked ?? self.shutterLocked,
            shutterSpeed: shutterSpeed ?? self.shutterSpeed,
            shutterAngle: shutterAngle ?? self.shutterAngle,
            fNumber: fNumber ?? self.fNumber,
            wbMode: wbMode ?? self.wbMode,
            wbKelvin: wbKelvin ?? self.wbKelvin,
            resolution: resolution ?? self.resolution,
            fps: fps ?? self.fps,
            rawScreenSize: rawScreenSize ?? self.rawScreenSize,
            fileType: fileType ?? self.fileType,
            batteryPercent: batteryPercent ?? self.batteryPercent,
            onExternalPower: onExternalPower ?? self.onExternalPower,
            warningRaw: warningRaw ?? self.warningRaw,
            focalLength: focalLength ?? self.focalLength,
            focalMinX100: focalMinX100 ?? self.focalMinX100,
            focalMaxX100: focalMaxX100 ?? self.focalMaxX100,
            apertureMinX100: apertureMinX100 ?? self.apertureMinX100,
            focusMode: focusMode ?? self.focusMode,
            focusArea: focusArea ?? self.focusArea,
            focusSubject: focusSubject ?? self.focusSubject,
            microphoneSensitivity: microphoneSensitivity ?? self.microphoneSensitivity,
            microphoneLevel: microphoneLevel ?? self.microphoneLevel,
            windNoiseReduction: windNoiseReduction ?? self.windNoiseReduction,
            inputAttenuator: inputAttenuator ?? self.inputAttenuator,
            audioInput: audioInput ?? self.audioInput,
            audioSensitivity: audioSensitivity ?? self.audioSensitivity,
            audio32BitFloat: audio32BitFloat ?? self.audio32BitFloat,
            vibrationReduction: vibrationReduction ?? self.vibrationReduction,
            electronicVR: electronicVR ?? self.electronicVR,
            gridDisplay: gridDisplay ?? self.gridDisplay
        )
    }
}

extension CameraDisplayState {
    /// Returns a monitor-display snapshot updated with the decoded camera properties available so far.
    public func applyingCameraProperties(
        _ properties: PTPCameraPropertySnapshot,
        mediaStatus: MediaStatus? = nil
    )
        -> CameraDisplayState
    {
        let updatedValues = values.map { value in
            CameraValue(
                label: value.label,
                value: cameraValue(
                    label: value.label, existing: value.value, properties: properties),
                isSettable: value.isSettable
            )
        }

        return CameraDisplayState(
            recordState: recordState,
            timecode: timecode,
            resolutionFrameRate: MonitorTextFormat.resolutionLabel(
                fromProperty: properties.resolution,
                frameRate: properties.fps ?? 0,
                fallback: resolutionFrameRate),
            codec: shortCodec(properties.fileType),
            media: media,
            liveFPS: liveFPS,
            cameraBatteryPercent: properties.batteryPercent ?? cameraBatteryPercent,
            phoneBatteryPercent: phoneBatteryPercent,
            cameraName: cameraName,
            lens: properties.lens ?? lens,
            // Real warning state (OK / CHECK / HOT) once 0xD102 is polled — never a fabricated
            // temperature number. Falls back to the existing label before the first poll.
            temperature: properties.warningRaw != nil
                ? properties.warningStatus.tileLabel
                : temperature,
            values: updatedValues,
            mediaStatus: mediaStatus ?? self.mediaStatus
        )
    }

    private func cameraValue(
        label: String,
        existing: String,
        properties: PTPCameraPropertySnapshot
    ) -> String {
        switch label {
        case "ISO":
            properties.iso.map(String.init) ?? existing
        case "SHUTTER":
            switch properties.shutterMode {
            case .speed: properties.shutterSpeed ?? properties.shutterAngle ?? existing
            case .angle, .none: properties.shutterAngle ?? properties.shutterSpeed ?? existing
            }
        case "IRIS":
            properties.fNumber ?? existing
        case "WB":
            // Kelvin only in colour-temperature WB mode. Named presets (Sunny, Cloudy, …) show
            // their name — a stale Kelvin reading must never win over a preset selection.
            if properties.wbMode == "Color temp", let kelvin = properties.wbKelvin {
                "\(kelvin)K"
            } else {
                properties.wbMode ?? properties.wbKelvin.map { "\($0)K" } ?? existing
            }
        case "FOCUS":
            properties.focusMode ?? existing
        default:
            existing
        }
    }

    /// Returns a shortened codec label, preserving the current codec when the camera hasn't
    /// reported one yet.
    private func shortCodec(_ fileType: String?) -> String {
        guard let fileType else { return codec }
        return MonitorTextFormat.codecShortLabel(fileType)
    }
}

/// Movie WB fine-tune ("tint") policy: which per-mode tune property serves a WB mode label, the
/// grid geometry, the wire encoding, and the operator-facing readout.
///
/// Axes follow Nikon's fine-tune grid: **x = amber (+) ↔ blue (−)**, **y = green (+) ↔
/// magenta (−)**. The camera exposes a **13×13 grid** of positions (cell index −6…+6 per axis);
/// per Nikon's fine-tuning convention one A–B cell is **0.5** units (≈5 mired) and one G–M cell
/// is **0.25** units — the same steps the body's own fine-tune screen uses.
///
/// Wire encoding (`MovieWbTune*`, UINT16): a grid coordinate `row·100 + column·2` with rows
/// running top (G) → bottom (M) and columns left (B) → right (A); neutral centre = **612**.
/// The advertised 0–1224 range is sparse — only the 169 grid points are valid values.
/// [ZR-only — value layout described in our own words from Nikon's fine-tuning coordinate
/// documentation; not present in libgphoto2.]
public enum WhiteBalanceTint {
    /// Grid cell index range on each axis (13 positions per side).
    public static let cellRange: ClosedRange<Int> = -6...6
    /// Operator units per grid cell on the amber↔blue axis.
    public static let amberBlueUnitsPerCell = 0.5
    /// Operator units per grid cell on the green↔magenta axis.
    public static let greenMagentaUnitsPerCell = 0.25

    /// The tune property that fine-tunes the given WB mode label (as decoded by
    /// ``PTPCameraPropertyDecoders/whiteBalanceMode(_:)``). Nil for modes with no mapped tune
    /// property — "Preset" slots (per-slot props not wired) and "Flash" (no movie tune code).
    public static func tuneProperty(forWBModeLabel label: String) -> PTPPropertyCode? {
        switch label {
        case "Auto": .movieWbTuneAuto
        case "Natural auto": .movieWbTuneNatural
        case "Sunny": .movieWbTuneSunny
        case "Cloudy": .movieWbTuneCloudy
        case "Shade": .movieWbTuneShade
        case "Incandescent": .movieWbTuneIncandescent
        case "Fluorescent": .movieWbTuneFluorescent
        case "Color temp": .movieWbTuneColorTemp
        default: nil
        }
    }

    /// Encodes a grid position to the wire value (clamping both cells to ``cellRange``).
    public static func propertyValue(amberBlueCell: Int, greenMagentaCell: Int) -> UInt16 {
        let column = 6 + clamp(amberBlueCell)
        let row = 6 - clamp(greenMagentaCell)
        return UInt16(row * 100 + column * 2)
    }

    /// Decodes a wire value back to grid cells; nil for values off the 169-point grid.
    public static func cells(fromPropertyValue value: UInt16) -> (
        amberBlue: Int, greenMagenta: Int
    )? {
        let row = Int(value) / 100
        let columnValue = Int(value) % 100
        guard (0...12).contains(row), columnValue % 2 == 0 else { return nil }
        let column = columnValue / 2
        guard (0...12).contains(column) else { return nil }
        return (amberBlue: column - 6, greenMagenta: 6 - row)
    }

    /// Builds the tune write for a WB mode. Nil when the mode has no mapped tune property.
    public static func write(
        wbModeLabel: String,
        amberBlueCell: Int,
        greenMagentaCell: Int
    ) -> PTPCameraPropertyWrite? {
        guard let property = tuneProperty(forWBModeLabel: wbModeLabel) else { return nil }
        let value = propertyValue(
            amberBlueCell: amberBlueCell, greenMagentaCell: greenMagentaCell)
        return PTPCameraPropertyWrite(property: property, data: Data(ByteCoding.uint16LE(value)))
    }

    /// Operator-facing readout in the body's own units: "A1.5 · G0.75", or "Neutral".
    public static func label(amberBlueCell: Int, greenMagentaCell: Int) -> String {
        let ab = clamp(amberBlueCell)
        let gm = clamp(greenMagentaCell)
        var parts: [String] = []
        if ab != 0 {
            parts.append(
                (ab > 0 ? "A" : "B") + trimmed(Double(abs(ab)) * amberBlueUnitsPerCell))
        }
        if gm != 0 {
            parts.append(
                (gm > 0 ? "G" : "M") + trimmed(Double(abs(gm)) * greenMagentaUnitsPerCell))
        }
        return parts.isEmpty ? "Neutral" : parts.joined(separator: " · ")
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, cellRange.lowerBound), cellRange.upperBound)
    }
}
