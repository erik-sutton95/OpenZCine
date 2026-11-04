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
        LadderSheet(
            presentation: state.presentation, enabled: true, onWrite: { perform($0) },
            control: model.shell.control, onHold: picker == .shutter ? { holdShutter() } : nil,
            tintLabel: {
                WhiteBalanceTint.label(
                    amberBlueCell: $0.amberBlue ?? 0, greenMagentaCell: $0.greenMagenta)
            },
            tintHelp: picker == .whiteBalance
                ? "Steps of 0.5 (A-B) and 0.25 (G-M), like the camera body. Double-tap the pad to reset."
                : nil,
            formats: picker == .resolution
                ? nikonLadderFormats(
                    options: state.presentation.tabs.first?.ladder.values ?? [],
                    recordingFormats: model.recordingFormatPresentations) : nil
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

    /// The session as values, the same the readout's quick drum reads.
    private var state: NikonCapturePopupState {
        model.capturePopupState(
            for: picker, initialMode: model.pickerInitialMode, audioTab: audioTab,
            lensApertures: lensApertures, codecRows: codecRows)
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

    private func holdShutter() { model.toggleShutterLockOnCamera() }
}

extension NativeAppModel {
    /// The session as the picker's popup values. One command tile is one audio tab, keyed by its
    /// real mode index. The drawer passes its own opening state; a readout's quick drum passes
    /// none and reads the tab the camera is on.
    func capturePopupState(
        for picker: CameraPicker, initialMode: Int?, audioTab: Int? = nil,
        lensApertures: [String], codecRows: [PTPCameraCodecFamily]
    ) -> NikonCapturePopupState {
        let listed = pickerModes(for: picker)
        let defaultOptions =
            picker == .resolution
            ? recordingFormatPresentations.map(\.token) : picker.options
        let modes =
            listed.isEmpty
            ? [PickerMode(title: picker.valueLabel, options: defaultOptions)] : listed
        var entries = Array(modes.enumerated())
        let held = picker == .audio ? audioTab ?? initialMode : nil
        if let held, modes.indices.contains(held) {
            entries = [(offset: held, element: modes[held])]
        }
        let single = picker == .audio && entries.count == 1
        var state = NikonCapturePopupState(
            kind: picker.capturePopupKind,
            title: single
                ? entries[0].element.title
                : picker.sharedCaptureSheet?.headerLabel
                    ?? (picker == .codec ? codecColorChoices.title : picker.valueLabel),
            subtitle: single
                ? pickerModeValue(picker, mode: entries[0].offset)
                : picker.sharedCaptureSheet?.subtitle ?? pickerSubtitle(for: picker),
            modes: entries.map { index, mode in
                NikonLadderMode(
                    index: index, title: mode.title, detail: mode.detail,
                    options: mode.options.isEmpty ? defaultOptions : mode.options, base: mode.base,
                    current: pickerModeValue(picker, mode: index),
                    disabled: pickerModeDisabled(picker, mode: index),
                    advertised: advertisedProperty(picker, index: index).flatMap {
                        cameraControlOptions[$0]
                    })
            })
        state.cameraValue = cameraValue(for: picker)
        state.seededTab = single ? 0 : initialMode
        state.circuitIndex =
            switch picker {
            case .iso: isoPickerModeIndex
            case .shutter: shutterPickerModeIndex
            case .stillISO: stillISOPickerModeIndex
            default: nil
            }
        state.codec = cameraState.codec
        state.photography = isPhotographyMode
        state.whiteBalanceMode = cameraPropertySnapshot.wbMode
        state.liveISO = cameraPropertySnapshot.iso.flatMap { $0 > 0 ? Int($0) : nil }
        state.dualBaseISO = showsDualBaseISOPicker
        state.autoISO = showsAutoISOPicker
        state.isoCameraOwned = isISOValueCameraOwned
        state.isoRecordingLocked = isISORecordingLocked
        state.allowsManualISO = allowsManualISO
        state.stillAllowsManualISO = stillAllowsManualISO
        state.shutterLockedOnCamera = lockedControls.contains(.shutter)
        state.tintCells = (whiteBalanceTintAB, whiteBalanceTintGM)
        state.tintAvailable = whiteBalanceTintAvailable
        state.lensApertures = lensApertures
        state.codecRows = codecRows
        state.activeCodecDepth = activeCodecMode?.bitDepth
        if !isDemoSession, videoSource != .relay {
            state.typed = picker.nikonControlSetting
        }
        return state
    }

    /// The camera enum behind a tab; the photography white balance popup reads the stills
    /// presets, and the drive tab reads the release modes.
    func advertisedProperty(_ picker: CameraPicker, index: Int) -> PTPPropertyCode? {
        if picker == .stillDrive, index == 0 { return .stillCaptureMode }
        let property = picker.optionProperty(forMode: index)
        if property == .movieWhiteBalance, isPhotographyMode { return .whiteBalance }
        return property
    }
}
