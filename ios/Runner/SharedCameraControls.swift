import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenZCineCore
import SwiftUI

// Shared camera-controls pieces on the monitor's model and palette.

/// The recovery card over a held live-view frame after an established session dropped is the
/// shared one: retry here, or leave for the operator menu. The model supplies its values.
typealias MonitorRecoveryOverlay = SessionRecoveryOverlay<NativeAppModel>

/// The vertical LUT wheel the LUT picker tabs use (built-in, RED and custom looks).
typealias AccentDrumWheel = LUTDrumWheel<LiveDesign>

/// The Edit view (per-DISP chrome) is the shared one over this monitor's own sections and DISP
/// modes: eye badges laid out together above the monitor, and the banner that names the mode.
typealias ChromeEditBadgeLayer = ChromeEditBadges<NativeAppModel>
typealias ChromeEditBanner = ChromeEditDoneBanner<NativeAppModel>
typealias ChromeEditBoundsKey = ChromeEditSectionBoundsKey<MonitorDisplayChrome.Section>

/// The Edit view edits the shared per-DISP chrome the one display owner keeps.
extension NativeAppModel: ChromeEditHost {
    typealias ChromeSection = MonitorDisplayChrome.Section
    typealias ChromeMode = MonitorDisplayMode
    var hapticsEnabled: Bool { preferences.hapticsEnabled }

    func isChromeVisible(_ section: MonitorDisplayChrome.Section, in mode: MonitorDisplayMode) -> Bool {
        operatorSession.chrome(for: mode).isVisible(section)
    }

    func toggleChrome(_ section: MonitorDisplayChrome.Section, for mode: MonitorDisplayMode) {
        operatorSession.toggle(section, in: mode)
    }
}

extension View {
    /// Outlines a monitor element while the Edit view is open on a mode that offers it (dimmed
    /// when hidden) and measures it for its eye badge. Outside the editor this is a no-op.
    func chromeEditable(_ section: MonitorDisplayChrome.Section, editing mode: MonitorDisplayMode?)
        -> some View
    {
        modifier(ChromeEditableModifier<NativeAppModel>(section: section, mode: mode))
    }
}

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
    static var onAccent: Color { MonitorTheme.onAccent }
    static var destructive: Color { rec }
    /// Zebra and highlight amber. Stable, so a brand-gold accent does not recolor stored paint.
    static var amber: Color {
        MonitorTheme.edrSRGB(red: 0.914, green: 0.674, blue: 0.208, gain: MonitorTheme.hdrGain)
    }
    /// AE lock yellow: the focus box, its AE-L tag, and the unlock key.
    static var aeLock: Color {
        MonitorTheme.edrSRGB(
            red: CGFloat(0xF5) / 255, green: CGFloat(0xD0) / 255, blue: CGFloat(0x52) / 255,
            gain: MonitorTheme.hdrGain)
    }

    static func chromeColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        MonitorTheme.edrSRGB(red: red, green: green, blue: blue, gain: MonitorTheme.hdrGain)
    }
}
