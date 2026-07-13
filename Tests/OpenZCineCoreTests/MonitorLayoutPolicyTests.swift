import Testing

@testable import OpenZCineCore

@Test func chromeInsetsUseMinimumMarginsWhenSafeAreaIsEmpty() {
    let insets = MonitorEdgeInsets.chrome(for: .zero)

    #expect(insets.top == 14)
    #expect(insets.leading == 16)
    #expect(insets.bottom == 12)
    #expect(insets.trailing == 18)
}

@Test func chromeInsetsAddSafeAreaOnlyToInteractiveChrome() {
    let safeArea = MonitorEdgeInsets(top: 24, leading: 59, bottom: 21, trailing: 44)
    let insets = MonitorEdgeInsets.chrome(for: safeArea)

    #expect(insets.top == 32)
    #expect(insets.leading == 71)
    #expect(insets.bottom == 29)
    #expect(insets.trailing == 56)
}

@Test func feedLayoutMovesRightToClearLandscapeLeftNotch() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    #expect(MonitorFeedLayout.leadingInset(for: safeArea) == 59)
}

@Test func feedLayoutKeepsLeftEdgeFlushWhenNotchIsTrailing() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 59)

    #expect(MonitorFeedLayout.leadingInset(for: safeArea) == 0)
}

@Test func feedLayoutKeepsLeftEdgeFlushWhenTrailingNotchHasOppositeCornerInset() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 59)

    #expect(MonitorFeedLayout.leadingInset(for: safeArea) == 0)
}

@Test func horizontalLayoutDirectionUsesDeviceOrientationBeforeSafeAreaFallback() {
    let ambiguousSafeArea = MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 44)

    #expect(
        MonitorHorizontalLayoutDirection.resolve(
            deviceOrientation: .landscapeLeft,
            safeArea: ambiguousSafeArea
        ) == .standard
    )
    #expect(
        MonitorHorizontalLayoutDirection.resolve(
            deviceOrientation: .landscapeRight,
            safeArea: ambiguousSafeArea
        ) == .mirrored
    )
    #expect(
        MonitorHorizontalLayoutDirection.resolve(
            deviceOrientation: .unknown,
            safeArea: MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 59)
        ) == .mirrored
    )
}

@Test func feedLayoutFitsPreviewFrameInsideLandscapeLeftSafeArea() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let frame = MonitorFeedLayout.frame(
        viewportWidth: 844,
        viewportHeight: 390,
        safeArea: safeArea
    )

    #expect(frame.x == 59)
    #expect(frame.y == 0)
    #expect(abs(frame.width - 693.333) < 0.001)
    #expect(frame.height == 390)
}

@Test func feedLayoutFitsSixteenByNinePreviewAtTopInPortrait() {
    let frame = MonitorFeedLayout.frame(
        viewportWidth: 390,
        viewportHeight: 844,
        safeArea: MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    )

    #expect(frame.x == 0)
    #expect(frame.y == 0)
    #expect(frame.width == 390)
    #expect(abs(frame.height - 219.375) < 0.001)
}

@Test func feedLayoutKeepsReferenceFrameInsideVisibleLandscapeBounds() {
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 844,
        viewportHeight: 390,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    #expect(frame.x == 59)
    #expect(frame.y == 0)
    #expect(abs(frame.width - 693.333) < 0.001)
    #expect(frame.height == 390)
}

@Test func feedLayoutFitsInsideLandscapeWidthWhenNotchInsetNarrowsAvailableWidth() {
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 760,
        viewportHeight: 390,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    #expect(frame.x == 59)
    #expect(abs(frame.width - 693.333) < 0.001)
    #expect(frame.height == 390)
    #expect(frame.x + frame.width <= 760)
}

@Test func feedLayoutDoesNotMoveWhenChromeMirrorsForLandscapeRight() {
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 760,
        viewportHeight: 390,
        safeArea: MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 59)
    )

    #expect(frame.x == 0)
    #expect(abs(frame.width - 693.333) < 0.001)
    #expect(frame.height == 390)
}

@Test func feedLayoutLetterboxesAndCentersOnNarrowerThanSixteenByNineViewports() {
    // 11" iPad landscape (4:3-ish): the full-height 16:9 frame (1482.7pt) would overflow the
    // 1194pt viewport. Expect a centered letterboxed frame with symmetric rail lanes.
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 1194,
        viewportHeight: 834,
        safeArea: .zero
    )

    let lane = MonitorFeedLayout.constrainedSideLaneWidth
    #expect(abs(frame.x - lane) < 0.001)
    #expect(abs(frame.width - (1194 - 2 * lane)) < 0.001)
    #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.001)
    #expect(frame.x + frame.width <= 1194)
    #expect(abs(frame.y - (834 - frame.height) / 2) < 0.001)
}

@Test func monitorChromeLayoutKeepsControlsStableWhileFeedAvoidsNotch() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let insets = MonitorChromeLayout.insets(feedSafeArea: safeArea)

    #expect(insets.top == 14)
    #expect(insets.leading == 16)
    #expect(insets.bottom == 12)
    #expect(insets.trailing == 18)
}

@Test func layoutRegionInsetsScreenByChromeEdges() {
    let screen = MonitorLayoutRegion.viewport(width: 844, height: 390)
    let region = screen.inset(MonitorEdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 18))

    #expect(region.x == 16)
    #expect(region.y == 14)
    #expect(region.width == 810)
    #expect(region.height == 364)
}

@Test func layoutRegionPlacesFixedSizeFrameByAnchor() {
    let region = MonitorLayoutRegion(x: 100, y: 20, width: 300, height: 200)

    let centered = region.place(width: 60, height: 40, anchor: .center)
    let bottomTrailing = region.place(width: 50, height: 30, anchor: .bottomTrailing)

    #expect(centered.x == 220)
    #expect(centered.y == 100)
    #expect(bottomTrailing.x == 350)
    #expect(bottomTrailing.y == 190)
}

@Test func layoutRegionBuildsTrailingLaneAfterFeedFrame() {
    let screen = MonitorLayoutRegion.viewport(width: 844, height: 390)
    let feed = MonitorFeedFrame(x: 59, y: 0, width: 693.333, height: 390)

    let lane = screen.trailingLane(after: feed)

    #expect(abs(lane.x - 752.333) < 0.001)
    #expect(abs(lane.width - 91.667) < 0.001)
    #expect(lane.y == 0)
    #expect(lane.height == 390)
}

@Test func liveViewViewportRestoresHorizontalSafeAreaExcludedByGeometryReader() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let viewportWidth = MonitorLiveViewViewport.fullWidth(
        layoutWidth: 741,
        safeArea: safeArea
    )

    #expect(viewportWidth == 844)
}

@Test func liveViewViewportUsesSceneWidthWhenGeometryInsetsAreCollapsed() {
    let viewportWidth = MonitorLiveViewViewport.fullWidth(
        layoutWidth: 741,
        safeArea: .zero,
        screenWidth: 844
    )

    #expect(viewportWidth == 844)
}

@Test func liveViewViewportRestoresSafeAreaWhenSceneWidthIsAlsoCollapsed() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let viewportWidth = MonitorLiveViewViewport.fullWidth(
        layoutWidth: 741,
        safeArea: safeArea,
        screenWidth: 741
    )

    #expect(viewportWidth == 844)
}

@Test func liveViewViewportDoesNotDoubleCountSafeAreaWhenGeometryIsAlreadyFullWidth() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let viewportWidth = MonitorLiveViewViewport.fullWidth(
        layoutWidth: 844,
        safeArea: safeArea,
        screenWidth: 844,
        geometrySpace: .fullScreen
    )

    #expect(viewportWidth == 844)
}

@Test func liveViewViewportKeepsRestoredCanvasAtLocalOrigin() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let offsetX = MonitorLiveViewViewport.canvasOffsetX(
        layoutWidth: 741,
        safeArea: safeArea,
        screenWidth: 844
    )

    #expect(offsetX == 0)
}

@Test func liveViewRightRailUsesRestoredViewportToClearFeedFromSafeAreaGeometry() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let viewportWidth = MonitorLiveViewViewport.fullWidth(
        layoutWidth: 741,
        safeArea: safeArea
    )
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: viewportWidth,
        viewportHeight: 390,
        feedSafeArea: safeArea,
        chromeInsets: MonitorChromeLayout.insets(feedSafeArea: safeArea),
        bottomBarHeight: 54
    )
    // The rail centers in the lane carved out by the restored viewport (844), not the collapsed width.
    let feedRight = layout.feed.x + layout.feed.width
    let leftGap = layout.rightRailControls.x - feedRight
    let rightGap = viewportWidth - (layout.rightRailControls.x + layout.rightRailControls.width)

    #expect(feedRight < layout.rightRailControls.x)
    #expect(abs(leftGap - rightGap) < 0.001)
}

@Test func liveViewRightRailUsesRestoredScreenEdgeWhenSceneWidthIsCollapsed() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let viewportWidth = MonitorLiveViewViewport.fullWidth(
        layoutWidth: 741,
        safeArea: safeArea,
        screenWidth: 741,
        geometrySpace: .safeArea
    )
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: viewportWidth,
        viewportHeight: 390,
        feedSafeArea: safeArea,
        chromeInsets: MonitorChromeLayout.insets(feedSafeArea: safeArea),
        bottomBarHeight: 54
    )
    let feedRight = layout.feed.x + layout.feed.width
    let leftGap = layout.rightRailLaneCenterLine.midX - feedRight
    let rightGap = viewportWidth - layout.rightRailLaneCenterLine.midX

    #expect(viewportWidth == 844)
    #expect(abs(leftGap - rightGap) < 0.001)
    #expect(abs(layout.rightRailControls.midX - layout.rightRailLaneCenterLine.midX) < 0.001)
}

@Test func liveViewModuleFramesKeepSharedChromeStableWhileRightRailFollowsFeedLane() {
    let chromeInsets = MonitorChromeLayout.insets(
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )
    let landscapeLeft = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44),
        chromeInsets: chromeInsets,
        bottomBarHeight: 54
    )
    let landscapeRight = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 59),
        chromeInsets: chromeInsets,
        bottomBarHeight: 54
    )

    #expect(landscapeLeft.feed.x == 59)
    #expect(landscapeRight.feed.x == 0)
    #expect(landscapeLeft.feed.height == 390)
    #expect(landscapeLeft.batteryRail == landscapeRight.batteryRail)
    // The top deck floats over the feed, so it tracks the feed's leading edge per orientation.
    #expect(
        landscapeLeft.topInfoDeck.x
            == landscapeLeft.feed.x + MonitorLiveViewModuleLayout.topInfoDeckSideInset)
    #expect(
        landscapeRight.topInfoDeck.x
            == landscapeRight.feed.x + MonitorLiveViewModuleLayout.topInfoDeckSideInset)
    #expect(landscapeLeft.bottomAssistTools == landscapeRight.bottomAssistTools)
    #expect(landscapeLeft.bottomCaptureSettings == landscapeRight.bottomCaptureSettings)
    #expect(landscapeLeft.rightRailControls.x > landscapeLeft.feed.x + landscapeLeft.feed.width)
    #expect(landscapeRight.rightRailControls.x > landscapeRight.feed.x + landscapeRight.feed.width)
}

@Test func liveViewRightRailControlsSitInVacantLaneBesideFeed() {
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44),
        chromeInsets: MonitorChromeLayout.insets(
            feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
        ),
        bottomBarHeight: 54
    )

    let feedRight = layout.feed.x + layout.feed.width
    let leftGap = layout.rightRailControls.x - feedRight
    let rightGap = 844 - (layout.rightRailControls.x + layout.rightRailControls.width)

    #expect(layout.rightRailControls.x > feedRight)
    #expect(abs(leftGap - rightGap) < 0.001)
}

@Test func liveViewRightRailCenterLineMarksVacantLaneMidpoint() {
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44),
        chromeInsets: MonitorChromeLayout.insets(
            feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
        ),
        bottomBarHeight: 54
    )

    let laneMidpoint = (layout.feed.x + layout.feed.width + 844) / 2

    #expect(abs(layout.rightRailLaneCenterLine.midX - laneMidpoint) < 0.001)
    #expect(abs(layout.rightRailControls.midX - layout.rightRailLaneCenterLine.midX) < 0.001)
    #expect(layout.rightRailLaneCenterLine.y == 0)
    #expect(layout.rightRailLaneCenterLine.height == 390)
}

@Test func liveViewModuleFramesMirrorChromeButNotFeedForLandscapeRight() {
    let chromeInsets = MonitorChromeLayout.insets(
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )
    let landscapeLeft = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44),
        chromeInsets: chromeInsets,
        bottomBarHeight: 54
    )
    let landscapeRight = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 59),
        chromeInsets: chromeInsets,
        bottomBarHeight: 54,
        horizontalDirection: .mirrored
    )
    let unmirroredLandscapeRight = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 59),
        chromeInsets: chromeInsets,
        bottomBarHeight: 54,
        horizontalDirection: .standard
    )

    #expect(landscapeRight.feed.x == 0)
    #expect(landscapeRight.feed.width == landscapeLeft.feed.width)
    #expect(landscapeRight.batteryRail.x == 790)
    #expect(
        landscapeRight.rightRailControls
            == unmirroredLandscapeRight.rightRailControls.mirroredHorizontally(in: 844)
    )
    #expect(
        landscapeRight.rightRailLaneCenterLine
            == unmirroredLandscapeRight.rightRailLaneCenterLine.mirroredHorizontally(in: 844)
    )
    #expect(landscapeRight.bottomAssistTools.x == 429)
    #expect(landscapeRight.bottomCaptureSettings.x == 18)
}

@Test func liveViewTopInfoDeckDoesNotDependOnBottomBars() {
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: .zero,
        chromeInsets: MonitorChromeLayout.insets(feedSafeArea: .zero),
        bottomBarHeight: 0
    )

    #expect(layout.topInfoDeck.height == MonitorLiveViewModuleLayout.topInfoDeckHeight)
    #expect(layout.bottomAssistTools.height == 0)
    #expect(layout.bottomCaptureSettings.height == 0)
}

@Test func liveViewTopInfoDeckCentersOverFeed() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: safeArea,
        chromeInsets: MonitorChromeLayout.insets(feedSafeArea: safeArea),
        bottomBarHeight: 54
    )
    let inset = MonitorLiveViewModuleLayout.topInfoDeckSideInset

    #expect(layout.topInfoDeck.x == layout.feed.x + inset)
    #expect(abs(layout.topInfoDeck.width - (layout.feed.width - 2 * inset)) < 0.001)
    // The deck spans the feed minus symmetric insets, so its center is the feed center.
    let deckCenter = layout.topInfoDeck.x + layout.topInfoDeck.width / 2
    let feedCenter = layout.feed.x + layout.feed.width / 2
    #expect(abs(deckCenter - feedCenter) < 0.001)
}

@Test func liveViewLockButtonAlignsWithTopDeckBand() {
    let chromeInsets = MonitorChromeLayout.insets(feedSafeArea: .zero)
    let layout = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: .zero,
        chromeInsets: chromeInsets,
        bottomBarHeight: 54
    )

    #expect(layout.lockButton.width == MonitorLiveViewModuleLayout.lockButtonSize)
    #expect(layout.lockButton.height == MonitorLiveViewModuleLayout.lockButtonSize)
    #expect(layout.lockButton.x == chromeInsets.leading)
    // Vertically centered in the top deck's band so it lines up with the top bar pill.
    #expect(
        layout.lockButton.y + layout.lockButton.height / 2
            == layout.topInfoDeck.y + layout.topInfoDeck.height / 2)
}

@Test func liveViewLockButtonMirrorsToTrailingCornerForLandscapeRight() {
    let chromeInsets = MonitorChromeLayout.insets(feedSafeArea: .zero)
    let standard = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: .zero,
        chromeInsets: chromeInsets,
        bottomBarHeight: 54,
        horizontalDirection: .standard
    )
    let mirrored = MonitorLiveViewModuleLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        feedSafeArea: .zero,
        chromeInsets: chromeInsets,
        bottomBarHeight: 54,
        horizontalDirection: .mirrored
    )

    #expect(mirrored.lockButton == standard.lockButton.mirroredHorizontally(in: 844))
}

@Test func sideRailControlsShareRecordCenterLine() {
    let layout = MonitorSideRailControlLayout.fit(railWidth: 120, railHeight: 390)

    #expect(layout.settingsCenterX == layout.recordCenterX)
    #expect(layout.mediaCenterX == layout.recordCenterX)
    #expect(layout.recordCenterY == 195)
}

@Test func sideRailMediaSplitsVisibleGapBetweenSettingsAndRecord() {
    let layout = MonitorSideRailControlLayout.fit(railWidth: 120, railHeight: 390)

    #expect(
        abs(
            (layout.mediaTop - layout.settingsBottom) - (layout.recordTop - layout.mediaBottom))
            < 0.0001)
}

@Test func sideRailDisplaySplitsVisibleGapBetweenRecordAndBottomBar() {
    let layout = MonitorSideRailControlLayout.fit(
        railWidth: 120,
        railHeight: 390,
        bottomBarHeight: 54
    )

    #expect(
        abs(
            (layout.displayTop - layout.recordBottom) - (layout.bottomBarTop - layout.displayBottom)
        )
            < 0.0001)
}

@Test func batteryRailPlacesIndicatorsAroundSideNotch() {
    let layout = MonitorBatteryRailLayout.fit(railHeight: 390)

    #expect(layout.phoneBottom == layout.notchTop - MonitorBatteryRailLayout.notchPadding)
    #expect(layout.cameraTop == layout.notchBottom + MonitorBatteryRailLayout.notchPadding)
}

@Test func batteryRailKeepsIndicatorsCloserThanCornerAnchors() {
    let layout = MonitorBatteryRailLayout.fit(railHeight: 390)

    #expect(layout.phoneCenterY > MonitorBatteryRailLayout.indicatorHeight / 2)
    #expect(layout.cameraCenterY < 390 - MonitorBatteryRailLayout.indicatorHeight / 2)
}

@Test func startupContentMarginsDoNotAddHorizontalSafeAreaGutters() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let margins = StartupLayoutMargins.content(for: safeArea, compact: false)

    #expect(margins.top == 20)
    #expect(margins.leading == 20)
    #expect(margins.bottom == 39)
    #expect(margins.trailing == 20)
}

@Test func startupHeaderMarginsUseCornersAroundLandscapeSideCutouts() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let margins = StartupLayoutMargins.header(for: safeArea, compact: false)

    #expect(margins.top == 20)
    #expect(margins.leading == 20)
    #expect(margins.bottom == 39)
    #expect(margins.trailing == 20)
}

@Test func startupHeaderTopMarginScalesWithViewportHeight() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let shortMargin = StartupLayoutMargins.headerTopMargin(
        for: safeArea,
        viewportHeight: 390,
        compact: false
    )
    let tallMargin = StartupLayoutMargins.headerTopMargin(
        for: safeArea,
        viewportHeight: 700,
        compact: false
    )

    #expect(shortMargin == 390 * StartupLayoutMargins.headerTopMarginFraction)
    #expect(tallMargin > shortMargin)
    // A percentage margin must be a clear step up from the old fixed 20pt inset.
    #expect(shortMargin > 24)
}

@Test func startupHeaderTopMarginStacksOnSafeAreaAndClamps() {
    let safeArea = MonitorEdgeInsets(top: 30, leading: 0, bottom: 0, trailing: 0)

    // Very tall viewport clamps the proportional band, then the safe-area top is added on.
    let clamped = StartupLayoutMargins.headerTopMargin(
        for: safeArea,
        viewportHeight: 2000,
        compact: false
    )
    #expect(clamped == 30 + 64)

    // Compact keeps a smaller floor so height-tight layouts do not overspend the top band.
    let compactFloor = StartupLayoutMargins.headerTopMargin(
        for: .zero,
        viewportHeight: 100,
        compact: true
    )
    #expect(compactFloor == 20)
}

@Test func startupSideCutoutAvoidanceReservesOnlyTheNotchedSideLane() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let avoidance = StartupSideCutoutAvoidance.resolve(for: safeArea)

    #expect(avoidance.leading == 59)
    #expect(avoidance.trailing == 0)
    #expect(avoidance.hasSideCutout)
}

@Test func startupSideCutoutAvoidanceIgnoresOrdinaryCornerPadding() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24)
    let avoidance = StartupSideCutoutAvoidance.resolve(for: safeArea)

    #expect(avoidance.leading == 0)
    #expect(avoidance.trailing == 0)
    #expect(!avoidance.hasSideCutout)
}

@Test func startupWideContentUsesLeadingAlignmentWhenSideCutoutExists() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)

    let alignment = StartupContentHorizontalAlignment.resolve(
        profile: .wideLandscape,
        safeArea: safeArea
    )

    #expect(alignment == .leading)
}

@Test func startupWideContentCanCenterWhenNoSideCutoutExists() {
    let alignment = StartupContentHorizontalAlignment.resolve(
        profile: .wideLandscape,
        safeArea: MonitorEdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24)
    )

    #expect(alignment == .center)
}

@Test func compactStartupMarginsUseSmallerBasePadding() {
    let safeArea = MonitorEdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0)
    let margins = StartupLayoutMargins.content(for: safeArea, compact: true)

    #expect(margins.top == 30)
    #expect(margins.leading == 16)
    #expect(margins.bottom == 16)
    #expect(margins.trailing == 16)
}

@Test func startupLayoutUsesTwoColumnsOnRegularLandscapePhone() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 956,
        viewportHeight: 440,
        safeArea: .zero
    )

    #expect(layout.profile == .regularLandscape)
    #expect(layout.mode == .twoColumn)
    #expect(layout.availableWidth == 916)
    #expect(layout.contentWidth == 916)
    #expect(layout.introColumnWidth >= 380)
    #expect(layout.actionColumnWidth >= 420)
    #expect(layout.columnSpacing >= 56)
    #expect(layout.totalColumnWidth <= layout.availableWidth)
    #expect(layout.showSecondaryVisuals)
    #expect(layout.showFooterLinks)
}

@Test func startupLayoutUsesTwoColumnsInsideNotchedLandscapeSafeArea() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    #expect(layout.profile == .regularLandscape)
    #expect(layout.mode == .twoColumn)
    #expect(layout.availableWidth == 804)
    #expect(layout.contentWidth == 804)
    #expect(layout.introColumnWidth >= 320)
    #expect(layout.actionColumnWidth >= 340)
    #expect(layout.columnSpacing >= 32)
    #expect(layout.totalColumnWidth <= layout.availableWidth)
    #expect(layout.showSecondaryVisuals)
}

@Test func startupLayoutFallsBackToSingleColumnWhenMinimumColumnsCannotFit() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 740,
        viewportHeight: 360,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    #expect(layout.profile == .compactLandscape)
    #expect(layout.mode == .singleColumn)
    #expect(layout.availableWidth == 700)
    #expect(layout.contentWidth <= layout.availableWidth)
    #expect(layout.introColumnWidth == layout.contentWidth)
    #expect(layout.actionColumnWidth == layout.contentWidth)
    #expect(layout.totalColumnWidth == layout.contentWidth)
}

@Test func startupLayoutCapsWideContentInsteadOfStretchingControls() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 1194,
        viewportHeight: 834,
        safeArea: MonitorEdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24)
    )

    #expect(layout.profile == .wideLandscape)
    #expect(layout.mode == .twoColumn)
    #expect(layout.availableWidth == 1154)
    #expect(layout.contentWidth == 920)
    #expect(layout.totalColumnWidth == layout.contentWidth)
    #expect(layout.actionColumnWidth <= 520)
}

@Test func startupReadyLayoutGivesConnectionPanelMostOfTheWidth() {
    let contentLayout = StartupContentLayout.fit(
        viewportWidth: 956,
        viewportHeight: 440,
        safeArea: .zero
    )

    let readyLayout = StartupReadyContentLayout.fit(contentLayout)

    #expect(readyLayout.introColumnWidth <= contentLayout.contentWidth * 0.34)
    #expect(readyLayout.actionColumnWidth >= contentLayout.contentWidth * 0.58)
    #expect(readyLayout.totalColumnWidth == contentLayout.contentWidth)
}

@Test func startupReadyLayoutUsesFullWidthInSingleColumnMode() {
    let contentLayout = StartupContentLayout.fit(
        viewportWidth: 740,
        viewportHeight: 360,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    let readyLayout = StartupReadyContentLayout.fit(contentLayout)

    #expect(readyLayout.introColumnWidth == contentLayout.contentWidth)
    #expect(readyLayout.actionColumnWidth == contentLayout.contentWidth)
    #expect(readyLayout.columnSpacing == 0)
}

@Test func startupReadyActionsSeparateSetupControlsFromCameraCard() {
    #expect(StartupReadyActionPlacementPolicy.region(for: .disconnect) == .intro)
    #expect(StartupReadyActionPlacementPolicy.region(for: .pairAnother) == .intro)
    #expect(StartupReadyActionPlacementPolicy.region(for: .remove) == .cardDestructiveCorner)
    #expect(StartupReadyActionPlacementPolicy.region(for: .liveViewNext) == .cardPrimary)
}

@Test func startupReadyLiveViewRequiresConnectedIdleSession() {
    #expect(
        StartupReadyLiveViewPolicy.canEnterMonitor(
            isConnected: true,
            hasActiveSession: true,
            isBusy: false
        ))
    #expect(
        !StartupReadyLiveViewPolicy.canEnterMonitor(
            isConnected: false,
            hasActiveSession: true,
            isBusy: false
        ))
    #expect(
        !StartupReadyLiveViewPolicy.canEnterMonitor(
            isConnected: true,
            hasActiveSession: false,
            isBusy: false
        ))
    #expect(
        !StartupReadyLiveViewPolicy.canEnterMonitor(
            isConnected: true,
            hasActiveSession: true,
            isBusy: true
        ))
}

@Test func savedCameraEditorUsesScrollableLargeSheetInLandscapePhoneHeight() {
    let layout = StartupSavedCameraEditorLayout.fit(
        viewportWidth: 956,
        viewportHeight: 440,
        safeArea: .zero
    )

    #expect(layout.requiresScrolling)
    #expect(layout.detent == .large)
    #expect(layout.maxContentWidth <= 620)
    #expect(layout.horizontalPadding <= 22)
}

@Test func startupDiscoveryHidesPrimaryActionWhileAutomaticScanIsEmpty() {
    let action = StartupDiscoveryPrimaryAction.resolve(
        hasSelectedCamera: false,
        isBusy: false,
        isKnownCamera: false
    )

    #expect(action == .none)
    #expect(action.title == nil)
}

@Test func startupDiscoveryShowsPairActionForNeverPairedCamera() {
    let action = StartupDiscoveryPrimaryAction.resolve(
        hasSelectedCamera: true,
        isBusy: false,
        isKnownCamera: false
    )

    #expect(action == .pairCamera(isEnabled: true))
    #expect(action.title == "Pair camera")
}

@Test func startupDiscoveryShowsConnectActionForPreviouslyPairedCamera() {
    let action = StartupDiscoveryPrimaryAction.resolve(
        hasSelectedCamera: true,
        isBusy: false,
        isKnownCamera: true
    )

    #expect(action == .connectCamera(isEnabled: true))
    #expect(action.title == "Connect camera")
}

@Test func startupDiscoveryStatusLivesBelowControls() {
    #expect(StartupDiscoveryStatusPlacementPolicy.region == .controlsFooter)
}

@Test func startupDiscoveryRadarAnimationStaysInsideScopeFrame() {
    let geometry = StartupDiscoveryRadarAnimationGeometry.fit(width: 210, height: 190)

    #expect(geometry.centerX == 105)
    #expect(geometry.centerY == 95)
    #expect(geometry.sweepRadius == 92)
    #expect(geometry.sweepDiameter == 184)
    #expect(geometry.sweepDiameter <= 190)
}
