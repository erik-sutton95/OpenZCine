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
    public static func map(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        mode: DispMode,
        isPortrait: Bool,
        aspect: PortraitFeedAspect,
        scopeCount: Int,
        horizontalDirection: MonitorHorizontalLayoutDirection,
        bottomBarHeight: Double
    ) -> MonitorZoneMap {
        if isPortrait {
            return portraitMap(
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                safeArea: safeArea,
                mode: mode,
                aspect: aspect,
                scopeCount: scopeCount,
                assistToolbarHeight: bottomBarHeight
            )
        }
        return landscapeMap(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
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
        horizontalDirection: MonitorHorizontalLayoutDirection,
        bottomBarHeight: Double
    ) -> MonitorZoneMap {
        let chromeInsets = MonitorChromeLayout.insets(feedSafeArea: safeArea)
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

        return MonitorZoneMap(
            feed: legacy.feed,
            infoBar: MonitorZone(frame: legacy.topInfoDeck, style: .infoPill, collapsible: false),
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
            systemSlots: landscapeSlots(legacy: legacy, rail: rail),
            batteryCluster: MonitorZone(
                frame: legacy.batteryRail,
                style: .batteryRail,
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

    // MARK: Portrait

    /// Translates `MonitorPortraitLayout.zones` into a zone map.
    private static func portraitMap(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets,
        mode: DispMode,
        aspect: PortraitFeedAspect,
        scopeCount: Int,
        assistToolbarHeight: Double
    ) -> MonitorZoneMap {
        let legacy = MonitorPortraitLayout.zones(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            mode: mode,
            aspect: aspect,
            scopeCount: scopeCount,
            assistToolbarHeight: assistToolbarHeight
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
