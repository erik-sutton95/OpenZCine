/// Visual style hint for a monitor zone, telling later render tasks how to lay out and skin the
/// region without re-deriving its geometry.
public enum MonitorZoneStyle: Equatable, Sendable {
    case infoPill, infoBar
    case axisHorizontal, axisVertical
    case scopesFloating, scopesStacked
    case batteryRail, batteryInline
}

/// A single normalized monitor region with its style hint and collapse behaviour.
public struct MonitorZone: Equatable, Sendable {
    /// Absolute frame in full-physical-viewport coordinates.
    public let frame: MonitorModuleFrame

    /// Style hint for how the region should be rendered.
    public let style: MonitorZoneStyle

    /// `true` only for the landscape assist strip; `false` everywhere else.
    ///
    /// Descriptive metadata only — no shell reads it. The shell's collapse-pill behaviour comes
    /// from `MonitorAssistStrip`'s `axis` parameter, which doesn't map onto this flag: the
    /// landscape assist zone is `collapsible: true` yet renders as a non-collapsing scroller, and
    /// the portrait vertical rail (the actual collapse pill) isn't a zone the map emits — the
    /// shell places it directly (see `MonitorShell`'s landscape assist mount in
    /// `ios/Runner/MonitorUnified.swift`). Kept because the golden parity tests exercise it;
    /// dropping it would touch every `MonitorZone` call site for no behavioural gain.
    public let collapsible: Bool

    public init(frame: MonitorModuleFrame, style: MonitorZoneStyle, collapsible: Bool) {
        self.frame = frame
        self.style = style
        self.collapsible = collapsible
    }
}

/// Per-slot frames for the five system-bar controls (lock, disp, record, media, settings), in the
/// left-to-right order the portrait system bar renders them and the landscape rail derives them.
public struct MonitorSystemSlotFrames: Equatable, Sendable {
    public let lock: MonitorModuleFrame
    public let disp: MonitorModuleFrame
    public let record: MonitorModuleFrame
    public let media: MonitorModuleFrame
    public let settings: MonitorModuleFrame

    public init(
        lock: MonitorModuleFrame,
        disp: MonitorModuleFrame,
        record: MonitorModuleFrame,
        media: MonitorModuleFrame,
        settings: MonitorModuleFrame
    ) {
        self.lock = lock
        self.disp = disp
        self.record = record
        self.media = media
        self.settings = settings
    }
}

/// Unified monitor zone map. Translates the landscape and portrait layout policies into one shape
/// so downstream render tasks can consume a single representation regardless of orientation.
public struct MonitorZoneMap: Equatable, Sendable {
    public let feed: MonitorFeedFrame

    /// Top information bar (landscape deck pill or portrait full-width bar).
    public let infoBar: MonitorZone

    /// Capture-settings strip. `nil` when tiles own controls (portrait fit) or in clean mode.
    public let captureStrip: MonitorZone?

    /// Assist-tool strip. `nil` in clean/command. In landscape this is the bottom assist band; in
    /// portrait it's the fit-mode horizontal toolbar between the scopes zone and the tile grid,
    /// present only in `fit16x9` + `.live` when the caller passes a positive `bottomBarHeight`
    /// (`nil` in `.fill`, which keeps the floating vertical rail instead).
    public let assistStrip: MonitorZone?

    /// System cluster wrapping the lock / DISP / record / media / settings controls.
    public let systemCluster: MonitorZone

    public let systemSlots: MonitorSystemSlotFrames

    /// Battery cluster. `nil` in portrait (battery is inline in the info bar there).
    public let batteryCluster: MonitorZone?

    /// Scopes zone. `nil` in landscape (scopes float over the feed) and when `scopeCount == 0`.
    public let scopes: MonitorZone?

    /// Controls tile grid. Command mode in both orientations, and portrait fit aspect tiles.
    public let controlsGrid: MonitorZone?

    /// Record options zone. Currently always `nil` — no legacy layout policy produces a
    /// rec-options frame; the shell places the rec-options button itself.
    public let recOptions: MonitorZone?

    public init(
        feed: MonitorFeedFrame,
        infoBar: MonitorZone,
        captureStrip: MonitorZone?,
        assistStrip: MonitorZone?,
        systemCluster: MonitorZone,
        systemSlots: MonitorSystemSlotFrames,
        batteryCluster: MonitorZone?,
        scopes: MonitorZone?,
        controlsGrid: MonitorZone?,
        recOptions: MonitorZone?
    ) {
        self.feed = feed
        self.infoBar = infoBar
        self.captureStrip = captureStrip
        self.assistStrip = assistStrip
        self.systemCluster = systemCluster
        self.systemSlots = systemSlots
        self.batteryCluster = batteryCluster
        self.scopes = scopes
        self.controlsGrid = controlsGrid
        self.recOptions = recOptions
    }
}

/// Pure adapter that normalizes the two existing monitor layout policies — landscape
/// `MonitorLiveViewModuleLayout.fit` / `MonitorSideRailControlLayout.fit` and portrait
/// `MonitorPortraitLayout.zones` — into a single `MonitorZoneMap`. No geometry is re-derived; the
/// legacy static functions are called and their outputs translated and relabeled.
public enum MonitorZoneLayout {
    /// Builds a unified zone map by delegating to the legacy layout policy for the given
    /// orientation.
    ///
    /// `mode`, `aspect`, and `scopeCount` only affect the portrait branch; landscape results are
    /// stable across modes. `bottomBarHeight` and `horizontalDirection` only affect the landscape
    /// branch.
    ///
    /// `chromeInsets` lets the shell pass margins that carry platform exclusions the safe area
    /// does not (the iPadOS 26 window-control pill); `nil` derives them from `safeArea` via
    /// `MonitorChromeLayout.insets`, as before.
    public static func map(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        chromeInsets: MonitorEdgeInsets? = nil,
        mode: DispMode,
        isPortrait: Bool,
        aspect: PortraitFeedAspect,
        scopeCount: Int,
        horizontalDirection: MonitorHorizontalLayoutDirection,
        bottomBarHeight: Double,
        portraitFeedAspectRatio: Double = 16.0 / 9.0
    ) -> MonitorZoneMap {
        if isPortrait {
            return portraitMap(
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                safeArea: safeArea,
                mode: mode,
                aspect: aspect,
                scopeCount: scopeCount,
                assistToolbarHeight: bottomBarHeight,
                feedAspectRatio: portraitFeedAspectRatio
            )
        }
        return landscapeMap(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            chromeInsets: chromeInsets,
            horizontalDirection: horizontalDirection,
            bottomBarHeight: bottomBarHeight
        )
    }

    // MARK: Landscape

    /// Translates `MonitorLiveViewModuleLayout.fit` + `MonitorSideRailControlLayout.fit` into a
    /// zone map. `chromeInsets` mirror the live call site (`MonitorChromeLayout.insets`), which is
    /// independent of the feed safe area.
    private static func landscapeMap(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        chromeInsets: MonitorEdgeInsets? = nil,
        horizontalDirection: MonitorHorizontalLayoutDirection,
        bottomBarHeight: Double
    ) -> MonitorZoneMap {
        let chromeInsets = chromeInsets ?? MonitorChromeLayout.insets(feedSafeArea: safeArea)
        // Width-constrained (4:3-ish iPad) landscape moves the side-rail chrome into the corners;
        // the battery cluster renders as an inline row beside the lock button (`.batteryInline`).
        let constrained = MonitorFeedLayout.isWidthConstrained(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        let legacy = MonitorLiveViewModuleLayout.fit(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            feedSafeArea: safeArea,
            chromeInsets: chromeInsets,
            bottomBarHeight: bottomBarHeight,
            horizontalDirection: horizontalDirection
        )
        let rail = MonitorSideRailControlLayout.fit(
            railWidth: legacy.rightRailControls.width,
            railHeight: legacy.rightRailControls.height,
            bottomBarHeight: bottomBarHeight
        )
        let slots =
            constrained
            ? constrainedLandscapeSlots(
                legacy: legacy,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                chromeInsets: chromeInsets,
                horizontalDirection: horizontalDirection
            )
            : landscapeSlots(legacy: legacy, rail: rail)
        // Constrained layouts fill the top band's corners with chrome (battery inline leading,
        // settings/media trailing), so the info bar narrows to the band between those clusters.
        // The legacy feed-anchored span let the centered pill run under the battery cluster on
        // shallow-letterbox viewports (iPad mini: pill left edge crossed the camera battery icon).
        let infoBarFrame =
            constrained
            ? constrainedInfoBarFrame(legacy: legacy, slots: slots)
            : legacy.topInfoDeck

        return MonitorZoneMap(
            feed: legacy.feed,
            infoBar: MonitorZone(frame: infoBarFrame, style: .infoPill, collapsible: false),
            captureStrip: MonitorZone(
                frame: legacy.bottomCaptureSettings,
                style: .axisHorizontal,
                collapsible: false
            ),
            assistStrip: MonitorZone(
                frame: legacy.bottomAssistTools,
                style: .axisHorizontal,
                collapsible: true
            ),
            systemCluster: MonitorZone(
                frame: union(legacy.lockButton, legacy.rightRailControls),
                style: .axisVertical,
                collapsible: false
            ),
            systemSlots: slots,
            batteryCluster: MonitorZone(
                frame: legacy.batteryRail,
                style: constrained ? .batteryInline : .batteryRail,
                collapsible: false
            ),
            scopes: nil,
            controlsGrid: nil,
            recOptions: nil
        )
    }

    /// Builds the five system slots for landscape: the lock module verbatim, plus rail-centered
    /// disp / record / media / settings frames offset into absolute viewport coordinates.
    private static func landscapeSlots(
        legacy: MonitorLiveViewModuleLayout,
        rail: MonitorSideRailControlLayout
    ) -> MonitorSystemSlotFrames {
        let aux = MonitorSideRailControlLayout.auxiliaryButtonSize
        let rec = MonitorSideRailControlLayout.recordButtonSize
        let dispW = MonitorSideRailControlLayout.displayButtonWidth
        let dispH = MonitorSideRailControlLayout.displayButtonHeight
        let originX = legacy.rightRailControls.x
        let originY = legacy.rightRailControls.y

        return MonitorSystemSlotFrames(
            lock: legacy.lockButton,
            disp: MonitorModuleFrame(
                x: rail.displayCenterX + originX - dispW / 2,
                y: rail.displayCenterY + originY - dispH / 2,
                width: dispW,
                height: dispH
            ),
            record: MonitorModuleFrame(
                x: rail.recordCenterX + originX - rec / 2,
                y: rail.recordCenterY + originY - rec / 2,
                width: rec,
                height: rec
            ),
            media: MonitorModuleFrame(
                x: rail.mediaCenterX + originX - aux / 2,
                y: rail.mediaCenterY + originY - aux / 2,
                width: aux,
                height: aux
            ),
            settings: MonitorModuleFrame(
                x: rail.settingsCenterX + originX - aux / 2,
                y: rail.settingsCenterY + originY - aux / 2,
                width: aux,
                height: aux
            )
        )
    }

    /// Corner slot frames for width-constrained (4:3 iPad) landscape: settings and media form a
    /// horizontal row tucked into the top-trailing chrome corner, vertically centered on the top
    /// info bar band so they read as one line with it (settings outermost, media on its left);
    /// record hugs the bottom-trailing corner (bottom-aligned with the shortened bottom bars)
    /// with DISP inline on its left, vertically centered on the record button. The lock keeps
    /// its legacy top-leading frame. Frames are built in standard orientation and mirrored as a
    /// final step, matching `MonitorLiveViewModuleLayout.mirroredChromeHorizontally`.
    private static func constrainedLandscapeSlots(
        legacy: MonitorLiveViewModuleLayout,
        viewportWidth: Double,
        viewportHeight: Double,
        chromeInsets: MonitorEdgeInsets,
        horizontalDirection: MonitorHorizontalLayoutDirection
    ) -> MonitorSystemSlotFrames {
        let chrome =
            MonitorLayoutRegion
            .viewport(width: viewportWidth, height: viewportHeight)
            .inset(chromeInsets)
        let aux = MonitorSideRailControlLayout.auxiliaryButtonSize
        let gap = MonitorLiveViewModuleLayout.bottomModuleSpacing
        let bandCenterY = chrome.y + MonitorLiveViewModuleLayout.topInfoDeckHeight / 2
        let settings = MonitorModuleFrame(
            x: chrome.maxX - aux,
            y: bandCenterY - aux / 2,
            width: aux,
            height: aux
        )
        let media = MonitorModuleFrame(
            x: settings.x - gap - aux,
            y: bandCenterY - aux / 2,
            width: aux,
            height: aux
        )
        // Bottom-aligned with the bottom bars' shared bottom edge (screen bottom minus the bar
        // inset), keeping home-indicator clearance identical to the bars'.
        let rec = MonitorSideRailControlLayout.recordButtonSize
        let dispWidth = MonitorSideRailControlLayout.displayButtonWidth
        let dispHeight = MonitorSideRailControlLayout.displayButtonHeight
        let recordBottom = viewportHeight - MonitorLiveViewModuleLayout.bottomBarBottomInset
        let record = MonitorModuleFrame(
            x: chrome.maxX - rec,
            y: recordBottom - rec,
            width: rec,
            height: rec
        )
        let disp = MonitorModuleFrame(
            x: record.x - gap - dispWidth,
            y: record.midY - dispHeight / 2,
            width: dispWidth,
            height: dispHeight
        )
        let mirrored = horizontalDirection == .mirrored

        return MonitorSystemSlotFrames(
            // The lock frame off `legacy` is already mirrored when the layout is.
            lock: legacy.lockButton,
            disp: mirrored ? disp.mirroredHorizontally(in: viewportWidth) : disp,
            record: mirrored ? record.mirroredHorizontally(in: viewportWidth) : record,
            media: mirrored ? media.mirroredHorizontally(in: viewportWidth) : media,
            settings: mirrored ? settings.mirroredHorizontally(in: viewportWidth) : settings
        )
    }

    /// Info-bar band for width-constrained (4:3-ish iPad) landscape: the free span between the
    /// inline battery cluster and the settings/media corner row, one module gap clear of each, at
    /// the legacy deck's vertical band. Works in final (possibly mirrored) coordinates — the
    /// battery sits leading and the row trailing in standard orientation, swapped when mirrored —
    /// so the band never needs its own mirror pass.
    private static func constrainedInfoBarFrame(
        legacy: MonitorLiveViewModuleLayout,
        slots: MonitorSystemSlotFrames
    ) -> MonitorModuleFrame {
        let gap = MonitorLiveViewModuleLayout.bottomModuleSpacing
        let battery = legacy.batteryRail
        let rowLeading = Swift.min(slots.media.x, slots.settings.x)
        let rowTrailing = Swift.max(
            slots.media.x + slots.media.width, slots.settings.x + slots.settings.width)
        let left = battery.x < rowLeading ? battery.x + battery.width : rowTrailing
        let right = battery.x < rowLeading ? rowLeading : battery.x

        return MonitorModuleFrame(
            x: left + gap,
            y: legacy.topInfoDeck.y,
            width: Swift.max(0, right - left - 2 * gap),
            height: legacy.topInfoDeck.height
        )
    }

    // MARK: Portrait

    /// Translates `MonitorPortraitLayout.zones` into a zone map.
    private static func portraitMap(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        mode: DispMode,
        aspect: PortraitFeedAspect,
        scopeCount: Int,
        assistToolbarHeight: Double,
        feedAspectRatio: Double = 16.0 / 9.0
    ) -> MonitorZoneMap {
        let legacy = MonitorPortraitLayout.zones(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            mode: mode,
            aspect: aspect,
            scopeCount: scopeCount,
            assistToolbarHeight: assistToolbarHeight,
            feedAspectRatio: feedAspectRatio
        )

        // In `.fill`, the controls region is a capture strip (hidden in clean). In `.fit16x9`, the
        // tiles own their controls so the region becomes a grid instead.
        let captureStrip: MonitorZone?
        let controlsGrid: MonitorZone?
        if aspect == .fill {
            controlsGrid = nil
            // The policy encodes clean-mode suppression as a zero-height controls region;
            // read that rather than re-deriving the mode rule here.
            captureStrip =
                legacy.controls.height > 0
                ? MonitorZone(
                    frame: moduleFrame(legacy.controls),
                    style: .axisHorizontal,
                    collapsible: false
                )
                : nil
        } else {
            captureStrip = nil
            controlsGrid = MonitorZone(
                frame: moduleFrame(legacy.controls),
                style: .axisHorizontal,
                collapsible: false
            )
        }

        let scopes: MonitorZone?
        if legacy.scopes.height > 0 {
            scopes = MonitorZone(
                frame: moduleFrame(legacy.scopes),
                style: .scopesStacked,
                collapsible: false
            )
        } else {
            scopes = nil
        }

        let assistStrip: MonitorZone? =
            legacy.assistToolbar.height > 0
            ? MonitorZone(
                frame: moduleFrame(legacy.assistToolbar), style: .axisHorizontal,
                collapsible: false)
            : nil

        return MonitorZoneMap(
            feed: legacy.feed,
            infoBar: MonitorZone(
                frame: moduleFrame(legacy.topBar),
                style: .infoBar,
                collapsible: false
            ),
            captureStrip: captureStrip,
            assistStrip: assistStrip,
            systemCluster: MonitorZone(
                frame: moduleFrame(legacy.systemBar),
                style: .axisHorizontal,
                collapsible: false
            ),
            systemSlots: portraitSlots(systemBar: legacy.systemBar),
            batteryCluster: nil,
            scopes: scopes,
            controlsGrid: controlsGrid,
            recOptions: nil
        )
    }

    /// Partitions the portrait system bar into five equal-width columns in lock / disp / record /
    /// media / settings order, matching `PortraitSystemBar`'s `HStack(spacing: 0)` with
    /// `.frame(maxWidth: .infinity)` children.
    private static func portraitSlots(systemBar: MonitorLayoutRegion) -> MonitorSystemSlotFrames {
        let slotWidth = systemBar.width / 5
        return MonitorSystemSlotFrames(
            lock: MonitorModuleFrame(
                x: systemBar.x, y: systemBar.y, width: slotWidth, height: systemBar.height),
            disp: MonitorModuleFrame(
                x: systemBar.x + slotWidth, y: systemBar.y, width: slotWidth,
                height: systemBar.height
            ),
            record: MonitorModuleFrame(
                x: systemBar.x + 2 * slotWidth, y: systemBar.y, width: slotWidth,
                height: systemBar.height),
            media: MonitorModuleFrame(
                x: systemBar.x + 3 * slotWidth, y: systemBar.y, width: slotWidth,
                height: systemBar.height),
            settings: MonitorModuleFrame(
                x: systemBar.x + 4 * slotWidth, y: systemBar.y, width: slotWidth,
                height: systemBar.height)
        )
    }

    // MARK: Shared geometry

    /// Smallest axis-aligned rect containing both frames. Used to span the landscape lock module
    /// and right-rail cluster under one system-cluster frame.
    private static func union(
        _ a: MonitorModuleFrame,
        _ b: MonitorModuleFrame
    ) -> MonitorModuleFrame {
        let minX = Swift.min(a.x, b.x)
        let minY = Swift.min(a.y, b.y)
        let maxX = Swift.max(a.x + a.width, b.x + b.width)
        let maxY = Swift.max(a.y + a.height, b.y + b.height)
        return MonitorModuleFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Copies a portrait layout region into a module frame (same coordinate fields).
    private static func moduleFrame(_ region: MonitorLayoutRegion) -> MonitorModuleFrame {
        MonitorModuleFrame(x: region.x, y: region.y, width: region.width, height: region.height)
    }
}
