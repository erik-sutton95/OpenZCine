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

@Test func feedLayoutTranslatesClassicNotchFeedTowardTheControlRail() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 44, bottom: 21, trailing: 44)
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 896,
        viewportHeight: 414,
        safeArea: safeArea
    )

    #expect(frame.x == 54)
    #expect(frame.x >= safeArea.leading)
    #expect(frame.x + frame.width <= 896 - safeArea.trailing)

    let mirrored = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 896,
        viewportHeight: 414,
        safeArea: safeArea,
        horizontalDirection: .mirrored
    )
    #expect(mirrored.x == 106)
    #expect(
        mirrored.x + mirrored.width
            == 896 - safeArea.trailing - MonitorFeedLayout.classicNotchRailwardShift)
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

@Test func feedLayoutLetterboxesFullWidthOnNarrowerThanSixteenByNineViewports() {
    // 11" iPad landscape (4:3-ish): the full-height 16:9 frame (1482.7pt) would overflow the
    // 1194pt viewport. With the side-rail chrome relocated into the corners, the letterboxed
    // frame spans the full width, vertically centered.
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 1194,
        viewportHeight: 834,
        safeArea: .zero
    )

    #expect(frame.x == 0)
    #expect(frame.width == 1194)
    #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.001)
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

@Test func startupContentMarginsDoNotAddHorizontalSafeAreaGutters() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let margins = StartupLayoutMargins.content(for: safeArea, compact: false)

    #expect(margins.top == 20)
    #expect(margins.leading == 20)
    #expect(margins.bottom == 39)
    #expect(margins.trailing == 20)
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

// Vertical camera: a rotated (9:16) feed pillarboxes centred in a landscape viewport, and in a
// tall (portrait-zone) viewport it binds to the height instead of overflowing it.
@Test func verticalAspectPillarboxesCenteredInLandscape() {
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 852, viewportHeight: 393,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
        aspect: 9.0 / 16.0, centered: true)
    #expect(frame.height == 393)
    #expect(abs(frame.width - 393 * 9 / 16) < 0.5)
    #expect(abs(frame.x - (852 - 393 * 9.0 / 16) / 2) < 1)
}

// A small overflow (≤15%) fills the WIDTH and centre-crops the sliver — the field case where
// the pillarbox left "few-pixel black bars" that read as a rendering bug. The mount clips the
// negative-y overflow to the band.
@Test func verticalAspectFillsWidthWhenOverflowIsSmall() {
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 390, viewportHeight: 629,
        safeArea: MonitorEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        aspect: 9.0 / 16.0, centered: true)
    // 390 / (9/16) = 693.3 — a 10% overflow, filled and centred.
    #expect(frame.width == 390)
    #expect(frame.x == 0)
    #expect(abs(frame.height - 390 * 16 / 9) < 0.5)
    #expect(abs(frame.y - (629 - 390 * 16.0 / 9) / 2) < 0.5)
}

// A LARGE overflow still pillarboxes: cropping real framing is worse than bars. 9:16 in a very
// short band (>15% overflow) binds to the height.
@Test func verticalAspectStillPillarboxesWhenOverflowIsLarge() {
    let frame = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 390, viewportHeight: 500,
        safeArea: MonitorEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        aspect: 9.0 / 16.0, centered: true)
    #expect(frame.height == 500)
    #expect(abs(frame.width - 500 * 9 / 16) < 0.5)
    #expect(abs(frame.x - (390 - 500 * 9.0 / 16) / 2) < 0.5)
    #expect(frame.y == 0)
}

/// The mirrored feed is the MIRROR of the standard feed — on every phone, not only the classic
/// notch. The island phone's arm ignored the direction, so the picture stayed put while the
/// chrome flipped around it: the capture rail overlaid the feed's left edge and a dead black
/// lane sat inboard of the island (field report, first hardware pass of the second landscape).
@Test func feedLayoutMirrorsOnIslandPhones() {
    // iPhone 16 Pro-class landscape: symmetric 59pt island lanes.
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
    let standard = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 874,
        viewportHeight: 402,
        safeArea: safeArea
    )
    let mirrored = MonitorFeedLayout.fullBleedFrame(
        viewportWidth: 874,
        viewportHeight: 402,
        safeArea: safeArea,
        horizontalDirection: .mirrored
    )

    // Standard clears the leading island; mirrored clears the trailing one.
    #expect(standard.x == 59)
    #expect(mirrored.x == 874 - standard.x - standard.width)
    #expect(mirrored.width == standard.width)
    // The island lane is free on the side that has an island.
    #expect(mirrored.x + mirrored.width <= 874 - 59)
}
