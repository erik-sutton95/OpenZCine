/// Edge inset values used by the native monitor chrome.
public struct MonitorEdgeInsets: Equatable, Sendable {
    public static let zero = MonitorEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    // Insets in points.
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// Keeps the live camera surface full-bleed while placing touch chrome clear of device cutouts.
    public static func chrome(for safeArea: MonitorEdgeInsets) -> MonitorEdgeInsets {
        MonitorEdgeInsets(
            top: max(14, safeArea.top + 8),
            leading: max(16, safeArea.leading + 12),
            bottom: max(12, safeArea.bottom + 8),
            trailing: max(18, safeArea.trailing + 12)
        )
    }
}

/// Physical device orientation used to choose the live-view module direction.
public enum MonitorDeviceOrientation: Equatable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case unknown
}

/// Horizontal orientation for live-view module layout.
public enum MonitorHorizontalLayoutDirection: Equatable, Sendable {
    /// Standard landscape-left layout.
    case standard

    /// Horizontally mirrored landscape-right layout.
    case mirrored

    /// Resolves the layout direction from the dominant landscape side cutout.
    public static func resolve(for safeArea: MonitorEdgeInsets) -> MonitorHorizontalLayoutDirection
    {
        let cutout = StartupSideCutoutAvoidance.resolve(for: safeArea)

        return cutout.trailing > cutout.leading ? .mirrored : .standard
    }

    /// Resolves the layout direction from device orientation first, with safe area as fallback.
    public static func resolve(
        deviceOrientation: MonitorDeviceOrientation,
        safeArea: MonitorEdgeInsets
    ) -> MonitorHorizontalLayoutDirection {
        switch deviceOrientation {
        case .landscapeRight:
            return .mirrored
        case .portrait, .portraitUpsideDown, .landscapeLeft:
            return .standard
        case .unknown:
            return resolve(for: safeArea)
        }
    }
}

/// Rectangular frame for the native monitor live feed.
public struct MonitorFeedFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Mirrors the frame around the viewport's vertical center line — the same operation the
    /// module frames carry, so the feed can follow the one-mirror-at-the-exit rule they follow.
    public func mirroredHorizontally(in viewportWidth: Double) -> MonitorFeedFrame {
        MonitorFeedFrame(
            x: max(0, viewportWidth) - x - width,
            y: y,
            width: width,
            height: height
        )
    }
}

/// Placement for the native monitor live feed.
public enum MonitorFeedLayout {
    /// Native monitor preview aspect ratio.
    public static let aspectRatio = 16.0 / 9.0

    /// Classic-notch feed translation toward the opposite-side control rail.
    public static let classicNotchRailwardShift = 10.0

    /// Keeps the feed clear of a landscape-left side notch.
    public static func leadingInset(for safeArea: MonitorEdgeInsets) -> Double {
        let cutout = StartupSideCutoutAvoidance.resolve(for: safeArea)

        if cutout.trailing > cutout.leading {
            return 0
        }

        return cutout.leading
    }

    /// Builds the feed frame, using height as the stable landscape constraint. `aspect`
    /// defaults to the native 16:9 monitor frame; photography passes the active still
    /// image area's shape (3:2, 1:1, 16:9) so the full photo frame letterboxes instead
    /// of cropping top and bottom. `centered` places the frame mid-viewport (clamped to
    /// the safe-area insets) — photography's layout — instead of the cinema
    /// leading-inset placement.
    public static func frame(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        horizontalDirection: MonitorHorizontalLayoutDirection = .standard,
        aspect: Double = aspectRatio,
        centered: Bool = false
    ) -> MonitorFeedFrame {
        let aspectRatio = max(0.1, aspect)
        let leadingInset = leadingInset(for: safeArea)
        let viewportWidth = max(0, viewportWidth)
        let viewportHeight = max(0, viewportHeight)

        if viewportHeight > viewportWidth {
            let width = viewportWidth
            let height = width / aspectRatio
            // Vertical (rotated) feeds are taller than the tall viewport itself. Gated to
            // aspect < 1 so every landscape-or-wider aspect keeps its historical full-width
            // portrait frame untouched.
            if aspectRatio < 1, height > viewportHeight + 0.5 {
                // A SMALL overflow (≤15%) binds to the WIDTH and centre-crops the sliver: a
                // vertical phone filming vertical wants edge-to-edge, and the ~13 pt
                // pillarbox this produced read as a rendering bug in the field. The mount
                // clips the overflow. A LARGE overflow still pillarboxes — cropping real
                // framing is worse than bars.
                if height <= viewportHeight * 1.15 {
                    return MonitorFeedFrame(
                        x: 0, y: (viewportHeight - height) / 2, width: width, height: height)
                }
                let boundWidth = viewportHeight * aspectRatio
                return MonitorFeedFrame(
                    x: (viewportWidth - boundWidth) / 2, y: 0,
                    width: boundWidth, height: viewportHeight)
            }
            return MonitorFeedFrame(x: 0, y: 0, width: width, height: height)
        }

        let width = viewportHeight * aspectRatio

        // Landscape viewport narrower than 16:9 (4:3-ish iPads): the full-height frame would
        // overflow the right edge — and drag the feed-spanning top deck off-center with it.
        // With the side-rail chrome relocated into the corners (see `isWidthConstrained`), the
        // letterboxed frame spans the full width, vertically centered between the corner chrome
        // bands. The tolerance keeps exact-16:9 mounts (portrait fit/fill hand this function
        // their own 16:9 box, where width == viewportWidth up to float drift) on the untouched
        // full-height path.
        if width > viewportWidth + 0.5 {
            let lanedHeight = viewportWidth / aspectRatio
            return MonitorFeedFrame(
                x: 0,
                y: (viewportHeight - lanedHeight) / 2,
                width: viewportWidth,
                height: lanedHeight
            )
        }

        let remainingWidth = max(0, viewportWidth - width)
        let x: Double
        if centered, aspectRatio < Self.aspectRatio - 0.001 {
            // Mid-viewport, clamped so neither edge runs under a safe-area inset. Only the
            // narrower-than-native shapes (3:2, 1:1) centre — a 16:9 photo frame takes the
            // exact video-mode placement, clear of the system rail.
            let maxX = max(leadingInset, remainingWidth - max(0, safeArea.trailing))
            x = min(max(remainingWidth / 2, leadingInset), maxX)
        } else if MonitorBatteryRailLayout.usesClassicSideNotch(safeArea: safeArea) {
            // Classic iPhones report equal horizontal safe areas even though only one side has
            // the notch: clear the leading side, biased slightly toward the opposite control
            // rail to close its oversized black gap. STANDARD space only — the exit mirror
            // below owns the other side, for this arm and every other one. (This arm used to
            // mirror in place, which for its equal insets happened to equal the exit mirror —
            // and the island arm below did not mirror at all, so the chrome flipped around a
            // picture that stayed put: the capture rail overlaid the feed's left edge and a
            // dead lane sat inboard of the island.)
            let availableShift = max(
                0,
                remainingWidth - max(0, safeArea.leading) - max(0, safeArea.trailing)
            )
            let railwardShift = min(classicNotchRailwardShift, availableShift)
            x = min(remainingWidth, safeArea.leading + railwardShift)
        } else {
            x = min(remainingWidth, leadingInset)
        }

        let standard = MonitorFeedFrame(x: x, y: 0, width: width, height: viewportHeight)
        // ONE mirror, at the exit, for every arm above — the same rule the module frames follow.
        // A direction-aware arm here and a direction-blind one there is exactly how the two
        // halves of the screen ended up disagreeing about which side the island was on.
        guard horizontalDirection == .mirrored else { return standard }
        return standard.mirroredHorizontally(in: viewportWidth)
    }

    /// Fits the feed to the visible viewport without expanding the source frame.
    public static func fullBleedFrame(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        horizontalDirection: MonitorHorizontalLayoutDirection = .standard,
        aspect: Double = aspectRatio,
        centered: Bool = false
    ) -> MonitorFeedFrame {
        frame(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            horizontalDirection: horizontalDirection,
            aspect: aspect,
            centered: centered
        )
    }
}

/// Placement for native monitor chrome that should stay independent from feed cutout avoidance.
public enum MonitorChromeLayout {
    /// Keeps chrome controls on their stable screen-relative margins while the feed handles cutouts.
    public static func insets(feedSafeArea _: MonitorEdgeInsets) -> MonitorEdgeInsets {
        MonitorEdgeInsets.chrome(for: .zero)
    }
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

    /// Horizontal shift for a restored full-screen canvas inside safe-area-sized geometry.
    public static func canvasOffsetX(
        layoutWidth: Double,
        safeArea: MonitorEdgeInsets,
        screenWidth: Double? = nil
    ) -> Double {
        0
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

/// Landscape side-notch geometry the feed placement reads.
public enum MonitorBatteryRailLayout {
    /// Whether landscape safe-area geometry identifies a wider pre-Dynamic-Island notch.
    /// Apple exposes no public notch-type API, so keep this deliberately narrow: classic-notch
    /// phones occupy the 44–50pt band while Dynamic Island phones use larger side insets.
    public static func usesClassicSideNotch(safeArea: MonitorEdgeInsets) -> Bool {
        let leading = max(0, safeArea.leading)
        let trailing = max(0, safeArea.trailing)
        let minimumInset = min(leading, trailing)
        let maximumInset = max(leading, trailing)
        return minimumInset >= 40 && maximumInset <= 50 && abs(leading - trailing) < 4
    }
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

/// Side cutout reservation for landscape iPhone startup layouts.
public struct StartupSideCutoutAvoidance: Equatable, Sendable {
    /// Minimum side safe-area inset that represents a hardware cutout rather than corner padding.
    public static let minimumCutoutInset = 50.0

    /// Width to keep empty in the middle of the leading edge.
    public let leading: Double

    /// Width to keep empty in the middle of the trailing edge.
    public let trailing: Double

    public init(leading: Double, trailing: Double) {
        self.leading = leading
        self.trailing = trailing
    }

    /// Whether either landscape side has a hardware cutout lane.
    public var hasSideCutout: Bool {
        leading > 0 || trailing > 0
    }

    /// Keeps only large side safe-area insets as cutout lanes, allowing normal corner padding.
    public static func resolve(for safeArea: MonitorEdgeInsets)
        -> StartupSideCutoutAvoidance
    {
        StartupSideCutoutAvoidance(
            leading: safeArea.leading >= minimumCutoutInset ? safeArea.leading : 0,
            trailing: safeArea.trailing >= minimumCutoutInset ? safeArea.trailing : 0
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
