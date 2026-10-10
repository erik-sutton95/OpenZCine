import MonitorPresentation
import Testing

@testable import OpenZCineCore

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

@Test func startupContentMarginsDoNotAddHorizontalSafeAreaGutters() {
    let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    let margins = StartupLayoutMargins.content(for: safeArea, compact: false)

    #expect(margins.top == 20)
    #expect(margins.leading == 20)
    #expect(margins.bottom == 39)
    #expect(margins.trailing == 20)
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
