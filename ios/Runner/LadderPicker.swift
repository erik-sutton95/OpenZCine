import MonitorUI
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineNikon
import SwiftUI

/// Thin Z adapter: reads the session into `NikonCapturePopupState`, draws the shared ladder
/// sheet it presents, and routes each write through the model.
struct LadderPickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    let picker: CameraPicker

    @State private var lensApertures: [String] = []
    @State private var codecRows: [PTPCameraCodecFamily] = []
    @State private var generation = 0
    @State private var adoptedCircuit: Int?
    /// Audio mode for this opening. `seed` clears `pickerInitialMode`, and the one tab has to
    /// survive that clear. The first body reads the seed directly so the sheet never starts as five.
    @State private var audioTab: Int?

    var body: some View {
        if picker == .resolution {
            NikonFormatPicker(title: picker.valueLabel, subtitle: model.pickerSubtitle(for: picker))
                .onAppear(perform: seed)
        } else {
            ladder
        }
    }

    private var ladder: some View {
        LadderSheet(
            presentation: state.presentation, enabled: true, onWrite: { perform($0) },
            control: model.shell.control, onHold: picker == .shutter ? { holdShutter() } : nil,
            tintLabel: {
                WhiteBalanceTint.label(
                    amberBlueCell: $0.amberBlue ?? 0, greenMagentaCell: $0.greenMagenta)
            },
            tintHelp: picker == .whiteBalance
                ? "Steps of 0.5 (A-B) and 0.25 (G-M), like the camera body. Double-tap the pad to reset."
                : nil
        ) { tab in
            NikonLadderFooter(picker: picker, tab: tab.key)
        }
        .environment(\.ladderOperatorHaptics, model.preferences.hapticsEnabled)
        .id(generation)
        .onAppear(perform: seed)
        .onChange(of: model.isoPickerModeIndex) { _, mode in
            if picker == .iso, model.showsDualBaseISOPicker { adopt(mode) }
        }
        .onChange(of: model.shutterPickerModeIndex) { _, mode in
            if picker == .shutter { adopt(mode) }
        }
        .onChange(of: model.stillISOPickerModeIndex) { _, mode in
            if picker == .stillISO { adopt(mode) }
        }
        .onChange(of: model.isISOValueCameraOwned) { _, owned in
            if picker == .iso, model.showsAutoISOPicker, !owned, !model.isISORecordingLocked {
                generation += 1
            }
        }
    }

    /// The session as values. One command tile is one audio tab, keyed by its real mode index.
    private var state: NikonCapturePopupState {
        let listed = model.pickerModes(for: picker)
        let modes =
            listed.isEmpty
            ? [PickerMode(title: picker.valueLabel, options: picker.options)] : listed
        var entries = Array(modes.enumerated())
        let held = picker == .audio ? audioTab ?? model.pickerInitialMode : nil
        if let held, modes.indices.contains(held) {
            entries = [(offset: held, element: modes[held])]
        }
        let single = picker == .audio && entries.count == 1
        var state = NikonCapturePopupState(
            kind: picker.capturePopupKind,
            title: single
                ? entries[0].element.title
                : picker.sharedCaptureSheet?.headerLabel
                    ?? (picker == .codec ? model.codecColorChoices.title : picker.valueLabel),
            subtitle: single
                ? model.pickerModeValue(picker, mode: entries[0].offset)
                : picker.sharedCaptureSheet?.subtitle ?? model.pickerSubtitle(for: picker),
            modes: entries.map { index, mode in
                NikonLadderMode(
                    index: index, title: mode.title, detail: mode.detail,
                    options: mode.options.isEmpty ? picker.options : mode.options, base: mode.base,
                    current: model.pickerModeValue(picker, mode: index),
                    disabled: model.pickerModeDisabled(picker, mode: index),
                    advertised: advertisedProperty(index: index).flatMap {
                        model.cameraControlOptions[$0]
                    })
            })
        state.cameraValue = model.cameraValue(for: picker)
        state.seededTab = single ? 0 : model.pickerInitialMode
        state.circuitIndex =
            switch picker {
            case .iso: model.isoPickerModeIndex
            case .shutter: model.shutterPickerModeIndex
            case .stillISO: model.stillISOPickerModeIndex
            default: nil
            }
        state.codec = model.cameraState.codec
        state.photography = model.isPhotographyMode
        state.whiteBalanceMode = model.cameraPropertySnapshot.wbMode
        state.liveISO = model.cameraPropertySnapshot.iso.flatMap { $0 > 0 ? Int($0) : nil }
        state.dualBaseISO = model.showsDualBaseISOPicker
        state.autoISO = model.showsAutoISOPicker
        state.isoCameraOwned = model.isISOValueCameraOwned
        state.isoRecordingLocked = model.isISORecordingLocked
        state.allowsManualISO = model.allowsManualISO
        state.stillAllowsManualISO = model.stillAllowsManualISO
        state.shutterLockedOnCamera = model.lockedControls.contains(.shutter)
        state.tintCells = (model.whiteBalanceTintAB, model.whiteBalanceTintGM)
        state.tintAvailable = model.whiteBalanceTintAvailable
        state.lensApertures = lensApertures
        state.codecRows = codecRows
        state.activeCodecDepth = model.activeCodecMode?.bitDepth
        if !model.isDemoSession, model.videoSource != .relay {
            state.typed = picker.nikonControlSetting
        }
        return state
    }

    /// The camera enum behind a tab; the photography white balance popup reads the stills
    /// presets, and the drive tab reads the release modes.
    private func advertisedProperty(index: Int) -> PTPPropertyCode? {
        if picker == .stillDrive, index == 0 { return .stillCaptureMode }
        let property = picker.optionProperty(forMode: index)
        if property == .movieWhiteBalance, model.isPhotographyMode { return .whiteBalance }
        return property
    }

    private func seed() {
        if picker == .iris || picker == .stillIris { lensApertures = model.irisApertures }
        if picker == .codec { codecRows = model.codecFamilies }
        if picker == .whiteBalance { model.refreshWhiteBalanceTintFromCamera() }
        if adoptedCircuit == nil, picker != .iso || model.showsDualBaseISOPicker {
            adoptedCircuit = state.circuitIndex
        }
        if picker == .audio, audioTab == nil { audioTab = model.pickerInitialMode }
        // Keep the audio seed until it is stored. Clearing it first would rebuild as five tabs.
        let audioSeedPending = picker == .audio && audioTab == nil
        if ![CameraPicker.iso, .stillISO, .shutter, .whiteBalance].contains(picker),
            !audioSeedPending
        {
            model.pickerInitialMode = nil
        }
    }

    private func adopt(_ mode: Int) {
        guard adoptedCircuit != mode else { return }
        adoptedCircuit = mode
        generation += 1
    }

    private func perform(_ write: LadderWrite<NikonLadderControl>) {
        let on = write.value == "On"
        switch write.key {
        case .baseISO:
            adoptedCircuit = write.value == "High" ? 1 : 0
            model.switchBaseISO(highBase: write.value == "High")
        case .autoISO:
            model.switchAutoISO(enabled: on)
        case .stillAutoISO:
            adoptedCircuit = on ? 0 : 1
            model.switchStillAutoISO(enabled: on)
        case .shutterMode:
            adoptedCircuit = write.value == "Speed" ? 1 : 0
            model.switchShutterMode(speedMode: write.value == "Speed")
        case .tint:
            guard let cells = WhiteBalanceTint.cells(label: write.value) else { return }
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
}
