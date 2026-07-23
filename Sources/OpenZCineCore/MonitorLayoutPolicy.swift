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
}

/// Named anchors for placing a fixed-size module inside a layout region.
public enum MonitorLayoutAnchor: Equatable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing
}

/// Rectangular layout region used to anchor monitor modules.
public struct MonitorLayoutRegion: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// Creates a region covering the full viewport.
    public static func viewport(width: Double, height: Double) -> MonitorLayoutRegion {
        MonitorLayoutRegion(x: 0, y: 0, width: width, height: height)
    }

    /// Returns this region inset by the provided edges.
    public func inset(_ edges: MonitorEdgeInsets) -> MonitorLayoutRegion {
        MonitorLayoutRegion(
            x: x + max(0, edges.leading),
            y: y + max(0, edges.top),
            width: width - max(0, edges.leading) - max(0, edges.trailing),
            height: height - max(0, edges.top) - max(0, edges.bottom)
        )
    }

    /// Returns the lane between the feed frame's right edge and this region's right edge.
    public func trailingLane(after feed: MonitorFeedFrame) -> MonitorLayoutRegion {
        let laneX = min(maxX, max(x, feed.x + feed.width))

        return MonitorLayoutRegion(
            x: laneX,
            y: y,
            width: maxX - laneX,
            height: height
        )
    }

    /// Places a fixed-size module inside the region using the given anchor.
    public func place(
        width placedWidth: Double,
        height placedHeight: Double,
        anchor: MonitorLayoutAnchor
    ) -> MonitorModuleFrame {
        let placedWidth = max(0, placedWidth)
        let placedHeight = max(0, placedHeight)
        let placedX: Double
        let placedY: Double

        switch anchor {
        case .topLeading, .leading, .bottomLeading:
            placedX = x
        case .top, .center, .bottom:
            placedX = x + (width - placedWidth) / 2
        case .topTrailing, .trailing, .bottomTrailing:
            placedX = maxX - placedWidth
        }

        switch anchor {
        case .topLeading, .top, .topTrailing:
            placedY = y
        case .leading, .center, .trailing:
            placedY = y + (height - placedHeight) / 2
        case .bottomLeading, .bottom, .bottomTrailing:
            placedY = maxY - placedHeight
        }

        return MonitorModuleFrame(
            x: placedX,
            y: placedY,
            width: placedWidth,
            height: placedHeight
        )
    }
}

/// Placement for the native monitor live feed.
public enum MonitorFeedLayout {
    /// Native monitor preview aspect ratio.
    public static let aspectRatio = 16.0 / 9.0

    /// Classic-notch feed translation toward the opposite-side control rail.
    public static let classicNotchRailwardShift = 10.0

    /// True for landscape viewports narrower than 16:9 (4:3-ish iPads), where the full-height
    /// feed would overflow the width. On these screens the side-rail chrome moves into the
    /// corners (battery inline beside the lock, settings/media top-trailing, record/DISP
    /// bottom-trailing) so the letterboxed feed can span the full width. False for every
    /// wider-than-16:9 landscape phone and for portrait, keeping those layouts untouched.
    public static func isWidthConstrained(viewportWidth: Double, viewportHeight: Double) -> Bool {
        let viewportWidth = max(0, viewportWidth)
        let viewportHeight = max(0, viewportHeight)

        return viewportHeight <= viewportWidth
            && viewportHeight * aspectRatio > viewportWidth + 0.5
    }

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
    /// of cropping top and bottom.
    public static func frame(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        horizontalDirection: MonitorHorizontalLayoutDirection = .standard,
        aspect: Double = aspectRatio
    ) -> MonitorFeedFrame {
        let aspectRatio = max(0.1, aspect)
        let leadingInset = leadingInset(for: safeArea)
        let viewportWidth = max(0, viewportWidth)
        let viewportHeight = max(0, viewportHeight)

        if viewportHeight > viewportWidth {
            let width = viewportWidth
            let height = width / aspectRatio
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
        if MonitorBatteryRailLayout.usesClassicSideNotch(safeArea: safeArea) {
            // Classic iPhones report equal horizontal safe areas even though only one side has
            // the notch. Use physical orientation to clear that side, then bias the feed slightly
            // toward the opposite control rail to close its oversized black gap.
            let availableShift = max(
                0,
                remainingWidth - max(0, safeArea.leading) - max(0, safeArea.trailing)
            )
            let railwardShift = min(classicNotchRailwardShift, availableShift)
            x =
                horizontalDirection == .mirrored
                ? max(0, remainingWidth - safeArea.trailing - railwardShift)
                : min(remainingWidth, safeArea.leading + railwardShift)
        } else {
            x = min(remainingWidth, leadingInset)
        }

        return MonitorFeedFrame(x: x, y: 0, width: width, height: viewportHeight)
    }

    /// Fits the feed to the visible viewport without expanding the source frame.
    public static func fullBleedFrame(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        horizontalDirection: MonitorHorizontalLayoutDirection = .standard,
        aspect: Double = aspectRatio
    ) -> MonitorFeedFrame {
        frame(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            horizontalDirection: horizontalDirection,
            aspect: aspect
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

    /// Mirrors the frame around the viewport's vertical center line.
    public func mirroredHorizontally(in viewportWidth: Double) -> MonitorModuleFrame {
        MonitorModuleFrame(
            x: max(0, viewportWidth) - x - width,
            y: y,
            width: width,
            height: height
        )
    }
}

/// Independent frames for the native live-view modules.
public struct MonitorLiveViewModuleLayout: Equatable, Sendable {
    /// Horizontal spacing between bottom chrome modules.
    public static let bottomModuleSpacing = 12.0

    /// Margin between the bottom chrome bars and the true screen edge. Tighter than the chrome
    /// inset so the bars hug the bottom of the feed, matching the wireframe.
    public static let bottomBarBottomInset = 14.0

    /// Vertical space reserved for the top information deck.
    public static let topInfoDeckHeight = 46.0

    /// Horizontal inset that floats the top information deck over the feed, clear of the side lanes.
    public static let topInfoDeckSideInset = 10.0

    /// Horizontal breathing room between the lock control and the information deck.
    public static let topInfoDeckControlGap = 12.0

    /// Diameter of the top-leading lock button.
    public static let lockButtonSize = 40.0

    /// Trailing chrome width reserved on width-constrained (4:3 iPad) landscape layouts for the
    /// inline bottom-corner record + DISP pair: both buttons plus a bar gap and the inter-button
    /// gap, so the shortened bottom bars end clear of the cluster.
    public static var constrainedBottomCornerReservedWidth: Double {
        MonitorSideRailControlLayout.recordButtonSize
            + MonitorSideRailControlLayout.displayButtonWidth
            + 2 * bottomModuleSpacing
    }

    /// Feed frame. This is the only module affected by feed safe-area cutout avoidance.
    public let feed: MonitorFeedFrame

    public let batteryRail: MonitorModuleFrame
    public let topInfoDeck: MonitorModuleFrame
    public let bottomAssistTools: MonitorModuleFrame
    public let bottomCaptureSettings: MonitorModuleFrame
    public let rightRailControls: MonitorModuleFrame

    /// Vertical debug line marking the center of the right-rail lane.
    public let rightRailLaneCenterLine: MonitorModuleFrame

    public let lockButton: MonitorModuleFrame

    public init(
        feed: MonitorFeedFrame,
        batteryRail: MonitorModuleFrame,
        topInfoDeck: MonitorModuleFrame,
        bottomAssistTools: MonitorModuleFrame,
        bottomCaptureSettings: MonitorModuleFrame,
        rightRailControls: MonitorModuleFrame,
        rightRailLaneCenterLine: MonitorModuleFrame,
        lockButton: MonitorModuleFrame
    ) {
        self.feed = feed
        self.batteryRail = batteryRail
        self.topInfoDeck = topInfoDeck
        self.bottomAssistTools = bottomAssistTools
        self.bottomCaptureSettings = bottomCaptureSettings
        self.rightRailControls = rightRailControls
        self.rightRailLaneCenterLine = rightRailLaneCenterLine
        self.lockButton = lockButton
    }

    /// Mirrors the live-view chrome around the viewport's vertical center line without moving feed.
    public func mirroredChromeHorizontally(in viewportWidth: Double) -> MonitorLiveViewModuleLayout
    {
        MonitorLiveViewModuleLayout(
            feed: feed,
            batteryRail: batteryRail.mirroredHorizontally(in: viewportWidth),
            // Top deck floats over the feed, which is not mirrored, so it stays put too.
            topInfoDeck: topInfoDeck,
            bottomAssistTools: bottomAssistTools.mirroredHorizontally(in: viewportWidth),
            bottomCaptureSettings: bottomCaptureSettings.mirroredHorizontally(in: viewportWidth),
            rightRailControls: rightRailControls.mirroredHorizontally(in: viewportWidth),
            rightRailLaneCenterLine: rightRailLaneCenterLine.mirroredHorizontally(
                in: viewportWidth
            ),
            lockButton: lockButton.mirroredHorizontally(in: viewportWidth)
        )
    }

    /// Fits independent live-view modules into the monitor viewport.
    public static func fit(
        viewportWidth: Double,
        viewportHeight: Double,
        feedSafeArea: MonitorEdgeInsets,
        chromeInsets: MonitorEdgeInsets,
        bottomBarHeight: Double,
        horizontalDirection: MonitorHorizontalLayoutDirection = .standard
    ) -> MonitorLiveViewModuleLayout {
        let viewportWidth = max(0, viewportWidth)
        let viewportHeight = max(0, viewportHeight)
        let screen = MonitorLayoutRegion.viewport(width: viewportWidth, height: viewportHeight)
        let chrome = screen.inset(chromeInsets)
        let bottomBarHeight = max(0, bottomBarHeight)
        // Width-constrained (4:3-ish iPad) landscape: the record + DISP pair sits inline in the
        // bottom-trailing corner, so the bottom bars shorten to leave that corner free.
        let constrained = MonitorFeedLayout.isWidthConstrained(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        let bottomBarsWidth =
            constrained
            ? max(0, chrome.width - Self.constrainedBottomCornerReservedWidth)
            : chrome.width
        let bottomModuleWidth = max(0, (bottomBarsWidth - bottomModuleSpacing) / 2)
        // The chrome viewport now spans the full screen height, so the screen edge is the true
        // bottom; hug the bars to it, tighter than the chrome inset.
        let bottomBarBottom = screen.maxY - bottomBarBottomInset
        let bottomRegion = MonitorLayoutRegion(
            x: chrome.x,
            y: max(chrome.y, bottomBarBottom - bottomBarHeight),
            width: bottomBarsWidth,
            height: bottomBarHeight
        )
        let bottomCaptureRegion = MonitorLayoutRegion(
            x: bottomRegion.x + bottomModuleWidth + bottomModuleSpacing,
            y: bottomRegion.y,
            width: bottomModuleWidth,
            height: bottomRegion.height
        )
        let rightRailWidth = Self.rightRailWidth(for: chrome.width)
        let feed = MonitorFeedLayout.fullBleedFrame(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: feedSafeArea,
            horizontalDirection: horizontalDirection
        )
        let usesClassicSideNotch = MonitorBatteryRailLayout.usesClassicSideNotch(
            safeArea: feedSafeArea
        )
        // The classic-notch feed moves toward the rail, but the rail itself stays on its
        // established center line. Recover the pre-translation feed edge for lane placement.
        let availableClassicShift = max(
            0,
            viewportWidth - feed.width - max(0, feedSafeArea.leading)
                - max(0, feedSafeArea.trailing)
        )
        let classicShift =
            usesClassicSideNotch
            ? min(MonitorFeedLayout.classicNotchRailwardShift, availableClassicShift)
            : 0
        let railReferenceFeed = MonitorFeedFrame(
            x: feed.x
                + (horizontalDirection == .mirrored ? classicShift : -classicShift),
            y: feed.y,
            width: feed.width,
            height: feed.height
        )
        let rightRailLane = screen.trailingLane(after: railReferenceFeed)
        let rightRailControls = Self.rightRailFrame(
            lane: rightRailLane,
            chrome: chrome,
            railWidth: rightRailWidth
        )

        let lockButton = MonitorModuleFrame(
            // Vertically centered in the top deck's band so its top edge lines up with the
            // top bar pill (which is centered in that same band), rather than the chrome top.
            x: chrome.x,
            y: chrome.y + (topInfoDeckHeight - lockButtonSize) / 2,
            width: lockButtonSize,
            height: lockButtonSize
        )

        // Keep the deck centered over the feed while clearing the lock only on compact
        // classic-notch phones. Every other device retains the established deck inset.
        let minimumDeckInset =
            lockButton.x + lockButton.width + topInfoDeckControlGap - feed.x
        let deckInset =
            constrained
            ? topInfoDeckSideInset
            : usesClassicSideNotch
                ? max(topInfoDeckSideInset, minimumDeckInset)
                : topInfoDeckSideInset
        let deckLeft = feed.x + deckInset
        let deckRight = feed.x + feed.width - deckInset

        // Width-constrained landscape also inlines the battery indicators beside the lock button
        // in the top chrome band instead of stacking them in a leading rail (no side lanes exist).
        let batteryRail =
            constrained
            ? MonitorModuleFrame(
                x: chrome.x + lockButtonSize + MonitorBatteryRailLayout.inlineLeadingGap,
                y: chrome.y + (topInfoDeckHeight - lockButtonSize) / 2,
                width: MonitorBatteryRailLayout.inlineClusterWidth,
                height: lockButtonSize
            )
            : MonitorModuleFrame(
                x: chrome.x,
                y: chrome.y,
                width: MonitorBatteryRailLayout.indicatorWidth,
                height: chrome.height
            )

        let layout = MonitorLiveViewModuleLayout(
            feed: feed,
            batteryRail: batteryRail,
            topInfoDeck: MonitorModuleFrame(
                x: deckLeft,
                y: chrome.y,
                width: max(0, deckRight - deckLeft),
                height: topInfoDeckHeight
            ),
            bottomAssistTools: Self.bottomAssistFrame(
                in: bottomRegion,
                width: bottomModuleWidth,
                batteryRail: batteryRail,
                safeArea: feedSafeArea
            ),
            bottomCaptureSettings: bottomCaptureRegion.place(
                width: bottomModuleWidth,
                height: bottomCaptureRegion.height,
                anchor: .leading
            ),
            rightRailControls: rightRailControls,
            rightRailLaneCenterLine: Self.rightRailLaneCenterLine(
                lane: rightRailLane,
                viewportHeight: viewportHeight
            ),
            lockButton: lockButton
        )

        return horizontalDirection == .mirrored
            ? layout.mirroredChromeHorizontally(in: viewportWidth)
            : layout
    }

    private static func rightRailWidth(for chromeWidth: Double) -> Double {
        min(max(0, chromeWidth), MonitorSideRailControlLayout.recordButtonSize)
    }

    private static func bottomAssistFrame(
        in region: MonitorLayoutRegion,
        width: Double,
        batteryRail: MonitorModuleFrame,
        safeArea: MonitorEdgeInsets
    ) -> MonitorModuleFrame {
        let defaultFrame = region.place(
            width: width,
            height: region.height,
            anchor: .leading
        )
        guard MonitorBatteryRailLayout.usesClassicSideNotch(safeArea: safeArea) else {
            return defaultFrame
        }

        let defaultRight = defaultFrame.x + defaultFrame.width
        let clearLeft = batteryRail.x + batteryRail.width + bottomModuleSpacing
        let adjustedLeft = min(defaultRight, max(defaultFrame.x, clearLeft))
        return MonitorModuleFrame(
            x: adjustedLeft,
            y: defaultFrame.y,
            width: defaultRight - adjustedLeft,
            height: defaultFrame.height
        )
    }

    private static func rightRailFrame(
        lane: MonitorLayoutRegion,
        chrome: MonitorLayoutRegion,
        railWidth: Double
    ) -> MonitorModuleFrame {
        // Center the rail in the vacant lane between the feed's right edge and the phone edge.
        let chromeLane = MonitorLayoutRegion(
            x: lane.x,
            y: chrome.y,
            width: lane.width,
            height: chrome.height
        )

        if lane.width >= railWidth {
            return chromeLane.place(width: railWidth, height: chrome.height, anchor: .center)
        }

        return chrome.place(width: railWidth, height: chrome.height, anchor: .trailing)
    }

    private static func rightRailLaneCenterLine(
        lane: MonitorLayoutRegion,
        viewportHeight: Double
    ) -> MonitorModuleFrame {
        MonitorModuleFrame(
            x: lane.midX - 0.5,
            y: 0,
            width: 1,
            height: viewportHeight
        )
    }
}

/// Placement for the native monitor side-rail controls.
public struct MonitorSideRailControlLayout: Equatable, Sendable {
    // Control dimensions in points.
    public static let auxiliaryButtonSize = 63.25  // circular settings/media buttons
    public static let recordButtonSize = 82.8  // circular record button
    public static let displayButtonWidth = 73.6
    public static let displayButtonHeight = 43.7

    // Button centers.
    public let settingsCenterX: Double
    public let settingsCenterY: Double
    public let mediaCenterX: Double
    public let mediaCenterY: Double
    public let recordCenterX: Double
    public let recordCenterY: Double
    public let displayCenterX: Double
    public let displayCenterY: Double

    // Derived button edges.
    public var settingsBottom: Double { settingsCenterY + Self.auxiliaryButtonSize / 2 }
    public var mediaTop: Double { mediaCenterY - Self.auxiliaryButtonSize / 2 }
    public var mediaBottom: Double { mediaCenterY + Self.auxiliaryButtonSize / 2 }
    public var recordBottom: Double { recordCenterY + Self.recordButtonSize / 2 }
    public var recordTop: Double { recordCenterY - Self.recordButtonSize / 2 }
    public var displayTop: Double { displayCenterY - Self.displayButtonHeight / 2 }
    public var displayBottom: Double { displayCenterY + Self.displayButtonHeight / 2 }

    /// Top edge of the bottom control bar.
    public let bottomBarTop: Double

    /// Fits side-rail controls to the given rail bounds.
    public static func fit(
        railWidth: Double,
        railHeight: Double,
        bottomBarHeight: Double = 0
    ) -> MonitorSideRailControlLayout {
        let recordCenterX = max(recordButtonSize / 2, railWidth - recordButtonSize / 2)
        let settingsCenterY = auxiliaryButtonSize / 2
        let recordCenterY = railHeight / 2
        let mediaCenterY =
            (settingsCenterY + auxiliaryButtonSize / 2 + recordCenterY - recordButtonSize / 2) / 2
        let bottomBarTop = max(0, railHeight - max(0, bottomBarHeight))
        let displayCenterY = (recordCenterY + recordButtonSize / 2 + bottomBarTop) / 2

        return MonitorSideRailControlLayout(
            settingsCenterX: recordCenterX,
            settingsCenterY: settingsCenterY,
            mediaCenterX: recordCenterX,
            mediaCenterY: mediaCenterY,
            recordCenterX: recordCenterX,
            recordCenterY: recordCenterY,
            displayCenterX: recordCenterX,
            displayCenterY: displayCenterY,
            bottomBarTop: bottomBarTop
        )
    }
}

/// Placement for the native monitor battery indicators around the landscape side notch.
public struct MonitorBatteryRailLayout: Equatable, Sendable {
    /// Battery indicator width in points.
    public static let indicatorWidth = 38.0

    /// Battery indicator height in points (battery glyph + percentage + device icon).
    public static let indicatorHeight = 70.0

    /// Compact phone-battery height used between the lock button and a classic side notch.
    public static let compactPhoneIndicatorHeight = 26.0

    /// Visual separation between the lock button and compact phone-battery readout.
    public static let lockButtonGap = 4.0

    /// Reserved vertical span for the landscape Dynamic Island. The physical black core is about
    /// 126pt tall, so this leaves a narrow safety edge while keeping both battery groups clear of
    /// the neighboring lock and LUT controls.
    public static let sideNotchHeight = 127.0

    /// Reserved vertical span for the wider classic notch used by iPhone 11-era displays.
    public static let classicSideNotchHeight = 232.0

    /// Clearance between the battery indicators and the classic-notch reservation.
    public static let notchPadding = 3.0

    /// Tighter clearance around the Dynamic Island reservation on newer iPhones.
    public static let dynamicIslandPadding = 1.0

    /// Horizontal nudge that aligns the indicators with the Dynamic Island, which sits slightly
    /// inboard of the chrome's leading inset.
    public static let notchAlignmentInsetX = 3.0

    /// Gap between the lock button and the inline battery cluster on width-constrained
    /// (4:3-ish iPad) landscape layouts.
    public static let inlineLeadingGap = 12.0

    /// Nominal frame width for the inline battery cluster (two single-row indicators). The shell's
    /// content hugs the frame's leading edge, so slack here never shifts the indicators.
    public static let inlineClusterWidth = 190.0

    // Indicator centers.
    public let phoneCenterX: Double
    public let phoneCenterY: Double
    public let phoneIndicatorHeight: Double
    public let cameraCenterX: Double
    public let cameraCenterY: Double

    // Side notch reservation edges.
    public let notchTop: Double
    public let notchBottom: Double

    public var phoneTop: Double { phoneCenterY - phoneIndicatorHeight / 2 }
    public var phoneBottom: Double { phoneCenterY + phoneIndicatorHeight / 2 }
    public var cameraTop: Double { cameraCenterY - Self.indicatorHeight / 2 }

    /// Fits the battery indicators to the side rail.
    public static func fit(
        railHeight: Double,
        safeArea: MonitorEdgeInsets = .zero,
        phoneTopClearance: Double = 0
    ) -> MonitorBatteryRailLayout {
        let usesCompactPhoneIndicator = usesClassicSideNotch(safeArea: safeArea)
        let phoneIndicatorHeight =
            usesCompactPhoneIndicator ? compactPhoneIndicatorHeight : indicatorHeight
        let requestedNotchHeight = sideNotchHeight(for: safeArea)
        let padding = notchPadding(for: safeArea)
        let maximumNotchHeight = max(
            0,
            railHeight - phoneIndicatorHeight - indicatorHeight - 2 * padding
        )
        let notchHeight = min(requestedNotchHeight, maximumNotchHeight)
        let notchCenterY = railHeight / 2
        let notchTop = notchCenterY - notchHeight / 2
        let notchBottom = notchCenterY + notchHeight / 2
        let indicatorCenterX = indicatorWidth / 2 - notchAlignmentInsetX
        let minimumPhoneCenterY =
            max(0, phoneTopClearance) + phoneIndicatorHeight / 2
        let minimumCameraCenterY = indicatorHeight / 2
        let maximumCenterY = max(minimumCameraCenterY, railHeight - indicatorHeight / 2)
        let phoneCenterY = max(
            minimumPhoneCenterY,
            notchTop - padding - phoneIndicatorHeight / 2
        )
        let cameraCenterY = min(
            maximumCenterY,
            notchBottom + padding + indicatorHeight / 2
        )

        return MonitorBatteryRailLayout(
            phoneCenterX: indicatorCenterX,
            phoneCenterY: phoneCenterY,
            phoneIndicatorHeight: phoneIndicatorHeight,
            cameraCenterX: indicatorCenterX,
            cameraCenterY: cameraCenterY,
            notchTop: notchTop,
            notchBottom: notchBottom
        )
    }

    private static func sideNotchHeight(for safeArea: MonitorEdgeInsets) -> Double {
        usesClassicSideNotch(safeArea: safeArea) ? classicSideNotchHeight : sideNotchHeight
    }

    private static func notchPadding(for safeArea: MonitorEdgeInsets) -> Double {
        usesClassicSideNotch(safeArea: safeArea) ? notchPadding : dynamicIslandPadding
    }

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

    /// Keeps edge-aligned header controls clear of physical device cutouts.
    public static func header(for safeArea: MonitorEdgeInsets, compact: Bool)
        -> MonitorEdgeInsets
    {
        let contentMargins = content(for: safeArea, compact: compact)

        return MonitorEdgeInsets(
            top: contentMargins.top,
            leading: contentMargins.leading,
            bottom: contentMargins.bottom,
            trailing: contentMargins.trailing
        )
    }

    /// Fraction of viewport height reserved above the startup header in roomier landscape layouts.
    public static let headerTopMarginFraction = 0.08

    /// Fraction of viewport height reserved above the header in compact / height-tight layouts.
    public static let compactHeaderTopMarginFraction = 0.06

    /// Top margin above the startup header: a fraction of viewport height (clamped to a readable
    /// range, stacked on the safe-area top) so the title clears the top edge on every device size.
    public static func headerTopMargin(
        for safeArea: MonitorEdgeInsets,
        viewportHeight: Double,
        compact: Bool
    ) -> Double {
        let fraction = compact ? compactHeaderTopMarginFraction : headerTopMarginFraction
        let minimum = compact ? 20.0 : 24.0
        let maximum = compact ? 48.0 : 64.0
        let proportional = min(maximum, max(minimum, max(0, viewportHeight) * fraction))

        return max(0, safeArea.top) + proportional
    }
}

/// Side cutout reservation for landscape iPhone startup layouts.
public struct StartupSideCutoutAvoidance: Equatable, Sendable {
    /// Minimum side safe-area inset that represents a hardware cutout rather than corner padding.
    public static let minimumCutoutInset = 50.0

    public static let none = StartupSideCutoutAvoidance(leading: 0, trailing: 0)

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

/// Horizontal placement for capped startup content.
public enum StartupContentHorizontalAlignment: Equatable, Sendable {
    case leading
    case center

    /// Uses leading placement when a side cutout exists so corners can remain usable.
    public static func resolve(
        profile: StartupLayoutProfile,
        safeArea: MonitorEdgeInsets
    ) -> StartupContentHorizontalAlignment {
        if StartupSideCutoutAvoidance.resolve(for: safeArea).hasSideCutout {
            return .leading
        }
        return profile == .wideLandscape ? .center : .leading
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

/// Column sizing for the camera-ready startup screen.
public struct StartupReadyContentLayout: Equatable, Sendable {
    /// Preferred fraction for the explanatory intro column.
    public static let introFraction = 0.32

    /// Maximum intro width before the action panel should take the remaining space.
    public static let maximumIntroColumnWidth = 300.0

    /// Smallest readable intro width in two-column mode.
    public static let minimumIntroColumnWidth = 220.0

    public let introColumnWidth: Double
    public let actionColumnWidth: Double
    public let columnSpacing: Double

    public var totalColumnWidth: Double {
        introColumnWidth + columnSpacing + actionColumnWidth
    }

    /// Fits the ready screen using a compact intro and roomier action panel.
    public static func fit(_ contentLayout: StartupContentLayout) -> StartupReadyContentLayout {
        guard contentLayout.mode == .twoColumn else {
            return StartupReadyContentLayout(
                introColumnWidth: contentLayout.contentWidth,
                actionColumnWidth: contentLayout.contentWidth,
                columnSpacing: 0
            )
        }

        let introWidth = min(
            maximumIntroColumnWidth,
            max(minimumIntroColumnWidth, contentLayout.contentWidth * introFraction)
        )
        let actionWidth = max(
            0,
            contentLayout.contentWidth - contentLayout.columnSpacing - introWidth
        )

        return StartupReadyContentLayout(
            introColumnWidth: introWidth,
            actionColumnWidth: actionWidth,
            columnSpacing: contentLayout.columnSpacing
        )
    }
}

/// Sheet sizing policy for editing saved camera presentation metadata.
public struct StartupSavedCameraEditorLayout: Equatable, Sendable {
    /// Approximate minimum content height for the identity editor without scrolling.
    public static let minimumUnscrolledHeight = 620.0

    /// Maximum readable content width for the editor.
    public static let maximumContentWidth = 620.0

    public let detent: StartupSavedCameraEditorDetent
    public let maxContentWidth: Double
    public let horizontalPadding: Double
    public let verticalPadding: Double

    /// Whether editor content must scroll to keep the header and actions reachable.
    public let requiresScrolling: Bool

    /// Fits the editor sheet to the current viewport.
    public static func fit(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets
    ) -> StartupSavedCameraEditorLayout {
        let availableHeight = max(0, viewportHeight - safeArea.top - safeArea.bottom)
        let availableWidth = max(0, viewportWidth - safeArea.leading - safeArea.trailing)
        let compactHeight = availableHeight < minimumUnscrolledHeight
        let horizontalPadding = compactHeight ? 20.0 : 28.0
        let verticalPadding = compactHeight ? 18.0 : 28.0

        return StartupSavedCameraEditorLayout(
            detent: .large,
            maxContentWidth: min(maximumContentWidth, max(0, availableWidth - 40)),
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            requiresScrolling: compactHeight
        )
    }
}

/// Supported saved camera editor detents.
public enum StartupSavedCameraEditorDetent: Equatable, Sendable {
    /// Use the largest sheet height so landscape controls do not clip.
    case large
}

/// Startup ready-screen actions with different visual hierarchy.
public enum StartupReadyAction: Equatable, Sendable {
    case disconnect
    case pairAnother
    case remove
    case liveViewNext
}

/// Visual region where a ready-screen action should be rendered.
public enum StartupReadyActionRegion: Equatable, Sendable {
    case intro
    case cardPrimary
    case cardDestructiveCorner
}

/// Keeps setup actions separate from camera-card actions on the ready screen.
public enum StartupReadyActionPlacementPolicy {
    public static func region(for action: StartupReadyAction) -> StartupReadyActionRegion {
        switch action {
        case .disconnect, .pairAnother:
            return .intro
        case .remove:
            return .cardDestructiveCorner
        case .liveViewNext:
            return .cardPrimary
        }
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

/// Region where the live startup discovery status copy should be rendered.
public enum StartupDiscoveryStatusRegion: Equatable, Sendable {
    /// Below the discovery controls, keeping the intro/footer column stable.
    case controlsFooter
}

/// Keeps long discovery status messages away from the intro/footer stack.
public enum StartupDiscoveryStatusPlacementPolicy {
    public static let region = StartupDiscoveryStatusRegion.controlsFooter
}

/// Geometry for the animated startup discovery radar.
public struct StartupDiscoveryRadarAnimationGeometry: Equatable, Sendable {
    public let centerX: Double
    public let centerY: Double

    /// Radius used by the rotating sweep.
    public let sweepRadius: Double

    /// Diameter of the rotating sweep cone.
    public let sweepDiameter: Double

    /// Fits radar animation geometry inside the supplied bounds.
    public static func fit(width: Double, height: Double) -> StartupDiscoveryRadarAnimationGeometry
    {
        let maximumDiameter = max(0, min(width, height) - 6)
        let sweepRadius = maximumDiameter / 2
        return StartupDiscoveryRadarAnimationGeometry(
            centerX: width / 2,
            centerY: height / 2,
            sweepRadius: sweepRadius,
            sweepDiameter: maximumDiameter
        )
    }
}
