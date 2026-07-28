import CoreGraphics
import Testing

@testable import Runner

/// The media filter/delivery popups prefer a fixed 400–420pt panel, which does not fit a compact
/// iPhone in portrait. The placement rule must bound the width by the safe viewport *before* it
/// clamps, otherwise the trailing-aligned clamp inverts and shoves the panel off the leading edge
/// (issue #277: on a 393pt phone the title, section labels and left chip column were off-screen).
///
/// This suite is the cheap way to cover the phone/tablet width matrix the issue asks for.
@Suite("Media popup placement")
struct MediaPopupPlacementTests {

    private static let margin = MediaPopupPlacement.margin

    /// Phone logical widths the issue calls out: SE-zoomed, SE/mini, 14/15, 15 Pro (the report),
    /// Pro portrait-zoomed, and Pro Max.
    private static let phoneWidths: [CGFloat] = [320, 375, 390, 393, 402, 430]

    /// A trailing-anchored FILTER pill near the right edge of the header, as the browser lays out.
    private func filterAnchor(hostWidth: CGFloat) -> CGRect {
        CGRect(x: hostWidth - 96, y: 120, width: 76, height: 32)
    }

    private func portraitHost(width: CGFloat, height: CGFloat = 852) -> CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    // MARK: - The reported case

    @Test("iPhone 15 Pro portrait (393×852): the panel sits fully inside the viewport")
    func reportedGeometryFitsEntirely() {
        let host = portraitHost(width: 393)
        let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let place = MediaPopupPlacement.below(
            anchor: filterAnchor(hostWidth: 393),
            host: host,
            safeArea: safeArea,
            preferredWidth: 400,
            minimumHeight: 180
        )

        // The whole point: 400pt cannot fit, so the width gives way — a clamp alone could not.
        #expect(place.width < 400)
        #expect(place.width == 393 - Self.margin * 2)
        // Leading edge on-screen, not the negative offset the report showed.
        #expect(place.x == Self.margin)
        #expect(place.x + place.width == 393 - Self.margin)
        // Below the Dynamic Island, clear of the home indicator.
        #expect(place.y >= 59 + Self.margin)
        #expect(place.y + place.maxHeight <= 852 - 34 - Self.margin)
    }

    // MARK: - Width matrix

    @Test(
        "Every compact phone width keeps the panel inside both edges",
        arguments: phoneWidths
    )
    func phonePortraitWidthsStayInsideBothEdges(width: CGFloat) {
        let host = portraitHost(width: width)
        let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)

        for preferred in [CGFloat(400), 420] {
            let place = MediaPopupPlacement.below(
                anchor: filterAnchor(hostWidth: width),
                host: host,
                safeArea: safeArea,
                preferredWidth: preferred,
                minimumHeight: 180
            )
            #expect(place.width > 0)
            #expect(place.width <= preferred)
            #expect(place.x >= Self.margin)
            #expect(place.x + place.width <= width - Self.margin)
            #expect(place.maxHeight > 0)
            #expect(place.y + place.maxHeight <= 852 - 34 - Self.margin)
        }
    }

    @Test("A roomy viewport keeps the preferred width and stays trailing-aligned to the trigger")
    func roomyViewportKeepsPreferredWidth() {
        // iPad-sized host: 400pt fits with room to spare, so nothing should shrink or re-align.
        let host = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        let anchor = CGRect(x: 800, y: 100, width: 76, height: 32)
        let place = MediaPopupPlacement.below(
            anchor: anchor,
            host: host,
            safeArea: MonitorEdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
            preferredWidth: 400,
            minimumHeight: 180
        )

        #expect(place.width == 400)
        // Trailing edge tracks the trigger button.
        #expect(place.x + place.width == anchor.maxX)
        #expect(place.y == anchor.maxY + 8)
    }

    // MARK: - Landscape (the primary orientation)

    @Test("Landscape phone: the panel clears the notch inset, not just the screen edge")
    func landscapeRespectsHorizontalSafeArea() {
        // 15 Pro landscape-left: the island eats the leading edge.
        let host = CGRect(x: 0, y: 0, width: 852, height: 393)
        let safeArea = MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 0)
        let place = MediaPopupPlacement.below(
            anchor: CGRect(x: 700, y: 60, width: 76, height: 32),
            host: host,
            safeArea: safeArea,
            preferredWidth: 400,
            minimumHeight: 180
        )

        #expect(place.x >= 59 + Self.margin)
        #expect(place.x + place.width <= 852 - Self.margin)
        // Short viewport: the panel is shortened rather than allowed to run under the home bar.
        #expect(place.y + place.maxHeight <= 393 - 21 - Self.margin)
    }

    @Test("A low anchor in a short landscape viewport lifts the panel instead of clipping it")
    func lowAnchorInShortViewportLiftsPanel() {
        let host = CGRect(x: 0, y: 0, width: 852, height: 393)
        // Trigger sits near the bottom: hanging 180pt below it would overflow.
        let anchor = CGRect(x: 700, y: 330, width: 76, height: 32)
        let place = MediaPopupPlacement.below(
            anchor: anchor,
            host: host,
            safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 0),
            preferredWidth: 400,
            minimumHeight: 180
        )

        #expect(place.y < anchor.maxY + 8)
        #expect(place.maxHeight >= 180)
        #expect(place.y + place.maxHeight <= 393 - 21 - Self.margin)
    }

    // MARK: - iPad windowed + stale anchors

    @Test("A narrow iPad window shrinks the panel to fit rather than overflowing")
    func narrowWindowShrinksPanel() {
        // Slide-over-ish width.
        let host = CGRect(x: 0, y: 0, width: 320, height: 1_024)
        let place = MediaPopupPlacement.below(
            anchor: CGRect(x: 224, y: 100, width: 76, height: 32),
            host: host,
            safeArea: MonitorEdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
            preferredWidth: 400,
            minimumHeight: 180
        )

        #expect(place.width == 320 - Self.margin * 2)
        #expect(place.x == Self.margin)
    }

    @Test("An anchor left over from the previous window size cannot push the panel off-screen")
    func staleAnchorIsClampedIntoTheLiveViewport() {
        // Anchor captured while the window was 1024pt wide; the window is now 393pt.
        let staleAnchor = CGRect(x: 928, y: 100, width: 76, height: 32)
        let host = portraitHost(width: 393)
        let place = MediaPopupPlacement.below(
            anchor: staleAnchor,
            host: host,
            safeArea: MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            preferredWidth: 400,
            minimumHeight: 180
        )

        #expect(place.x >= Self.margin)
        #expect(place.x + place.width <= 393 - Self.margin)
    }

    @Test("No anchor yet (first layout pass) still lands inside the viewport")
    func zeroAnchorFallsBackInsideViewport() {
        let host = portraitHost(width: 393)
        let place = MediaPopupPlacement.below(
            anchor: .zero,
            host: host,
            safeArea: MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            preferredWidth: 400,
            minimumHeight: 180
        )

        #expect(place.x >= Self.margin)
        #expect(place.x + place.width <= 393 - Self.margin)
        #expect(place.y >= 59 + Self.margin)
    }

    // MARK: - Non-zero host origin (the overlay is offset inside a larger window)

    @Test("Host-local output: an offset host still yields offsets relative to its own origin")
    func offsetHostReturnsHostLocalCoordinates() {
        let host = CGRect(x: 500, y: 200, width: 393, height: 852)
        let place = MediaPopupPlacement.below(
            anchor: CGRect(x: 500 + 297, y: 200 + 120, width: 76, height: 32),
            host: host,
            safeArea: MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            preferredWidth: 400,
            minimumHeight: 180
        )

        let expectedY: CGFloat = 120 + 32 + 8  // anchor bottom, host-local, plus the 8pt gap
        #expect(place.x == Self.margin)
        #expect(place.y == expectedY)
        #expect(place.x + place.width <= 393 - Self.margin)
    }

    // MARK: - Shared horizontal rule (used by the above-anchor delivery panel)

    @Test("fitted() and below() agree on width and leading edge", arguments: phoneWidths)
    func fittedMatchesBelow(width: CGFloat) {
        let host = portraitHost(width: width)
        let safeArea = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let anchor = filterAnchor(hostWidth: width)

        let fitted = MediaPopupPlacement.fitted(
            anchor: anchor, host: host, safeArea: safeArea, preferredWidth: 420)
        let below = MediaPopupPlacement.below(
            anchor: anchor, host: host, safeArea: safeArea, preferredWidth: 420,
            minimumHeight: 220)

        #expect(fitted.x == below.x)
        #expect(fitted.width == below.width)
    }
}
