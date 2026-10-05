import OpenZCineCore
import SwiftUI
import struct MonitorPresentation.MonitorEdgeInsets

/// Nikon's saved assist identifiers remain owned by its existing Codable preferences.
typealias MonitorAssistTool = OpenZCineCore.MonitorAssistTool

extension GeometryProxy {
    var monitorEdgeInsets: MonitorEdgeInsets {
        MonitorEdgeInsets(
            top: Double(safeAreaInsets.top),
            leading: Double(safeAreaInsets.leading),
            bottom: Double(safeAreaInsets.bottom),
            trailing: Double(safeAreaInsets.trailing)
        )
    }
}

extension MonitorEdgeInsets {
    /// Floors the top inset so top-leading chrome clears the iPadOS 26 window-control pill.
    ///
    /// In iPadOS 26's default "Windowed Apps" mode the system floats a close/minimize capsule
    /// over every scene's top-leading corner — including this app's, which opts out of window
    /// resizing (`UIRequiresFullScreen` + fixed orientations) and therefore runs as a scaled
    /// full-screen canvas. In that compatibility mode the pill is composited by the system and
    /// is invisible to the process: safe areas, the iOS 26 corner-adapted layout regions
    /// (`UIView.LayoutRegion`), and `UIWindowScene.effectiveGeometry` all report plain
    /// full-screen values (verified on the iPadOS 26.2 simulator — top inset 0, corner
    /// adaptation 9.5pt display-corner only, scene == screen bounds). The system's own
    /// compatibility placement parks the pill in the status-bar band, but this app hides the
    /// status bar, so the band must be reserved manually.
    ///
    /// Apply this ONLY to chrome-placement insets — never to `feedSafeArea`/viewport math,
    /// which must restore physical-screen geometry from real insets.
    @MainActor var clearingWindowControls: MonitorEdgeInsets {
        let clearance = MonitorWindowControlsClearance.top
        guard clearance > top else { return self }
        return MonitorEdgeInsets(
            top: clearance, leading: leading, bottom: bottom, trailing: trailing)
    }
}

/// Top band reserved for the iPadOS 26 window-control pill (see `clearingWindowControls`).
@MainActor
enum MonitorWindowControlsClearance {
    /// 40pt clears the ~26pt-tall (screen points) pill — but only a WINDOWED scene needs it.
    ///
    /// This used to reserve the band unconditionally, costing the top chrome ~26pt of headroom on
    /// every iPadOS 26 iPad. The number was sized before `9dc2523`: back then `UIRequiresFullScreen`
    /// put the app in a SCALED compatibility canvas (~0.65–1.0 measured), and that scale inflated a
    /// 26pt pill to 40pt of layout space. Adopting the windowing model retired the scaled canvas —
    /// the app runs at native scale now — but the constant outlived its reason.
    ///
    /// Full screen reserves nothing: iPadOS 26 keeps the window controls hidden until the operator
    /// reveals them, the same deal every full-screen app makes with the status bar (no pill
    /// composites over the band — verified on the iPadOS 26.2 simulator and in a device capture).
    /// A resized window shows them persistently, so the band still stands there, where the lock
    /// button would otherwise sit under the capsule.
    static var top: Double {
        guard #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .pad,
            !sceneFillsDisplay
        else { return 0 }
        return 40
    }

    /// True while the scene fills the display. A windowed scene reports smaller bounds than its
    /// screen; the scaled compatibility canvas this replaces reported them equal, which is why
    /// scene geometry was no help before the app adopted windowing.
    private static var sceneFillsDisplay: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard
            let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first
        else { return true }
        let bounds = scene.coordinateSpace.bounds.size
        let screen = scene.screen.bounds.size
        return abs(bounds.width - screen.width) <= 1 && abs(bounds.height - screen.height) <= 1
    }
}

extension OperatorPreferences.StreamPreset {
    var next: OperatorPreferences.StreamPreset {
        switch self {
        case .fast: .balanced
        case .balanced: .quality
        case .quality: .fast
        }
    }
}

extension OperatorPreferences.QualityBias {
    var next: OperatorPreferences.QualityBias {
        switch self {
        case .latency: .balanced
        case .balanced: .detail
        case .detail: .latency
        }
    }
}

// `liveViewImageSize` / `liveViewImageCompression` moved onto the shared-core enums
// (`OperatorPreferences.StreamPreset` / `.QualityBias`) so both shells send the same bytes —
// they had drifted as two independently maintained copies of the same table.
