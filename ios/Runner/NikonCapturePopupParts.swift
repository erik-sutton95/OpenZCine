import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineNikon
import SwiftUI

extension CameraPicker {
    /// Pickers that draw on the shared `LadderSheet`, movie and photo alike. Quality stays on its
    /// own panel (two wheels compose one label, and the NEF chips write a different control), and
    /// stabilization is two independent switches. Each audio command tile is one tab.
    var usesLadderSheet: Bool { self != .stillQuality && self != .stabilization }

    /// The shared popup whose header (title and subtitle) every app shows for this picker, so
    /// white balance and shutter read exactly as on Pocket and Insta.
    var sharedCaptureSheet: CaptureSheet? {
        switch self {
        case .whiteBalance: .wb
        case .shutter: .shutter
        default: nil
        }
    }

    var capturePopupKind: NikonCapturePopupKind {
        switch self {
        case .iso: .iso
        case .stillISO: .stillISO
        case .shutter: .shutter
        case .whiteBalance: .whiteBalance
        case .codec: .codec
        case .iris, .stillIris: .aperture
        case .stillDrive: .drive
        case .focus, .stillFocus, .stillMode, .stillSize, .audio: .independentTabs
        default: .settings
        }
    }
}

/// The rows under a Nikon ladder tab: the focus dial switch, the codec colour tones, and the
/// timer shot count, drawn with the shared capture rows.
struct NikonLadderFooter: View {
    @Environment(NativeAppModel.self) private var model
    let picker: CameraPicker
    let tab: NikonLadderControl

    var body: some View {
        if picker == .focus || picker == .stillFocus {
            MonitorCaptureToggle(
                "Focus dial", help: "Shows a manual focus dial beside the picture.",
                isOn: Binding(
                    get: { model.mfDriveScrubEnabled }, set: { model.mfDriveScrubEnabled = $0 })
            )
        }
        if picker == .focus { FocusRackEntryRow() }
        if picker == .codec { NikonCodecColorFooter() }
        if picker == .stillDrive, case .value(let mode) = tab, mode == 1 || mode == 2 {
            let disabled = model.pickerModeDisabled(.stillDrive, mode: mode)
            MonitorCaptureStepper(
                "Shots", help: "Frames each timer release takes.",
                value: model.photoTimerShotCount, range: 1...9
            ) { model.adjustPhotoTimerShots(by: $0 - model.photoTimerShotCount) }
            .disabled(disabled).opacity(disabled ? 0.35 : 1)
        }
    }
}

/// A recording-format popup's choices for the shared format picker on the ladder sheet (twin of the
/// Android `ladderFormats`): the body's reported formats group each ladder token; a token it does
/// not describe stays unclassified.
func nikonLadderFormats(
    options: [String], recordingFormats: [NikonRecordingFormatPresentation]
) -> [CaptureFormatChoice<String>] {
    options.map { token in
        let format = recordingFormats.first { $0.token == token }
        return CaptureFormatChoice(
            value: token, title: token,
            imageArea: format?.imageArea.map { CaptureFormatGroup(id: $0, title: $0) },
            resolution: format.map { CaptureFormatGroup(id: $0.resolution, title: $0.resolution) },
            frameRate: format.map { CaptureFormatGroup(id: $0.frameRate, title: $0.frameRate) })
    }
}

/// The colour half of the one codec and colour popup: the tones the body offers for the active
/// codec, under the codec ladder. A codec with a fixed tone (R3D NE: Log3G10) shows it inert.
struct NikonCodecColorFooter: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        let choices = model.codecColorChoices
        if choices.showsColor {
            CaptureCodecColorSectionView(.color) {
                CaptureCodecColorTabs(
                    choices: choices.colors, selected: choices.selectedColor,
                    enabled: !model.isRecording && choices.colorEditable,
                    select: { id in
                        guard let label = choices.colors.first(where: { $0.id == id })?.label else {
                            return
                        }
                        model.applyMovieTone(label)
                    })
            }
            .padding(.top, 4)
        }
    }
}
