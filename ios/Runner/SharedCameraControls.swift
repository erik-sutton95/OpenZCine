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

/// The Edit view (per-DISP chrome) is the shared one over this monitor's own sections and DISP
/// modes: eye badges laid out together above the monitor, and the banner that names the mode.
typealias ChromeEditBadgeLayer = ChromeEditBadges<NativeAppModel>
typealias ChromeEditBanner = ChromeEditDoneBanner<NativeAppModel>
typealias ChromeEditBoundsKey = ChromeEditSectionBoundsKey<DisplayChromeVisibility.Section>

/// Per-DISP chrome follows the capture side the body reports (photo or video).
extension NativeAppModel: ChromeEditHost {
    var hapticsEnabled: Bool { preferences.hapticsEnabled }
    var chromeEditSections: [DisplayChromeVisibility.Section] {
        DisplayChromeVisibility.Section.allCases
    }

    func chromeSectionTitle(_ section: DisplayChromeVisibility.Section) -> String { section.title }
    func chromeSectionID(_ section: DisplayChromeVisibility.Section) -> String { section.rawValue }
    func chromeModeTitle(_ mode: DispMode) -> String { mode.title }

    func isChromeConfigurable(_ section: DisplayChromeVisibility.Section, in mode: DispMode) -> Bool
    {
        DisplayChromeVisibility.isConfigurable(section, in: mode)
    }

    func isChromeVisible(_ section: DisplayChromeVisibility.Section, in mode: DispMode) -> Bool {
        preferences.chrome(for: mode, capture: captureLayoutMode).isVisible(section)
    }
}

extension View {
    /// Outlines a monitor element while the Edit view is open on a mode that offers it (dimmed
    /// when hidden) and measures it for its eye badge. Outside the editor this is a no-op.
    func chromeEditable(_ section: DisplayChromeVisibility.Section, editing mode: DispMode?)
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
    static var onAccent: Color { .black }
    static var destructive: Color { rec }
    static var amber: Color { accent }
    static var aeLock: Color { accent }

    static func chromeColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}
