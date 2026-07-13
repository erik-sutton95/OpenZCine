/// Which aspect the portrait feed renders at (operator pinch, persisted).
public enum PortraitFeedAspect: String, Codable, Equatable, Sendable {
    /// Full-width strip; whole image visible (16:9 letterboxed within the portrait width).
    case fit16x9

    /// Fills topBar→systemBar; center-crop zoom.
    case fill
}

/// Zone frames for the portrait monitor layout.
public struct MonitorPortraitZones: Equatable, Sendable {
    /// Top bar region. Sits above the feed (tucked `topBarLift` into the status clearance);
    /// the feed starts at its bottom edge.
    public let topBar: MonitorLayoutRegion

    /// Live camera feed frame.
    public let feed: MonitorFeedFrame

    /// Scopes region. `fit16x9` mode only; height is zero when `scopeCount == 0` or in `.fill`.
    public let scopes: MonitorLayoutRegion

    /// Fit-mode horizontal assist toolbar, directly below the scopes region. Zero height outside
    /// `fit16x9` + `.live`, or when the caller passes a zero `assistToolbarHeight`.
    public let assistToolbar: MonitorLayoutRegion

    /// Controls region: tile area in `fit16x9`, or a capture-bar strip overlaying the feed's
    /// bottom edge in `.fill`.
    public let controls: MonitorLayoutRegion

    /// Bottom system bar region (lock / DISP / record / media / settings band).
    public let systemBar: MonitorLayoutRegion
}

/// Zone geometry policy for the portrait monitor layout.
///
/// Stacks a fixed-height top bar and system bar around a feed whose size depends on
/// `PortraitFeedAspect`, then allocates the remaining space to scopes and controls.
public enum MonitorPortraitLayout {
    /// Height of the top bar.
    public static let topBarHeight = 44.0

    /// How far the top bar tucks up into the status-bar clearance, tightening the gap under the
    /// clock so the feed (which starts at the bar's bottom edge) sits as high as possible.
    public static let topBarLift = 8.0

    /// Height of the bottom system bar. Sized for the record-button's complete clearance: the
    /// 82.8pt record button plus ~8.6pt top/bottom breathing room (R4).
    public static let systemBarHeight = 100.0

    /// How far the system band drops into the bottom safe-area clearance to use the otherwise-empty
    /// space below the controls, while still leaving room for the home indicator.
    public static let systemBarBottomLift = 14.0

    /// Height of one stacked scope in `fit16x9` mode.
    public static let scopeUnitHeight = 96.0

    /// Height of the fill-mode controls strip (capture bar).
    public static let captureBarHeight = 64.0

    /// Height of the fit-mode horizontal assist toolbar (matches the landscape bottom-bar band,
    /// `LiveDesign.controlHeight`).
    public static let assistToolbarHeight = 58.0

    /// Computes portrait monitor zone frames for the given viewport, safe area, display mode,
    /// feed aspect, and scope count.
    ///
    /// `systemBar` is pinned strictly above `safeArea.bottom`; on degenerate (ultra-short)
    /// viewports where the feed alone would exceed the available height, `systemBar` may overlap
    /// the feed instead of breaching the bottom safe area.
    public static func zones(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        mode: DispMode,
        aspect: PortraitFeedAspect,
        scopeCount: Int,
        assistToolbarHeight: Double = 0
    ) -> MonitorPortraitZones {
        let viewportWidth = max(0, viewportWidth)
        let viewportHeight = max(0, viewportHeight)

        let topBar = MonitorLayoutRegion(
            x: 0,
            y: max(0, max(0, safeArea.top) - topBarLift),
            width: viewportWidth,
            height: topBarHeight
        )

        // Sit the band a little lower into the bottom clearance to use the empty space below the
        // controls, while still keeping ~home-indicator clearance. On devices with no bottom inset
        // this reduction floors at 0 (nothing to reclaim).
        let systemBarBottomInset = max(0, max(0, safeArea.bottom) - systemBarBottomLift)
        let systemBar = MonitorLayoutRegion(
            x: 0,
            y: max(0, viewportHeight - systemBarBottomInset - systemBarHeight),
            width: viewportWidth,
            height: systemBarHeight
        )

        switch aspect {
        case .fit16x9:
            // The feed starts at the bar's bottom edge — the bar no longer overlays it.
            let feedHeight = viewportWidth * 9 / 16
            let feed = MonitorFeedFrame(
                x: 0, y: topBar.maxY, width: viewportWidth, height: feedHeight)

            switch mode {
            case .command:
                // Feed is ignored by callers; controls take the full grid area.
                let scopes = MonitorLayoutRegion(
                    x: 0, y: feed.y + feed.height, width: viewportWidth, height: 0)
                let assistToolbar = MonitorLayoutRegion(
                    x: 0, y: scopes.maxY, width: viewportWidth, height: 0)
                let controls = MonitorLayoutRegion(
                    x: 0, y: topBar.maxY, width: viewportWidth,
                    height: max(0, systemBar.y - topBar.maxY))
                return MonitorPortraitZones(
                    topBar: topBar, feed: feed, scopes: scopes, assistToolbar: assistToolbar,
                    controls: controls, systemBar: systemBar)

            case .clean:
                // Clean (DISP 2) hides the scopes/toolbar/tiles, so the 16:9 feed is the only
                // content between the top bar and the system band — centre it vertically in that
                // span instead of leaving it top-aligned with a large empty gap below.
                let cleanSpan = max(0, systemBar.y - topBar.maxY)
                let cleanFeed = MonitorFeedFrame(
                    x: 0, y: topBar.maxY + max(0, (cleanSpan - feedHeight) / 2),
                    width: viewportWidth, height: feedHeight)
                let scopes = MonitorLayoutRegion(
                    x: 0, y: cleanFeed.y + cleanFeed.height, width: viewportWidth, height: 0)
                let assistToolbar = MonitorLayoutRegion(
                    x: 0, y: scopes.maxY, width: viewportWidth, height: 0)
                let controls = MonitorLayoutRegion(
                    x: 0, y: scopes.maxY, width: viewportWidth, height: 0)
                return MonitorPortraitZones(
                    topBar: topBar, feed: cleanFeed, scopes: scopes, assistToolbar: assistToolbar,
                    controls: controls, systemBar: systemBar)

            case .live:
                let clampedScopeCount = min(max(0, scopeCount), 2)
                let scopesHeight = Double(clampedScopeCount) * scopeUnitHeight
                let scopes = MonitorLayoutRegion(
                    x: 0, y: feed.y + feed.height, width: viewportWidth, height: scopesHeight)
                let toolbarHeight = max(0, assistToolbarHeight)
                let assistToolbar = MonitorLayoutRegion(
                    x: 0, y: scopes.maxY, width: viewportWidth, height: toolbarHeight)
                let controls = MonitorLayoutRegion(
                    x: 0, y: assistToolbar.maxY, width: viewportWidth,
                    height: max(0, systemBar.y - assistToolbar.maxY))
                return MonitorPortraitZones(
                    topBar: topBar, feed: feed, scopes: scopes, assistToolbar: assistToolbar,
                    controls: controls, systemBar: systemBar)
            }

        case .fill:
            // Edge-to-edge fill: full viewport width, as much of the bar-bottom→systemBar span as
            // a 16:9-of-width crop allows (the cap keeps tall viewports sane; on phones the span
            // governs). The content aspect-fills (center-crops) within the frame. The operator
            // rejected the earlier true-9:16 frame's pillar bars.
            let span = max(0, systemBar.y - topBar.maxY)
            let feedHeight = min(viewportWidth * 16 / 9, span)
            let feed = MonitorFeedFrame(
                x: 0, y: topBar.maxY, width: viewportWidth, height: feedHeight)

            let scopes = MonitorLayoutRegion(
                x: 0, y: feed.y + feed.height, width: viewportWidth, height: 0)

            // Fill keeps the floating vertical rail; no toolbar zone regardless of the caller's
            // requested height.
            let assistToolbar = MonitorLayoutRegion(
                x: 0, y: scopes.maxY, width: viewportWidth, height: 0)

            let controlsHeight = mode == .clean ? 0 : min(captureBarHeight, feed.height)
            let controls = MonitorLayoutRegion(
                x: 0, y: feed.y + feed.height - controlsHeight, width: viewportWidth,
                height: controlsHeight)

            return MonitorPortraitZones(
                topBar: topBar, feed: feed, scopes: scopes, assistToolbar: assistToolbar,
                controls: controls, systemBar: systemBar)
        }
    }
}
