import CoreGraphics
import Testing

@testable import Runner

/// The level gauge is a HUD instrument: its tracks seat against the VISIBLE feed area (content
/// rect ∩ on-screen bounds), unlike the framing aids that stay pixel-exact with the content even
/// when portrait fill or de-squeeze widen it past the screen.
@Suite("Level gauge seats")
struct LevelGaugeSeatTests {

    @Test("Landscape: fully visible feed seats against the feed itself")
    func landscapeFullyVisible() {
        let feed = CGRect(x: 40, y: 0, width: 800, height: 390)
        let screen = CGRect(x: 0, y: 0, width: 874, height: 402)
        let seats = LevelGaugeView.seats(
            feed: feed, visibleBounds: screen, isPortrait: false, bottomChrome: 0)
        #expect(seats.roll == CGPoint(x: feed.midX, y: feed.maxY - 104))
        #expect(seats.pitch == CGPoint(x: feed.maxX - 44, y: feed.midY))
    }

    @Test("Portrait fit: feed band fully visible, roll hugs the band bottom")
    func portraitFit() {
        let feed = CGRect(x: 0, y: 0, width: 402, height: 226)
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 226)
        let seats = LevelGaugeView.seats(
            feed: feed, visibleBounds: bounds, isPortrait: true, bottomChrome: 0)
        #expect(seats.roll == CGPoint(x: feed.midX, y: feed.maxY - 30))
        #expect(seats.pitch == CGPoint(x: feed.maxX - 44, y: feed.midY))
    }

    @Test("Portrait fill: over-widened content clamps both tracks to the visible rect")
    func portraitFillOverWidened() {
        // Content over-widened to height * 16/9; the visible slice is the screen-width window
        // centred in it (overlay-local coordinates).
        let feed = CGRect(x: 0, y: 0, width: 1000, height: 560)
        let visible = CGRect(x: 299, y: 0, width: 402, height: 560)
        let seats = LevelGaugeView.seats(
            feed: feed, visibleBounds: visible, isPortrait: true, bottomChrome: 64)
        // Pitch track lands inside the visible window, not at the clipped-away content edge.
        #expect(seats.pitch.x == visible.maxX - 44)
        #expect(seats.pitch.y == visible.midY)
        // Roll track centres on the visible window and clears the fill capture strip (64) plus
        // the fit-mode bottom hug (30).
        #expect(seats.roll.x == visible.midX)
        #expect(seats.roll.y == visible.maxY - 94)
    }

    @Test("Portrait fill + de-squeeze: seats stay inside both the image and the screen")
    func portraitFillDesqueezed() {
        // De-squeeze shrinks the over-widened content to a centred sub-rect that can still be
        // wider than the screen; the seat is the intersection of the two.
        let desqueezed = CGRect(x: 125, y: 0, width: 750, height: 560)
        let visible = CGRect(x: 299, y: 0, width: 402, height: 560)
        let seats = LevelGaugeView.seats(
            feed: desqueezed, visibleBounds: visible, isPortrait: true, bottomChrome: 64)
        #expect(seats.pitch.x <= min(desqueezed.maxX, visible.maxX) - 44)
        #expect(seats.pitch.x == visible.maxX - 44)
        #expect(seats.roll.x == visible.midX)
    }

    @Test("Degenerate visible bounds fall back to the feed rect")
    func degenerateVisibleBounds() {
        let feed = CGRect(x: 0, y: 0, width: 800, height: 450)
        let disjoint = CGRect(x: 2000, y: 2000, width: 10, height: 10)
        let seats = LevelGaugeView.seats(
            feed: feed, visibleBounds: disjoint, isPortrait: false, bottomChrome: 0)
        #expect(seats.roll == CGPoint(x: feed.midX, y: feed.maxY - 104))
        #expect(seats.pitch == CGPoint(x: feed.maxX - 44, y: feed.midY))
    }

    @Test("Visible bounds: screen intersection recovers the clip window in overlay-local space")
    func visibleBoundsIntersection() {
        // Portrait fill on a 402pt-wide screen: content 1000pt wide, centred, so its global
        // origin sits 299pt off-screen to the left.
        let contentGlobal = CGRect(x: -299, y: 52, width: 1000, height: 560)
        let visible = FeedAlignedAssists.visibleBounds(
            contentGlobal: contentGlobal,
            size: CGSize(width: 1000, height: 560),
            screen: CGRect(x: 0, y: 0, width: 402, height: 874))
        #expect(visible == CGRect(x: 299, y: 0, width: 402, height: 560))
    }

    @Test("Visible bounds: no scene or a disjoint screen falls back to the full content bounds")
    func visibleBoundsFallback() {
        let size = CGSize(width: 800, height: 450)
        let content = CGRect(origin: .zero, size: size)
        #expect(
            FeedAlignedAssists.visibleBounds(contentGlobal: content, size: size, screen: nil)
                == content)
        #expect(
            FeedAlignedAssists.visibleBounds(
                contentGlobal: CGRect(x: 5000, y: 5000, width: 800, height: 450), size: size,
                screen: CGRect(x: 0, y: 0, width: 402, height: 874))
                == content)
    }
}
