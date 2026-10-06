import MonitorPresentation

/// Placement for the native monitor live feed.
public enum MonitorFeedLayout {
    /// Native monitor preview aspect ratio.
    public static let aspectRatio = 16.0 / 9.0
}

/// Coordinate space SwiftUI uses when reporting live-view geometry.
public enum MonitorLiveViewGeometrySpace: Equatable, Sendable {
    /// The reported geometry excludes horizontal safe-area lanes.
    case safeArea

    /// The reported geometry already includes horizontal safe-area lanes.
    case fullScreen
}

/// Viewport dimensions used by live-view chrome when SwiftUI reports safe-area-sized geometry.
public enum MonitorLiveViewViewport {
    /// Restores the horizontal safe-area lanes excluded from the layout width.
    public static func fullWidth(
        layoutWidth: Double,
        safeArea: MonitorEdgeInsets,
        screenWidth: Double? = nil,
        geometrySpace: MonitorLiveViewGeometrySpace = .safeArea
    ) -> Double {
        let layoutWidth = max(0, layoutWidth)
        let restoredWidth = layoutWidth + max(0, safeArea.leading) + max(0, safeArea.trailing)
        let geometryWidth =
            geometrySpace == .safeArea
            ? restoredWidth
            : layoutWidth

        guard let screenWidth else {
            return geometryWidth
        }

        return max(geometryWidth, max(0, screenWidth))
    }

}

/// Rectangular frame for a live-view interface module.
public struct MonitorModuleFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Live-view chrome bands the floating assists clear.
public enum MonitorLiveViewModuleLayout {
    /// Margin between the bottom chrome bars and the true screen edge. Tighter than the chrome
    /// inset so the bars hug the bottom of the feed, matching the wireframe.
    public static let bottomBarBottomInset = 14.0

    /// Vertical space reserved for the top information deck.
    public static let topInfoDeckHeight = 46.0
}

/// The record button's size, which the photography chrome matches.
public enum MonitorSideRailControlLayout {
    public static let recordButtonSize = 82.8
}

/// Content margins used by the native startup and pairing screens.
public enum StartupLayoutMargins {
    /// Keeps startup content close to the device edges so it can wrap around side cutouts.
    public static func content(for safeArea: MonitorEdgeInsets, compact: Bool)
        -> MonitorEdgeInsets
    {
        let horizontalBase = compact ? 16.0 : 20.0

        return MonitorEdgeInsets(
            top: safeArea.top + (compact ? 18 : 20),
            leading: horizontalBase,
            bottom: safeArea.bottom + (compact ? 16 : 18),
            trailing: horizontalBase
        )
    }
}

/// Semantic startup layout profile selected from viewport shape and safe content width.
public enum StartupLayoutProfile: Equatable, Sendable {
    /// Narrow portrait shape. The app is currently landscape-locked, but this keeps policy explicit.
    case compactPortrait

    /// Landscape shape where two readable columns cannot fit.
    case compactLandscape

    /// Primary iPhone landscape layout.
    case regularLandscape

    /// Large landscape layout with capped content width.
    case wideLandscape
}

/// Startup content arrangement.
public enum StartupContentMode: Equatable, Sendable {
    /// Intro and controls stack vertically.
    case singleColumn

    /// Intro and controls sit side by side.
    case twoColumn
}

/// Adaptive startup content layout after safe-area margins have been applied.
public struct StartupContentLayout: Equatable, Sendable {
    /// Smallest readable intro column in two-column mode.
    public static let minimumIntroColumnWidth = 230.0

    /// Smallest readable action/list column in two-column mode.
    public static let minimumActionColumnWidth = 340.0

    /// Tightest acceptable spacing between two startup columns.
    public static let minimumColumnSpacing = 32.0

    /// Preferred maximum content width before wide layouts stop stretching controls.
    public static let maximumContentWidth = 920.0

    /// Maximum width for a single-column startup stack.
    public static let maximumSingleColumnWidth = 520.0

    public let profile: StartupLayoutProfile
    public let mode: StartupContentMode

    /// Width remaining for startup content after margins.
    public let availableWidth: Double

    /// Actual width used by the startup content.
    public let contentWidth: Double

    public let introColumnWidth: Double
    public let actionColumnWidth: Double
    public let columnSpacing: Double

    /// Whether secondary art, such as the discovery scope, has enough space to be useful.
    public let showSecondaryVisuals: Bool

    /// Whether footer links should be shown without crowding primary actions.
    public let showFooterLinks: Bool

    /// Total horizontal footprint of the current column arrangement.
    public var totalColumnWidth: Double {
        switch mode {
        case .singleColumn:
            contentWidth
        case .twoColumn:
            introColumnWidth + columnSpacing + actionColumnWidth
        }
    }

    /// Fits startup content inside the safe content area using adaptive columns.
    public static func fit(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets
    ) -> StartupContentLayout {
        let portrait = viewportHeight > viewportWidth
        let compactLandscape = !portrait && viewportWidth < 760
        let margins = StartupLayoutMargins.content(for: safeArea, compact: portrait)
        let availableWidth = max(0, viewportWidth - margins.leading - margins.trailing)
        let availableHeight = max(0, viewportHeight - margins.top - margins.bottom)
        let minimumTwoColumnWidth =
            minimumIntroColumnWidth + minimumColumnSpacing + minimumActionColumnWidth
        let shouldUseSingleColumn =
            portrait || compactLandscape || availableWidth < minimumTwoColumnWidth

        if shouldUseSingleColumn {
            let profile: StartupLayoutProfile = portrait ? .compactPortrait : .compactLandscape
            let contentWidth = min(availableWidth, maximumSingleColumnWidth)

            return StartupContentLayout(
                profile: profile,
                mode: .singleColumn,
                availableWidth: availableWidth,
                contentWidth: contentWidth,
                introColumnWidth: contentWidth,
                actionColumnWidth: contentWidth,
                columnSpacing: 0,
                showSecondaryVisuals: availableWidth >= 360 && availableHeight >= 300,
                showFooterLinks: availableHeight >= 340
            )
        }

        let profile: StartupLayoutProfile =
            availableWidth > maximumContentWidth
            ? .wideLandscape
            : .regularLandscape
        let contentWidth = min(availableWidth, maximumContentWidth)
        let columnSpacing = min(66, max(minimumColumnSpacing, contentWidth * 0.07))
        let actionColumnWidth = min(
            520,
            max(minimumActionColumnWidth, contentWidth * 0.48)
        )
        let introColumnWidth = contentWidth - columnSpacing - actionColumnWidth

        guard introColumnWidth >= minimumIntroColumnWidth else {
            let fallbackProfile: StartupLayoutProfile =
                portrait ? .compactPortrait : .compactLandscape
            let fallbackContentWidth = min(availableWidth, maximumSingleColumnWidth)

            return StartupContentLayout(
                profile: fallbackProfile,
                mode: .singleColumn,
                availableWidth: availableWidth,
                contentWidth: fallbackContentWidth,
                introColumnWidth: fallbackContentWidth,
                actionColumnWidth: fallbackContentWidth,
                columnSpacing: 0,
                showSecondaryVisuals: availableWidth >= 360 && availableHeight >= 300,
                showFooterLinks: availableHeight >= 340
            )
        }

        return StartupContentLayout(
            profile: profile,
            mode: .twoColumn,
            availableWidth: availableWidth,
            contentWidth: contentWidth,
            introColumnWidth: introColumnWidth,
            actionColumnWidth: actionColumnWidth,
            columnSpacing: columnSpacing,
            showSecondaryVisuals: introColumnWidth >= 250 && availableHeight >= 300,
            showFooterLinks: availableHeight >= 330 && introColumnWidth >= 260
        )
    }
}

/// Determines whether the ready screen can open the live monitor.
public enum StartupReadyLiveViewPolicy {
    public static func canEnterMonitor(
        isConnected: Bool,
        hasActiveSession: Bool,
        isBusy: Bool
    ) -> Bool {
        isConnected && hasActiveSession && !isBusy
    }
}

/// Primary action exposed by the automatic startup discovery screen.
public enum StartupDiscoveryPrimaryAction: Equatable, Sendable {
    /// No command is shown while automatic discovery is still looking for cameras.
    case none

    /// Pair with the currently selected discovered camera (never paired by this app).
    case pairCamera(isEnabled: Bool)

    /// Reconnect a camera this app has paired before; the camera mediates whether a code is
    /// actually needed, so this usually connects silently.
    case connectCamera(isEnabled: Bool)

    /// Resolves the discovery command from selection, busy state, and prior pairing.
    /// `isKnownCamera` only chooses the button label; the startup flow differentiates known vs
    /// unknown cameras and may skip the probe step for unknown ones.
    public static func resolve(hasSelectedCamera: Bool, isBusy: Bool, isKnownCamera: Bool)
        -> StartupDiscoveryPrimaryAction
    {
        guard hasSelectedCamera else { return .none }
        return isKnownCamera
            ? .connectCamera(isEnabled: !isBusy)
            : .pairCamera(isEnabled: !isBusy)
    }

    /// User-facing button title, when a button should be shown.
    public var title: String? {
        switch self {
        case .none:
            nil
        case .pairCamera:
            "Pair camera"
        case .connectCamera:
            "Connect camera"
        }
    }

    /// Whether the visible primary action should accept taps.
    public var isEnabled: Bool {
        switch self {
        case .none:
            false
        case .pairCamera(let isEnabled), .connectCamera(let isEnabled):
            isEnabled
        }
    }
}
