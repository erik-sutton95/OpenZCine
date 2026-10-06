import MonitorUI
import OpenCineCameraControls
import OpenZCineCore
import SwiftUI

// Shared camera-controls pieces on the monitor's model and palette.

/// The recovery card over a held live-view frame after an established session dropped is the
/// shared one: retry here, or leave for the operator menu. The model supplies its values.
typealias MonitorRecoveryOverlay = SessionRecoveryOverlay<NativeAppModel>

/// The vertical LUT wheel the LUT picker tabs use (built-in, RED and custom looks).
typealias AccentDrumWheel = LUTDrumWheel<LiveDesign>

extension NativeAppModel: SessionRecoveryHost {
    typealias Palette = LiveDesign

    var recoveryDeviceName: String { connectionProgressDeviceName }

    /// The connect machinery's live step while a retry runs ("Reading the camera's card... 40%").
    var recoveryProgressDetail: String {
        connectionStageDetail.isEmpty ? "Reconnecting to the camera\u{2026}" : connectionStageDetail
    }

    /// A Nikon body drops its session when another device scans for cameras, so a paused drop
    /// storm names that as the likely cause.
    var recoveryDropSuspect: SessionDropSuspect? { .otherDeviceScanning }
}

/// The shared live chrome reads the monitor's palette.
extension LiveDesign: LiveChromePalette {
    static var onAccent: Color { .black }
    static var destructive: Color { rec }
    static var amber: Color { accent }
    static var aeLock: Color { accent }

    static func chromeColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}
