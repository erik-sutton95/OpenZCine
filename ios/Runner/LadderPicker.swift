import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineNikon
import SwiftUI

/// Writes a ladder tab reports. The value key is the tab index; circuit switches are separate
/// so selecting a tab can change the circuit without pretending the drum value is that write.
enum LadderControl: Hashable, Sendable {
    case value(Int)
    case baseISO
    case autoISO
    case shutterMode
    case tint
}

extension CameraPicker {
    /// Pickers that draw on `LadderSheet`. Quality stays on its own panel: two wheels compose one
    /// label, and the NEF chips write a different control. Each audio command tile is one tab.
    var usesLadderSheet: Bool {
        switch self {
        case .iso, .shutter, .iris, .whiteBalance, .focus, .resolution, .codec,
            .stillMode, .stillDrive, .stillMeter, .stillSize, .stillPicture, .audio:
            true
        default:
            false
        }
    }
}

/// Host for one capture picker on `LadderSheet`. Seeds descriptor lists on appear, follows a
/// camera circuit change by rebuilding, and routes each write through the existing model helpers.
struct LadderPickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    let picker: CameraPicker
    var chromeless = false

    @State private var lensApertures: [String] = []
    @State private var screenModes: [String] = []
    @State private var codecRows: [PTPCameraCodecFamily] = []
    @State private var generation = 0
    @State private var adoptedCircuit: Int?
    /// Audio mode for this opening. `seed` clears `pickerInitialMode`, and the one tab has to
    /// survive that clear. The first body reads the seed directly so the sheet never starts as five.
    @State private var audioTab: Int?

    var body: some View {
        LadderSheet(
            presentation: presentation,
            enabled: true,
            onWrite: { perform($0) },
            onClose: { model.dismissActivePanel() },
            control: model.shell.control,
            fromTop: picker.isTopBar,
            chromeless: chromeless,
            onHold: picker == .shutter ? { holdShutter() } : nil,
            tintLabel: { tint in
                WhiteBalanceTint.label(
                    amberBlueCell: tint.amberBlue ?? 0, greenMagentaCell: tint.greenMagenta)
            },
            tintHelp: picker == .whiteBalance
                ? "Steps of 0.5 (A-B) and 0.25 (G-M), like the camera body. Double-tap the pad to reset."
                : nil
        ) { tab in
            if picker == .focus {
                FocusDialFooter()
            }
            if picker == .stillDrive, case .value(let mode) = tab.key, mode == 1 || mode == 2 {
                TimerShotsFooter(mode: mode)
            }
        }
        .environment(\.ladderOperatorHaptics, model.preferences.hapticsEnabled)
        .id(generation)
        .onAppear(perform: seed)
        .onChange(of: model.isoPickerModeIndex) { _, mode in
            guard picker == .iso, model.showsDualBaseISOPicker else { return }
            adopt(mode)
        }
        .onChange(of: model.shutterPickerModeIndex) { _, mode in
            guard picker == .shutter else { return }
            adopt(mode)
        }
        .onChange(of: model.isISOValueCameraOwned) { _, owned in
            guard picker == .iso, model.showsAutoISOPicker, !owned, !model.isISORecordingLocked
            else { return }
            generation += 1
        }
    }

    private var presentation: LadderSheetPresentation<LadderControl> {
        let entries = modeEntries
        let singleAudio = picker == .audio && entries.count == 1
        return LadderSheetPresentation(
            title: singleAudio ? entries[0].mode.title : picker.valueLabel,
            subtitle: singleAudio
                ? model.pickerModeValue(picker, mode: entries[0].index)
                : model.pickerSubtitle(for: picker),
            tabs: entries.map { tab($0.mode, index: $0.index) },
            initialTab: singleAudio ? 0 : initialTab,
            lock: sheetLock,
            lockBanner: banner)
    }

    private var modes: [PickerMode] {
        let listed = model.pickerModes(for: picker)
        if !listed.isEmpty { return listed }
        return [PickerMode(title: picker.valueLabel, options: picker.options)]
    }

    /// One command tile is one tab. The key stays the real audio mode, not the array offset.
    private var modeEntries: [(index: Int, mode: PickerMode)] {
        if picker == .audio, let only = heldAudioTab, modes.indices.contains(only) {
            return [(only, modes[only])]
        }
        return modes.enumerated().map { ($0.offset, $0.element) }
    }

    private var heldAudioTab: Int? {
        guard picker == .audio else { return nil }
        return audioTab ?? model.pickerInitialMode
    }

    private var initialTab: Int {
        let raw: Int
        switch picker {
        case .iso:
            raw = model.isoPickerModeIndex
        case .shutter:
            raw = model.shutterPickerModeIndex
        case .whiteBalance:
            let mode = model.cameraPropertySnapshot.wbMode
            raw = (mode == nil || mode == "Color temp") ? 0 : 1
        default:
            if let seeded = model.pickerInitialMode {
                raw = seeded
            } else {
                let live = model.cameraValue(for: picker)
                raw = modes.firstIndex { $0.options.contains(live) } ?? 0
            }
        }
        return min(max(raw, 0), max(modes.count - 1, 0))
    }

    /// Recording and a camera shutter lock freeze the whole sheet. Auto ISO locks each drum
    /// instead, so the operator can still leave Auto.
    private var sheetLock: CaptureLock? {
        if picker == .shutter, model.lockedControls.contains(.shutter) { return .cameraControl }
        if picker == .iso, model.isISORecordingLocked { return .recording }
        return nil
    }

    private var banner: String? {
        switch sheetLock {
        case .cameraControl:
            return "Shutter locked on camera. Hold anywhere to unlock."
        case .recording:
            return "ISO is locked while recording in R3D NE"
        default:
            break
        }
        guard picker == .iso, model.showsAutoISOPicker, model.isISOValueCameraOwned else {
            return nil
        }
        if model.allowsManualISO {
            return
                "Auto ISO is on. The camera sets sensitivity. Switch to Auto Off to choose a value."
        }
        return "Manual ISO needs exposure mode M. The camera is setting sensitivity."
    }

    private func tab(_ mode: PickerMode, index: Int) -> LadderTab<LadderControl> {
        let options = modeOptions(mode, index: index)
        let lock = tabLock(mode)
        let (activate, apply) = activation(mode, index: index)
        let current = model.pickerModeValue(picker, mode: index)
        let kelvin = picker == .whiteBalance && mode.title == "Kelvin"
        let core = coreField(mode, options: options, lock: lock)
        let grown: (@Sendable (String) -> [String])? = kelvin ? Self.kelvinValues : nil
        let steps = stepProvider(mode)
        return LadderTab(
            label: mode.title,
            key: .value(index),
            ladder: CaptureLadder(
                current: current.isEmpty ? nil : current,
                values: core.options,
                marked: marked(mode, index: index),
                lock: lock),
            detail: mode.detail,
            activate: activate,
            applyOnActivate: apply,
            disabled: model.pickerModeDisabled(picker, mode: index),
            field: core.field,
            tint: tint(mode),
            values: grown,
            steps: steps)
    }

    private func tabLock(_ mode: PickerMode) -> CaptureLock? {
        if picker == .whiteBalance, mode.title == "Tint", !model.whiteBalanceTintAvailable {
            return .auto
        }
        if picker == .iso, model.showsAutoISOPicker, model.isISOValueCameraOwned,
            !model.isISORecordingLocked
        {
            return .auto
        }
        return nil
    }

    private func activation(
        _ mode: PickerMode, index: Int
    ) -> (LadderWrite<LadderControl>?, Bool) {
        switch picker {
        case .iso where model.showsDualBaseISOPicker:
            return (LadderWrite(key: .baseISO, value: index == 1 ? "High" : "Low"), true)
        case .iso where model.showsAutoISOPicker:
            let autoOn = index == 0
            return (LadderWrite(key: .autoISO, value: autoOn ? "On" : "Off"), !autoOn)
        case .shutter:
            return (LadderWrite(key: .shutterMode, value: index == 1 ? "Speed" : "Angle"), false)
        case .focus, .stillMode, .stillDrive, .stillSize, .audio:
            return (nil, false)
        case .whiteBalance where mode.title == "Tint":
            return (nil, false)
        default:
            return (nil, true)
        }
    }

    private func modeOptions(_ mode: PickerMode, index: Int) -> [String] {
        switch picker {
        case .iso:
            let live =
                model.showsAutoISOPicker && model.isISOValueCameraOwned
                ? liveISO : nil
            return ISOPickerPolicy.options(
                codec: model.cameraState.codec, modeIndex: index, includingLiveISO: live)
        case .iris:
            return lensApertures.isEmpty ? fallback(mode) : lensApertures
        case .resolution:
            return screenModes.isEmpty ? fallback(mode) : screenModes
        case .codec:
            let labels = codecRows.map(\.label)
            return labels.isEmpty ? fallback(mode) : labels
        case .whiteBalance where mode.title == "Kelvin":
            return WhiteBalanceKelvinPolicy.kelvinOptions
        case .whiteBalance where mode.title == "Tint":
            return []
        case .stillDrive where index == 0:
            if let camera = model.cameraControlOptions[.stillCaptureMode], !camera.isEmpty {
                return StillDriveMode.driveDrumOptions(advertised: camera)
            }
            return fallback(mode)
        default:
            if let property = advertisedProperty(index: index),
                let camera = model.cameraControlOptions[property], !camera.isEmpty
            {
                if property == .movieWhiteBalance {
                    return PTPCameraPropertyDecoders.whiteBalanceOptions(
                        advertised: camera, codec: model.cameraState.codec)
                }
                return camera
            }
            let resolved = fallback(mode)
            if picker == .whiteBalance, !model.isPhotographyMode, mode.title == "Preset" {
                return PTPCameraPropertyDecoders.whiteBalanceOptions(
                    advertised: resolved, codec: model.cameraState.codec)
            }
            return resolved
        }
    }

    private func fallback(_ mode: PickerMode) -> [String] {
        mode.options.isEmpty ? picker.options : mode.options
    }

    private func advertisedProperty(index: Int) -> PTPPropertyCode? {
        switch picker {
        case .focus:
            switch index {
            case 0: return .movieFocusMode
            case 1: return .movieFocusMeteringMode
            case 2: return .movieAFSubjectDetection
            default: return nil
            }
        case .shutter:
            return index == 0 ? .movieShutterAngle : .movieShutterSpeed
        case .whiteBalance:
            guard index == 1 else { return nil }
            return model.isPhotographyMode ? .whiteBalance : .movieWhiteBalance
        case .stillMode:
            return index == 0 ? .exposureProgramMode : .userMode
        case .stillSize:
            return index == 1 ? .imageSize : nil
        case .stillMeter:
            return .exposureMeteringMode
        case .stillPicture:
            return .activePicCtrlItem
        case .audio:
            switch index {
            case 1: return .audioInputSelection
            case 2: return .movWindNoiseReduction
            case 3: return .movieAttenuator
            case 4: return .movie32BitFloatAudioRecording
            default: return nil
            }
        default:
            return nil
        }
    }

    private func marked(_ mode: PickerMode, index: Int) -> Set<String> {
        if picker == .iso {
            return ISOPickerPolicy.markedValues(codec: model.cameraState.codec, modeIndex: index)
        }
        return mode.base.isEmpty ? [] : [mode.base]
    }

    /// Core drum when the setting is typed. The sheet filters drum choices by label, and
    /// `MonitorCaptureField` has no public copy, so the offered labels are the choice labels.
    private func coreField(
        _ mode: PickerMode, options: [String], lock: CaptureLock?
    ) -> (field: MonitorCaptureField?, options: [String]) {
        if lock != nil { return (nil, options) }
        if picker == .whiteBalance, mode.title == "Kelvin" || mode.title == "Tint" {
            return (nil, options)
        }
        guard let setting = picker.nikonControlSetting,
            !model.isDemoSession, model.videoSource != .relay,
            let field = model.shell.control.captureField(setting.key)
        else { return (nil, options) }
        let offered = Set(options.compactMap { NikonCameraSession.setting(setting, label: $0) })
        let labels = field.choices.filter { offered.contains($0.value) }.map(\.label)
        return (field, labels.isEmpty ? options : labels)
    }

    private func tint(_ mode: PickerMode) -> CaptureTint? {
        guard picker == .whiteBalance, mode.title == "Tint" else { return nil }
        return CaptureTint(
            greenMagenta: model.whiteBalanceTintGM,
            amberBlue: model.whiteBalanceTintAB,
            range: WhiteBalanceTint.cellRange)
    }

    private func stepProvider(
        _ mode: PickerMode
    ) -> (@Sendable (String) -> (LadderStep, LadderStep)?)? {
        if picker == .codec {
            return Self.codecStepProvider(rows: codecRows, depth: model.activeCodecMode?.bitDepth)
        }
        if picker == .whiteBalance, mode.title == "Kelvin" {
            return Self.kelvinSteps
        }
        return nil
    }

    private var liveISO: String? {
        guard let iso = model.cameraPropertySnapshot.iso, iso > 0 else { return nil }
        return String(iso)
    }

    private func seed() {
        if picker == .iris { lensApertures = model.irisApertures }
        if picker == .resolution { screenModes = model.resolutionOptions }
        if picker == .codec { codecRows = model.codecFamilies }
        if picker == .whiteBalance { model.refreshWhiteBalanceTintFromCamera() }
        if adoptedCircuit == nil { adoptedCircuit = circuitIndex }
        if picker == .audio, audioTab == nil {
            audioTab = model.pickerInitialMode
        }
        // Keep the audio seed until it is stored. Clearing it first would rebuild as five tabs.
        let audioSeedPending = picker == .audio && audioTab == nil
        if picker != .iso, picker != .shutter, picker != .whiteBalance, !audioSeedPending {
            model.pickerInitialMode = nil
        }
    }

    private var circuitIndex: Int? {
        switch picker {
        case .iso where model.showsDualBaseISOPicker:
            return model.isoPickerModeIndex
        case .shutter:
            return model.shutterPickerModeIndex
        default:
            return nil
        }
    }

    private func adopt(_ mode: Int) {
        guard adoptedCircuit != mode else { return }
        adoptedCircuit = mode
        generation += 1
    }

    private func perform(_ write: LadderWrite<LadderControl>) {
        switch write.key {
        case .baseISO:
            adoptedCircuit = write.value == "High" ? 1 : 0
            model.switchBaseISO(highBase: write.value == "High")
        case .autoISO:
            model.switchAutoISO(enabled: write.value == "On")
        case .shutterMode:
            adoptedCircuit = write.value == "Speed" ? 1 : 0
            model.switchShutterMode(speedMode: write.value == "Speed")
        case .tint:
            guard let cells = Self.cells(fromTintLabel: write.value) else { return }
            model.whiteBalanceTintAB = cells.amberBlue
            model.whiteBalanceTintGM = cells.greenMagenta
            model.commitWhiteBalanceTint()
        case .value(let mode):
            model.applyPicker(picker, mode: mode, value: write.value)
        }
    }

    private func holdShutter() {
        let locked = model.lockedControls.contains(.shutter)
        if model.preferences.hapticsEnabled {
            if locked {
                OperatorSettingsHaptics.unlockConfirm()
            } else {
                OperatorSettingsHaptics.lockConfirm()
            }
        }
        if locked {
            model.unlockShutterControlOnCamera()
        } else {
            model.lockShutterControlOnCamera()
        }
    }

    private nonisolated static func kelvinValues(_ landed: String) -> [String] {
        WhiteBalanceKelvinPolicy.options(including: landed)
    }

    private nonisolated static func codecStepProvider(
        rows: [PTPCameraCodecFamily], depth: Int?
    ) -> @Sendable (String) -> (LadderStep, LadderStep)? {
        { selected in codecSteps(rows: rows, selected: selected, activeDepth: depth) }
    }

    private nonisolated static func kelvinSteps(_ selected: String) -> (LadderStep, LadderStep)? {
        (
            kelvinStep(
                selected, delta: -WhiteBalanceKelvinPolicy.fineStepKelvin,
                label: "\u{2212}10", description: "Decrease Kelvin by 10"),
            kelvinStep(
                selected, delta: WhiteBalanceKelvinPolicy.fineStepKelvin,
                label: "+10", description: "Increase Kelvin by 10")
        )
    }

    private nonisolated static func kelvinStep(
        _ selected: String, delta: Int, label: String, description: String
    ) -> LadderStep {
        let value =
            WhiteBalanceKelvinPolicy.canFineAdjust(from: selected, delta: delta)
            ? WhiteBalanceKelvinPolicy.fineAdjust(from: selected, delta: delta) : nil
        return LadderStep(
            label: label, value: value, description: description, lands: true)
    }

    private nonisolated static func codecSteps(
        rows: [PTPCameraCodecFamily], selected: String, activeDepth: Int?
    ) -> (LadderStep, LadderStep)? {
        guard let row = rows.first(where: { $0.label == selected }),
            row.offersBitDepthChoice, let low = row.depths.first, let high = row.depths.last
        else { return nil }
        return (
            LadderStep(
                label: low.bitDepthLabel, value: low.label,
                description: "Record \(row.label) at \(low.bitDepth) bit",
                selected: activeDepth == low.bitDepth, lands: false),
            LadderStep(
                label: high.bitDepthLabel, value: high.label,
                description: "Record \(row.label) at \(high.bitDepth) bit",
                selected: activeDepth == high.bitDepth, lands: false)
        )
    }

    /// The pad reports the operator label. Map it back onto grid cells for the existing tint write.
    nonisolated static func cells(fromTintLabel label: String) -> (
        amberBlue: Int, greenMagenta: Int
    )? {
        if label == "Neutral" { return (0, 0) }
        var amberBlue = 0
        var greenMagenta = 0
        var saw = false
        for part in label.split(separator: "\u{00B7}") {
            let token = part.trimmingCharacters(in: .whitespaces)
            guard let prefix = token.first else { return nil }
            guard let units = Double(token.dropFirst()) else { return nil }
            switch prefix {
            case "A":
                amberBlue = cellCount(units, perCell: WhiteBalanceTint.amberBlueUnitsPerCell)
            case "B":
                amberBlue = -cellCount(units, perCell: WhiteBalanceTint.amberBlueUnitsPerCell)
            case "G":
                greenMagenta = cellCount(units, perCell: WhiteBalanceTint.greenMagentaUnitsPerCell)
            case "M":
                greenMagenta = -cellCount(
                    units, perCell: WhiteBalanceTint.greenMagentaUnitsPerCell)
            default:
                return nil
            }
            saw = true
        }
        return saw ? (amberBlue, greenMagenta) : nil
    }

    private nonisolated static func cellCount(_ units: Double, perCell: Double) -> Int {
        Int((units / perCell).rounded())
    }
}

/// Shot count shared by the drive picker's two timer tabs.
private struct TimerShotsFooter: View {
    @Environment(NativeAppModel.self) private var model
    let mode: Int

    var body: some View {
        let disabled = model.pickerModeDisabled(.stillDrive, mode: mode)
        HStack(spacing: 12) {
            Text("Shots")
                .font(.system(size: 12, weight: .semibold))
                .kerning(1)
                .textCase(.uppercase)
                .foregroundStyle(LiveDesign.muted)
            Spacer(minLength: 8)
            step("minus", enabled: model.photoTimerShotCount > 1) {
                model.adjustPhotoTimerShots(by: -1)
            }
            Text("\(model.photoTimerShotCount)")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .frame(minWidth: 28)
                .contentTransition(.numericText())
            step("plus", enabled: model.photoTimerShotCount < 9) {
                model.adjustPhotoTimerShots(by: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LiveDesign.background.opacity(0.28),
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        }
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }

    private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? LiveDesign.accent : LiveDesign.faint)
                .frame(width: 32, height: 32)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.monitorTapTarget)
        .disabled(!enabled)
    }
}

/// The focus picker's scrub toggle, kept as the sheet footer.
private struct FocusDialFooter: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.mfDriveScrubEnabled) {
            Text("Focus dial")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
        }
        .toggleStyle(SwitchToggleStyle(tint: LiveDesign.accent))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LiveDesign.background.opacity(0.28),
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        }
    }
}
