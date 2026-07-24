import Testing

@testable import OpenZCineCore

@Test func fitAspectStacksTopBarFeedScopesControlsSystemBar() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 1)
    // Bar tucks topBarLift (8) into the status clearance; the feed starts at its bottom edge.
    #expect(z.topBar.y == 51 && z.topBar.height == 44)
    #expect(z.feed.y == z.topBar.maxY)
    #expect(abs(z.feed.height - 390 * 9 / 16) < 0.5)
    #expect(z.scopes.y >= z.feed.y + z.feed.height)
    #expect(z.scopes.height == 96)
    #expect(z.controls.y >= z.scopes.maxY)
    // Band drops `systemBarBottomLift` (14) into the bottom clearance, still short of the edge.
    #expect(z.systemBar.maxY <= 844 - (34 - 14))
    #expect(z.systemBar.maxY < 844)
    #expect(z.controls.maxY <= z.systemBar.y)
}

// R4 record-button clearance: systemBarHeight grew 88 -> 100. Deliberate, not regenerated.
@Test func systemBarHeightIsHundredForRecordButtonClearance() {
    #expect(MonitorPortraitLayout.systemBarHeight == 100)
}

@Test func fitLiveAssistToolbarSitsBelowScopesAndShrinksControlsWhenPresent() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let withToolbar = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 1, assistToolbarHeight: 58)
    #expect(withToolbar.assistToolbar.y == withToolbar.scopes.maxY)
    #expect(withToolbar.assistToolbar.height == 58)
    #expect(withToolbar.assistToolbar.width == 390)
    #expect(withToolbar.controls.y == withToolbar.assistToolbar.maxY)

    let withoutToolbar = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 1)
    #expect(withoutToolbar.assistToolbar.height == 0)
    #expect(withoutToolbar.controls.y == withoutToolbar.scopes.maxY)
}

@Test(arguments: [DispMode.clean, .command])
func assistToolbarIsZeroHeightInCleanAndCommand(mode: DispMode) {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: mode,
        aspect: .fit16x9, scopeCount: 1, assistToolbarHeight: 58)
    #expect(z.assistToolbar.height == 0)
}

@Test func assistToolbarIsZeroHeightInFillRegardlessOfMode() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    for mode in DispMode.allCases {
        let z = MonitorPortraitLayout.zones(
            viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: mode,
            aspect: .fill, scopeCount: 1, assistToolbarHeight: 58)
        #expect(z.assistToolbar.height == 0)
    }
}

@Test func fitAspectWithoutScopesGivesControlsTheSpace() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let with = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 2)
    let without = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 0)
    #expect(without.scopes.height == 0)
    #expect(with.scopes.height == 192)
    #expect(without.controls.height - with.controls.height == 192)
}

@Test func scopeCountClampsToTwo() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 5)
    #expect(z.scopes.height == 192)
}

@Test func fillAspectFeedIsEdgeToEdgeSpanningToSystemBar() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fill, scopeCount: 1)
    #expect(z.feed.y == z.topBar.maxY)  // below the bar, never overlaid
    // Edge-to-edge: no pillar bars, full viewport width.
    #expect(z.feed.x == 0)
    #expect(z.feed.width == 390)
    // Phone-shaped viewport: span-limited — as tall as bar-bottom→systemBar allows.
    #expect(abs((z.feed.y + z.feed.height) - z.systemBar.y) < 0.5)
    #expect(z.scopes.height == 0)  // fill-mode scopes overlay the feed (shell concern)
    #expect(z.controls.height == 64)
    #expect(abs(z.controls.maxY - (z.feed.y + z.feed.height)) < 0.5)
}

@Test func fillAspectOnTallViewportIsWidthLimitedFullWidth9x16() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 2000, safeArea: sa, mode: .live,
        aspect: .fill, scopeCount: 0)
    #expect(z.feed.width == 390)
    #expect(z.feed.x == 0)
    #expect(abs(z.feed.height - 390 * 16 / 9) < 0.5)
    #expect(z.feed.y + z.feed.height <= z.systemBar.y + 0.5)
}

@Test func cleanCollapsesScopesAndControlsInBothAspects() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    for aspect in [PortraitFeedAspect.fit16x9, .fill] {
        let z = MonitorPortraitLayout.zones(
            viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .clean,
            aspect: aspect, scopeCount: 2)
        #expect(z.scopes.height == 0 && z.controls.height == 0)
        #expect(z.systemBar.maxY <= 844 - (34 - 14))
    }
}

@Test func ultraShortViewportKeepsSystemBarInsideBottomSafeArea() {
    let sa = MonitorEdgeInsets(top: 40, leading: 0, bottom: 20, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 320, viewportHeight: 300, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 0)
    // With bottom inset 20 and a 14 lift, the band reclaims 14 of the clearance but still doesn't
    // reach the physical bottom.
    #expect(z.systemBar.maxY <= 300 - max(0, 20 - 14))
    #expect(z.systemBar.maxY < 300)
    for r in [z.topBar, z.scopes, z.controls, z.systemBar] { #expect(r.height >= 0) }
}

@Test func photographyAspectRatioReshapesFitFeedAndClosesTheBandGap() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    // 3:2 stills feed, no photo-visible scopes, toolbar present — the exact portrait
    // photography stack: feed directly under the top bar, toolbar directly under the feed,
    // tiles from the toolbar down to the system band. No dead band anywhere.
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 0, assistToolbarHeight: 58, feedAspectRatio: 1.5)
    #expect(abs(z.feed.height - 390 / 1.5) < 0.5)
    #expect(abs(z.feed.y - z.topBar.maxY) < 0.5)
    #expect(z.scopes.height == 0)
    #expect(abs(z.assistToolbar.y - (z.feed.y + z.feed.height)) < 0.5)
    #expect(abs(z.controls.y - z.assistToolbar.maxY) < 0.5)
    #expect(abs(z.controls.maxY - z.systemBar.y) < 0.5)
}

@Test func defaultAspectRatioKeepsThe16x9FitFeed() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 0)
    #expect(abs(z.feed.height - 390 * 9 / 16) < 0.5)
}
