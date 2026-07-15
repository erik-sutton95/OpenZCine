import Testing

@testable import OpenZCineCore

// MARK: - Test helpers (independently re-derive geometry the adapter must match)

/// Smallest axis-aligned rect containing both frames — mirrors the landscape system-cluster
/// union rule without relying on the type under test.
private func union(_ a: MonitorModuleFrame, _ b: MonitorModuleFrame) -> MonitorModuleFrame {
    let minX = Swift.min(a.x, b.x)
    let minY = Swift.min(a.y, b.y)
    let maxX = Swift.max(a.x + a.width, b.x + b.width)
    let maxY = Swift.max(a.y + a.height, b.y + b.height)
    return MonitorModuleFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// Translates a portrait layout region into a module frame (pure field copy).
private func frame(_ region: MonitorLayoutRegion) -> MonitorModuleFrame {
    MonitorModuleFrame(x: region.x, y: region.y, width: region.width, height: region.height)
}

// MARK: - Landscape parity

@Test(arguments: [MonitorHorizontalLayoutDirection.standard, .mirrored])
func landscapeMapMirrorsLegacyForBothDirections(
    direction: MonitorHorizontalLayoutDirection
) {
    let viewportWidth = 874.0
    let viewportHeight = 402.0
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 0)
    // Mirror the real call site: chromeInsets comes from MonitorChromeLayout.insets(feedSafeArea:),
    // which is independent of the feed safe area.
    let chromeInsets = MonitorChromeLayout.insets(feedSafeArea: safeArea)
    let bottomBarHeight = 58.0

    let legacy = MonitorLiveViewModuleLayout.fit(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        feedSafeArea: safeArea,
        chromeInsets: chromeInsets,
        bottomBarHeight: bottomBarHeight,
        horizontalDirection: direction
    )
    let rail = MonitorSideRailControlLayout.fit(
        railWidth: legacy.rightRailControls.width,
        railHeight: legacy.rightRailControls.height,
        bottomBarHeight: bottomBarHeight
    )

    let aux = MonitorSideRailControlLayout.auxiliaryButtonSize
    let rec = MonitorSideRailControlLayout.recordButtonSize
    let dispW = MonitorSideRailControlLayout.displayButtonWidth
    let dispH = MonitorSideRailControlLayout.displayButtonHeight
    let railX = legacy.rightRailControls.x
    let railY = legacy.rightRailControls.y

    // The rail fit hands back centers in the rail's own coordinate space; the shell positions the
    // rail absolutely via rightRailControls.x/.y, so slot frames offset by that origin.
    let expectedSlots = MonitorSystemSlotFrames(
        lock: legacy.lockButton,
        disp: MonitorModuleFrame(
            x: rail.displayCenterX + railX - dispW / 2,
            y: rail.displayCenterY + railY - dispH / 2,
            width: dispW,
            height: dispH
        ),
        record: MonitorModuleFrame(
            x: rail.recordCenterX + railX - rec / 2,
            y: rail.recordCenterY + railY - rec / 2,
            width: rec,
            height: rec
        ),
        media: MonitorModuleFrame(
            x: rail.mediaCenterX + railX - aux / 2,
            y: rail.mediaCenterY + railY - aux / 2,
            width: aux,
            height: aux
        ),
        settings: MonitorModuleFrame(
            x: rail.settingsCenterX + railX - aux / 2,
            y: rail.settingsCenterY + railY - aux / 2,
            width: aux,
            height: aux
        )
    )

    let expectedClusterFrame = union(legacy.lockButton, legacy.rightRailControls)

    // Landscape mode does not flow into the legacy layout policy today, so every mode must yield
    // an identical zone map.
    var mapsByMode: [DispMode: MonitorZoneMap] = [:]
    for mode in DispMode.allCases {
        mapsByMode[mode] = MonitorZoneLayout.map(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            mode: mode,
            isPortrait: false,
            aspect: .fill,
            scopeCount: 0,
            horizontalDirection: direction,
            bottomBarHeight: bottomBarHeight
        )
    }

    #expect(mapsByMode[.live] == mapsByMode[.clean])
    #expect(mapsByMode[.live] == mapsByMode[.command])

    let map = mapsByMode[.live]

    #expect(map?.feed == legacy.feed)

    #expect(map?.infoBar.frame == legacy.topInfoDeck)
    #expect(map?.infoBar.style == .infoPill)
    #expect(map?.infoBar.collapsible == false)

    #expect(map?.captureStrip?.frame == legacy.bottomCaptureSettings)
    #expect(map?.captureStrip?.style == .axisHorizontal)
    #expect(map?.captureStrip?.collapsible == false)

    #expect(map?.assistStrip?.frame == legacy.bottomAssistTools)
    #expect(map?.assistStrip?.style == .axisHorizontal)
    #expect(map?.assistStrip?.collapsible == true)

    #expect(map?.systemCluster.frame == expectedClusterFrame)
    #expect(map?.systemCluster.style == .axisVertical)
    #expect(map?.systemCluster.collapsible == false)
    #expect(map?.systemSlots == expectedSlots)

    #expect(map?.batteryCluster?.frame == legacy.batteryRail)
    #expect(map?.batteryCluster?.style == .batteryRail)
    #expect(map?.batteryCluster?.collapsible == false)

    #expect(map?.scopes == nil)
    #expect(map?.controlsGrid == nil)
    #expect(map?.recOptions == nil)
}

// MARK: - Portrait parity

@Test func portraitMapMirrorsLegacyAcrossAspectScopeMode() {
    let viewportWidth = 390.0
    let viewportHeight = 844.0
    let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    for aspect in [PortraitFeedAspect.fit16x9, .fill] {
        for scopeCount in [0, 1, 2] {
            for mode in DispMode.allCases {
                let legacy = MonitorPortraitLayout.zones(
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight,
                    safeArea: safeArea,
                    mode: mode,
                    aspect: aspect,
                    scopeCount: scopeCount,
                    assistToolbarHeight: 58
                )
                let map = MonitorZoneLayout.map(
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight,
                    safeArea: safeArea,
                    mode: mode,
                    isPortrait: true,
                    aspect: aspect,
                    scopeCount: scopeCount,
                    horizontalDirection: .standard,
                    bottomBarHeight: 58
                )

                // feed + infoBar (topBar overlay)
                #expect(map.feed == legacy.feed)
                #expect(map.infoBar.frame == frame(legacy.topBar))
                #expect(map.infoBar.style == .infoBar)
                #expect(map.infoBar.collapsible == false)

                // controls -> captureStrip (fill, non-clean) or controlsGrid (fit16x9)
                if aspect == .fill {
                    #expect(map.controlsGrid == nil)
                    if mode == .clean {
                        #expect(map.captureStrip == nil)
                    } else {
                        #expect(map.captureStrip?.frame == frame(legacy.controls))
                        #expect(map.captureStrip?.style == .axisHorizontal)
                        #expect(map.captureStrip?.collapsible == false)
                    }
                } else {
                    #expect(map.captureStrip == nil)
                    #expect(map.controlsGrid?.frame == frame(legacy.controls))
                    #expect(map.controlsGrid?.style == .axisHorizontal)
                    #expect(map.controlsGrid?.collapsible == false)
                }

                // scopes only when the region has height
                if legacy.scopes.height > 0 {
                    #expect(map.scopes?.frame == frame(legacy.scopes))
                    #expect(map.scopes?.style == .scopesStacked)
                    #expect(map.scopes?.collapsible == false)
                } else {
                    #expect(map.scopes == nil)
                }

                // systemCluster (systemBar)
                #expect(map.systemCluster.frame == frame(legacy.systemBar))
                #expect(map.systemCluster.style == .axisHorizontal)
                #expect(map.systemCluster.collapsible == false)

                // assistStrip -> only present for fit16x9 + .live when the caller forwards a
                // positive toolbar height (bottomBarHeight: 58 here); nil everywhere else.
                if aspect == .fit16x9, mode == .live {
                    #expect(map.assistStrip?.frame == frame(legacy.assistToolbar))
                    #expect(map.assistStrip?.style == .axisHorizontal)
                    #expect(map.assistStrip?.collapsible == false)
                } else {
                    #expect(map.assistStrip == nil)
                }

                // portrait-only nils
                #expect(map.batteryCluster == nil)
                #expect(map.recOptions == nil)

                // systemBarHeight changed 88 -> 100 for record-button clearance (R4); asserted
                // deliberately rather than regenerated from the policy.
                #expect(map.systemCluster.frame.height == 100)
            }
        }
    }
}

// MARK: - Portrait assist toolbar zone (E1)

@Test func portraitFitLiveAssistToolbarHeightProducesAssistStripBelowScopes() {
    let viewportWidth = 390.0
    let viewportHeight = 844.0
    let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    let map = MonitorZoneLayout.map(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        safeArea: safeArea,
        mode: .live,
        isPortrait: true,
        aspect: .fit16x9,
        scopeCount: 1,
        horizontalDirection: .standard,
        bottomBarHeight: 58
    )

    let scopesMaxY = (map.scopes?.frame.y ?? 0) + (map.scopes?.frame.height ?? 0)
    let assistMaxY = (map.assistStrip?.frame.y ?? 0) + (map.assistStrip?.frame.height ?? 0)

    #expect(map.assistStrip != nil)
    #expect(map.assistStrip?.frame.y == scopesMaxY)
    #expect(map.assistStrip?.frame.height == 58)
    #expect(map.assistStrip?.frame.width == viewportWidth)
    #expect(map.controlsGrid?.frame.y == assistMaxY)
}

@Test func portraitFitLiveZeroAssistToolbarHeightYieldsNilAssistStripAndGridAtScopesBottom() {
    let viewportWidth = 390.0
    let viewportHeight = 844.0
    let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    let map = MonitorZoneLayout.map(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        safeArea: safeArea,
        mode: .live,
        isPortrait: true,
        aspect: .fit16x9,
        scopeCount: 1,
        horizontalDirection: .standard,
        bottomBarHeight: 0
    )

    let scopesMaxY = (map.scopes?.frame.y ?? 0) + (map.scopes?.frame.height ?? 0)

    #expect(map.assistStrip == nil)
    #expect(map.controlsGrid?.frame.y == scopesMaxY)
}

@Test(arguments: [DispMode.clean, .command])
func portraitFitCleanCommandNeverProduceAssistStripRegardlessOfToolbarHeight(mode: DispMode) {
    let viewportWidth = 390.0
    let viewportHeight = 844.0
    let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    for toolbarHeight in [0.0, 58.0] {
        let map = MonitorZoneLayout.map(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            mode: mode,
            isPortrait: true,
            aspect: .fit16x9,
            scopeCount: 1,
            horizontalDirection: .standard,
            bottomBarHeight: toolbarHeight
        )
        #expect(map.assistStrip == nil)
    }
}

@Test(arguments: [DispMode.live, .clean, .command])
func portraitFillNeverProducesAssistStripRegardlessOfToolbarHeight(mode: DispMode) {
    let viewportWidth = 390.0
    let viewportHeight = 844.0
    let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    for toolbarHeight in [0.0, 58.0] {
        let map = MonitorZoneLayout.map(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: safeArea,
            mode: mode,
            isPortrait: true,
            aspect: .fill,
            scopeCount: 1,
            horizontalDirection: .standard,
            bottomBarHeight: toolbarHeight
        )
        #expect(map.assistStrip == nil)
    }
}

@Test func portraitSystemSlotsAreFiveEqualWidthColumnsInLockDispRecordMediaSettingsOrder() {
    let viewportWidth = 390.0
    let viewportHeight = 844.0
    let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

    let legacy = MonitorPortraitLayout.zones(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        safeArea: safeArea,
        mode: .live,
        aspect: .fit16x9,
        scopeCount: 1
    )
    let map = MonitorZoneLayout.map(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        safeArea: safeArea,
        mode: .live,
        isPortrait: true,
        aspect: .fit16x9,
        scopeCount: 1,
        horizontalDirection: .standard,
        bottomBarHeight: 58
    )

    let bar = legacy.systemBar
    let slotWidth = bar.width / 5
    let expected = MonitorSystemSlotFrames(
        lock: MonitorModuleFrame(x: bar.x, y: bar.y, width: slotWidth, height: bar.height),
        disp: MonitorModuleFrame(
            x: bar.x + slotWidth, y: bar.y, width: slotWidth, height: bar.height),
        record: MonitorModuleFrame(
            x: bar.x + 2 * slotWidth, y: bar.y, width: slotWidth, height: bar.height),
        media: MonitorModuleFrame(
            x: bar.x + 3 * slotWidth, y: bar.y, width: slotWidth, height: bar.height),
        settings: MonitorModuleFrame(
            x: bar.x + 4 * slotWidth, y: bar.y, width: slotWidth, height: bar.height)
    )
    #expect(map.systemSlots == expected)
}

// MARK: - Width-constrained (4:3 iPad) landscape corner layout (OPE-2)

/// iPad Pro 11" landscape points with the runtime chrome insets (window-control clearance top).
private enum PadViewport {
    static let width = 1210.0
    static let height = 834.0
    static let safeArea = MonitorEdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
    static let chromeInsets = MonitorEdgeInsets(top: 40, leading: 16, bottom: 12, trailing: 18)

    static func map(bottomBarHeight: Double = 58) -> MonitorZoneMap {
        MonitorZoneLayout.map(
            viewportWidth: width,
            viewportHeight: height,
            safeArea: safeArea,
            chromeInsets: chromeInsets,
            mode: .live,
            isPortrait: false,
            aspect: .fill,
            scopeCount: 0,
            horizontalDirection: .standard,
            bottomBarHeight: bottomBarHeight
        )
    }
}

@Test func widthConstrainedDiscriminatorSelects4x3PadsNotPhones() {
    // iPad Pro 11" landscape: 16:9 at full height (1482.7pt) overflows the 1210pt width.
    #expect(
        MonitorFeedLayout.isWidthConstrained(viewportWidth: 1210, viewportHeight: 834))
    // iPhone 17 Pro landscape is wider than 16:9.
    #expect(
        !MonitorFeedLayout.isWidthConstrained(viewportWidth: 874, viewportHeight: 402))
    // Portrait never constrains (its feed box is handed in as exact 16:9).
    #expect(
        !MonitorFeedLayout.isWidthConstrained(viewportWidth: 834, viewportHeight: 1210))
}

@Test func padLandscapeBatteryClusterIsInlineBesideLock() throws {
    let map = PadViewport.map()
    let lock = map.systemSlots.lock

    #expect(map.batteryCluster?.style == .batteryInline)
    let battery = try #require(map.batteryCluster?.frame)
    // Right of the lock button, in the same top chrome band.
    #expect(battery.x == lock.x + lock.width + MonitorBatteryRailLayout.inlineLeadingGap)
    #expect(battery.midY == lock.midY)
    #expect(battery.height == MonitorLiveViewModuleLayout.lockButtonSize)
}

@Test func padLandscapeSettingsAndMediaFormATopTrailingRowAlignedWithTheInfoBar() {
    let map = PadViewport.map()
    let settings = map.systemSlots.settings
    let media = map.systemSlots.media
    let chromeTrailing = PadViewport.width - PadViewport.chromeInsets.trailing
    let gap = MonitorLiveViewModuleLayout.bottomModuleSpacing

    // Settings hugs the top-trailing chrome corner; media sits inline on its left.
    #expect(settings.x + settings.width == chromeTrailing)
    #expect(media.x + media.width == settings.x - gap)
    // Both are vertically centered on the top info bar band.
    #expect(settings.midY == map.infoBar.frame.midY)
    #expect(media.midY == map.infoBar.frame.midY)
}

@Test func padLandscapeRecordAndDispFormABottomTrailingRowAndTheBarsShorten() throws {
    let map = PadViewport.map()
    let record = map.systemSlots.record
    let disp = map.systemSlots.disp
    let chromeTrailing = PadViewport.width - PadViewport.chromeInsets.trailing
    let gap = MonitorLiveViewModuleLayout.bottomModuleSpacing
    let barBottom = PadViewport.height - MonitorLiveViewModuleLayout.bottomBarBottomInset

    // Record hugs the bottom-trailing chrome corner, bottom-aligned with the bars.
    #expect(record.x + record.width == chromeTrailing)
    #expect(record.y + record.height == barBottom)
    // DISP sits inline on the record button's left, centered on it.
    #expect(disp.x + disp.width == record.x - gap)
    #expect(disp.midY == record.midY)

    // The bottom bars shorten so they end clear of the DISP + record cluster.
    let capture = try #require(map.captureStrip?.frame)
    #expect(capture.x + capture.width <= disp.x - gap + 0.0001)
    // And they still start at the chrome leading edge.
    let assist = try #require(map.assistStrip?.frame)
    #expect(assist.x == PadViewport.chromeInsets.leading)
}

/// iPad mini (A17 Pro) landscape points: 1133×744 ≈ 1.52:1 — still narrower than 16:9, so the
/// constrained corner layout fires, but with far shallower letterbox bands than the Pro 11"
/// (~53pt vs ~77pt), making it the tightest shipping viewport for the corner clusters.
private enum PadMiniViewport {
    static let width = 1133.0
    static let height = 744.0
    static let safeArea = MonitorEdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
    static let chromeInsets = MonitorEdgeInsets(top: 40, leading: 16, bottom: 12, trailing: 18)

    static func map(
        bottomBarHeight: Double = 58,
        direction: MonitorHorizontalLayoutDirection = .standard
    ) -> MonitorZoneMap {
        MonitorZoneLayout.map(
            viewportWidth: width,
            viewportHeight: height,
            safeArea: safeArea,
            chromeInsets: chromeInsets,
            mode: .live,
            isPortrait: false,
            aspect: .fill,
            scopeCount: 0,
            horizontalDirection: direction,
            bottomBarHeight: bottomBarHeight
        )
    }
}

@Test func padMiniLandscapeCornerClustersStayCollisionFreeInShallowLetterbox() throws {
    #expect(
        MonitorFeedLayout.isWidthConstrained(
            viewportWidth: PadMiniViewport.width, viewportHeight: PadMiniViewport.height))

    let map = PadMiniViewport.map()
    let slots = map.systemSlots
    let gap = MonitorLiveViewModuleLayout.bottomModuleSpacing

    // Feed spans the full width, vertically centered.
    #expect(map.feed.x == 0)
    #expect(map.feed.width == PadMiniViewport.width)
    #expect(abs(map.feed.y - (PadMiniViewport.height - map.feed.height) / 2) < 0.0001)

    // Battery cluster sits inline beside the lock, clear of the settings/media corner row.
    #expect(map.batteryCluster?.style == .batteryInline)
    let battery = try #require(map.batteryCluster?.frame)
    #expect(
        battery.x == slots.lock.x + slots.lock.width + MonitorBatteryRailLayout.inlineLeadingGap)
    #expect(battery.x + battery.width <= slots.media.x)

    // The info bar narrows to the free band between the corner clusters, one gap clear of each,
    // so the centered pill can never run under the battery icons or the settings/media row.
    let infoBar = map.infoBar.frame
    #expect(infoBar.x == battery.x + battery.width + gap)
    #expect(infoBar.x + infoBar.width == slots.media.x - gap)
    #expect(infoBar.midY == slots.lock.midY)

    // Shortened bottom bars end clear of the DISP + record corner cluster.
    let capture = try #require(map.captureStrip?.frame)
    #expect(capture.x + capture.width <= slots.disp.x - gap + 0.0001)
    #expect(slots.disp.x + slots.disp.width <= slots.record.x - gap + 0.0001)

    // Record keeps the bars' 14pt bottom clearance and every corner control stays on-screen.
    let barBottom = PadMiniViewport.height - MonitorLiveViewModuleLayout.bottomBarBottomInset
    #expect(slots.record.y + slots.record.height == barBottom)
    for frame in [slots.lock, slots.disp, slots.record, slots.media, slots.settings, battery] {
        #expect(frame.x >= 0)
        #expect(frame.y >= 0)
        #expect(frame.x + frame.width <= PadMiniViewport.width)
        #expect(frame.y + frame.height <= PadMiniViewport.height)
    }
}

@Test func padMiniMirroredInfoBarBandMirrorsWithTheCornerClusters() {
    let standard = PadMiniViewport.map()
    let mirrored = PadMiniViewport.map(direction: .mirrored)

    #expect(
        mirrored.infoBar.frame
            == standard.infoBar.frame.mirroredHorizontally(in: PadMiniViewport.width))
}

@Test func phoneLandscapeBatteryClusterStaysALeadingRail() {
    let map = MonitorZoneLayout.map(
        viewportWidth: 874,
        viewportHeight: 402,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 0),
        mode: .live,
        isPortrait: false,
        aspect: .fill,
        scopeCount: 0,
        horizontalDirection: .standard,
        bottomBarHeight: 58
    )

    #expect(map.batteryCluster?.style == .batteryRail)
    #expect(map.batteryCluster?.frame.width == MonitorBatteryRailLayout.indicatorWidth)
}

@Test func iphone11LandscapeZoneMapKeepsInfoAndAssistBarsClear() throws {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 44)
    let map = MonitorZoneLayout.map(
        viewportWidth: 896,
        viewportHeight: 414,
        safeArea: safeArea,
        mode: .live,
        isPortrait: false,
        aspect: .fill,
        scopeCount: 0,
        horizontalDirection: .standard,
        bottomBarHeight: 58
    )

    let lockRight = map.systemSlots.lock.x + map.systemSlots.lock.width

    #expect(map.feed.x == 54)
    #expect(
        lockRight + MonitorLiveViewModuleLayout.topInfoDeckControlGap
            <= map.infoBar.frame.x)
    #expect(map.infoBar.frame.x + map.infoBar.frame.width <= 896)

    let batteryCluster = try #require(map.batteryCluster?.frame)
    let battery = MonitorBatteryRailLayout.fit(
        railHeight: batteryCluster.height,
        safeArea: safeArea
    )
    let cameraRight =
        batteryCluster.x + battery.cameraCenterX
        + MonitorBatteryRailLayout.indicatorWidth / 2
    #expect(
        cameraRight + MonitorLiveViewModuleLayout.bottomModuleSpacing
            <= (map.assistStrip?.frame.x ?? 0))
}

@Test func landscapeSystemSlotsCenterOnLegacyRailCenters() {
    let viewportWidth = 874.0
    let viewportHeight = 402.0
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 0)
    let chromeInsets = MonitorChromeLayout.insets(feedSafeArea: safeArea)
    let bottomBarHeight = 58.0

    let legacy = MonitorLiveViewModuleLayout.fit(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        feedSafeArea: safeArea,
        chromeInsets: chromeInsets,
        bottomBarHeight: bottomBarHeight,
        horizontalDirection: .standard
    )
    let map = MonitorZoneLayout.map(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        safeArea: safeArea,
        mode: .live,
        isPortrait: false,
        aspect: .fill,
        scopeCount: 0,
        horizontalDirection: .standard,
        bottomBarHeight: bottomBarHeight
    )

    let rail = MonitorSideRailControlLayout.fit(
        railWidth: legacy.rightRailControls.width,
        railHeight: legacy.rightRailControls.height,
        bottomBarHeight: bottomBarHeight
    )
    let aux = MonitorSideRailControlLayout.auxiliaryButtonSize
    let rec = MonitorSideRailControlLayout.recordButtonSize
    let dispW = MonitorSideRailControlLayout.displayButtonWidth
    let dispH = MonitorSideRailControlLayout.displayButtonHeight
    let rx = legacy.rightRailControls.x
    let ry = legacy.rightRailControls.y

    // lock slot is the lock module verbatim.
    #expect(map.systemSlots.lock == legacy.lockButton)

    // disp / record / media / settings centers land on the legacy rail centers, offset to the
    // absolute viewport origin.
    #expect(abs(map.systemSlots.disp.midX - (rail.displayCenterX + rx)) < 0.0001)
    #expect(abs(map.systemSlots.disp.midY - (rail.displayCenterY + ry)) < 0.0001)
    #expect(map.systemSlots.disp.width == dispW && map.systemSlots.disp.height == dispH)

    #expect(abs(map.systemSlots.record.midX - (rail.recordCenterX + rx)) < 0.0001)
    #expect(abs(map.systemSlots.record.midY - (rail.recordCenterY + ry)) < 0.0001)
    #expect(map.systemSlots.record.width == rec && map.systemSlots.record.height == rec)

    #expect(abs(map.systemSlots.media.midX - (rail.mediaCenterX + rx)) < 0.0001)
    #expect(abs(map.systemSlots.media.midY - (rail.mediaCenterY + ry)) < 0.0001)
    #expect(map.systemSlots.media.width == aux && map.systemSlots.media.height == aux)

    #expect(abs(map.systemSlots.settings.midX - (rail.settingsCenterX + rx)) < 0.0001)
    #expect(abs(map.systemSlots.settings.midY - (rail.settingsCenterY + ry)) < 0.0001)
    #expect(map.systemSlots.settings.width == aux && map.systemSlots.settings.height == aux)
}
