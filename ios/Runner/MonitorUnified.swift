import SwiftUI

/// Unified top information bar for both monitor shells, selected by `MonitorZoneStyle`.
///
/// `.infoPill` is the landscape deck (readout cells incl. `topBarPickerFrames` anchor publishing
/// and its reset semantics — a regression re-opens the rotation stale-frame bug class). `.infoBar`
/// is the portrait overlay (accent-framed timecode, centered storage, inline battery). Any other
/// style renders nothing.
struct MonitorInfoBar: View {
    var style: MonitorZoneStyle
    /// Pill-only: clean mode strips the deck to status, timecode and FPS. Unused by `.infoBar`.
    var compact: Bool = false

    var body: some View {
        switch style {
        case .infoPill:
            InfoPillContent(compact: compact)
        case .infoBar:
            InfoBarContent()
        default:
            EmptyView()
        }
    }

    // MARK: - .infoPill (former `TopInfoDeckModule`)

    private struct InfoPillContent: View {
        @Environment(NativeAppModel.self) private var model
        var compact: Bool = false

        /// Photography swaps the movie readouts for stills ones in the same pill: the shots
        /// counter takes the timecode slot, image size and quality take resolution and codec.
        private var isPhotography: Bool {
            StillCapturePolicy.prefersPhotographyChrome(
                selector: model.cameraPropertySnapshot.captureSelector)
        }

        var body: some View {
            GlassPanel(
                padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            ) {
                HStack(spacing: 10) {
                    let chrome = model.preferences.displayChrome
                    if isPhotography {
                        ShotsRemainingReadout()
                        if !compact {
                            imageAreaButton
                            if chrome.codecReadoutVisible {
                                readoutButton(
                                    .stillQuality, icon: "camera.aperture",
                                    value: model.cameraPropertySnapshot.stillQualityCompactLabel
                                        ?? "—"
                                )
                                .accessibilityLabel("Image quality")
                            }
                            // No MEDIA cell in photo mode — the SHOTS readout tap-toggles to the
                            // storage form instead.
                        }
                    } else {
                        if chrome.recReadoutVisible {
                            RecordChip(state: model.cameraState.recordState)
                        }
                        TimecodeReadout()
                        if !compact {
                            readoutButton(
                                .resolution, icon: "video",
                                value: model.cameraState.resolutionFrameRate
                            )
                            if chrome.codecReadoutVisible {
                                readoutButton(
                                    .codec, icon: "film",
                                    value: MonitorTextFormat.codecCompactLabel(
                                        model.cameraState.codec))
                            }
                            if chrome.mediaReadoutVisible {
                                mediaCell
                            }
                        }
                    }
                    if chrome.fpsReadoutVisible {
                        FPSChip(fps: model.liveFPS, signalBars: model.liveSignalBars)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        /// The size pill in photo mode: shows "FX · L" and drops the SIZE drum picker down
        /// (Area / Size tabs) exactly like the cinema resolution/codec pills — same anchoring,
        /// same blend/dismiss semantics. The feed frame reshapes with the area selection.
        private var imageAreaButton: some View {
            readoutButton(
                .stillSize, icon: "photo",
                value: model.stillSizeAreaDisplay ?? "—"
            )
            .accessibilityLabel("Image area and size")
        }

        /// Frames left on the card, in the timecode slot's typography — a tap flips it to the
        /// remaining-storage readout (GB + percent), standing in for the MEDIA cell photo mode
        /// drops. Counts above four digits compact to "12.3k" the way camera bodies do.
        private struct ShotsRemainingReadout: View {
            @Environment(NativeAppModel.self) private var model
            var body: some View {
                Button {
                    model.photoPillShowsStorage.toggle()
                } label: {
                    readout
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.zcTapTarget)
                // Pin the cell's geometry so the width change when the readout flips can't
                // relayout the cell out from under an in-flight tap (same trap as the MEDIA cell).
                .geometryGroup()
            }

            private var readout: Text {
                if model.photoPillShowsStorage, let status = model.cameraState.mediaStatus {
                    return Text("\(status.gigabytesFree) GB").foregroundStyle(LiveDesign.text)
                        + Text(" \(status.percentFree)%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiveDesign.muted)
                }
                let remaining = model.cameraPropertySnapshot.shotsRemaining
                return Text(remaining.map(Self.compactCount) ?? "—")
                    .foregroundStyle(LiveDesign.text)
                    + Text(" SHOTS").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiveDesign.muted)
            }

            private static func compactCount(_ count: Int) -> String {
                guard count > 9999 else { return String(count) }
                return String(format: "%.1fk", Double(count) / 1000)
            }
        }

        /// Timecode with the frame field tinted, isolated into its own leaf `View` so the ~30 Hz
        /// tick invalidates only this text, not the whole pill body. The leaf must read the model
        /// from `@Environment` (not a passed-in snapshot) or it stops observing timecode updates.
        private struct TimecodeReadout: View {
            @Environment(NativeAppModel.self) private var model
            var body: some View {
                let tc = model.liveTimecode
                let main = String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second)
                let frames = String(format: ":%02d", tc.frame)
                return
                    (Text(main).foregroundStyle(LiveDesign.text)
                    + Text(frames).foregroundStyle(LiveDesign.accent))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }

        /// A glyph followed inline by its value in its own glass pill. When its popdown is open the
        /// pill takes the *same* active treatment as a bottom-bar setting (dim-accent fill, hairline
        /// border, gold text) so the two bars highlight identically.
        @ViewBuilder
        private func inlineReadout(icon: String, value: String, isActive: Bool = false) -> some View
        {
            let content =
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.muted)
                    Text(value.replacingOccurrences(of: " · ", with: "·"))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // Top-bar readout pills stay one line; deck compression must
                // shrink type, never stack characters.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if isActive {
                content
                    .background(Capsule().fill(LiveDesign.accentDim))
                    .overlay(Capsule().strokeBorder(LiveDesign.accentDim, lineWidth: 1))
            } else {
                content.liquidGlass(in: Capsule())
            }
        }

        /// A top-deck readout that drops its drum picker down when tapped. Mirrors the bottom-bar
        /// `CaptureSettingButton`: open, dismiss, or blend depending on which picker is up.
        @ViewBuilder
        private func readoutButton(
            _ picker: CameraPicker, icon: String, value: String
        ) -> some View {
            let isActive = model.activePanel == .picker(picker)
            Button {
                if model.activePanel == nil {
                    model.showPicker(picker)
                } else if model.activePanel == .picker(picker) {
                    model.dismissActivePanel()
                } else {
                    model.switchPicker(to: picker)
                }
            } label: {
                inlineReadout(icon: icon, value: value, isActive: isActive)
            }
            .buttonStyle(.zcTapTarget)
            .geometryGroup()
            // Publish the cell's global frame continuously so its drop-down picker anchors just
            // beneath it and a backdrop tap on the cell can blend/dismiss like the bottom bar.
            .background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { model.topBarPickerFrames[picker] = frame }
                        .onChange(of: frame) { _, newFrame in
                            model.topBarPickerFrames[picker] = newFrame
                        }
                        // Rotation to portrait unmounts this cell; drop its entry so a stale
                        // landscape frame can't satisfy topPickerBody's hasCell check or
                        // handleBackdropTap's hit-test.
                        .onDisappear { model.topBarPickerFrames[picker] = nil }
                }
            )
        }

        /// The MEDIA cell: tap cycles capacity ↔ duration. No popover. `.contentShape` makes the
        /// whole pill a hit target; `.geometryGroup()` pins the cell's geometry so the width change
        /// when the readout flips (`521 GB·47%` → `47 Min`) can't relayout the cell out from under
        /// an in-flight tap and swallow it.
        private var mediaCell: some View {
            Button {
                model.toggleMediaReadout()
            } label: {
                inlineReadout(icon: "sdcard", value: model.mediaReadout)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.zcTapTarget)
            .geometryGroup()
        }
    }

    // MARK: - .infoBar (former `PortraitTopBar`)

    private struct InfoBarContent: View {
        @Environment(NativeAppModel.self) private var model

        var body: some View {
            ZStack {
                // Storage/minutes centered on the SCREEN, not the leftover space (spec §1): a bare
                // Text in the ZStack centers within the full bar width regardless of siblings.
                Text(model.mediaReadout)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
                    .lineLimit(1)

                HStack {
                    // Must read `liveTimecode` (not `cameraState.timecode`) — per-frame telemetry
                    // is held separately so the HUD struct is not invalidated every tick.
                    // A nested leaf observes that property so only this text re-renders.
                    PortraitInfoBarTimecode()

                    Spacer(minLength: 8)

                    cameraBattery
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .background(LiveDesign.glass)
        }

        // The landscape rail's `BatteryIndicator` in its `.inline` layout (R2): same
        // symbol/readout/charging logic, one row, sized for the 44pt top bar natively.
        private var cameraBattery: some View {
            BatteryIndicator(
                percent: model.cameraState.cameraBatteryPercent,
                deviceSystemName: "camera",
                isCamera: true,
                isCharging: model.cameraBatteryCharging,
                layout: .inline
            )
        }
    }

    /// Portrait top-bar timecode leaf — same source as landscape (`liveTimecode`), isolated so
    /// the ~30 Hz tick does not invalidate the whole info bar.
    private struct PortraitInfoBarTimecode: View {
        @Environment(NativeAppModel.self) private var model

        var body: some View {
            let tc = model.liveTimecode
            return
                (Text(String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second))
                .foregroundStyle(LiveDesign.text)
                + Text(String(format: ":%02d", tc.frame))
                .foregroundStyle(LiveDesign.accent))
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .lineLimit(1)
        }
    }
}

/// Portrait command-mode (DISP 3) hero timecode above the tile grid, frame field tinted accent.
/// Its own leaf view reading `liveTimecode` from `@Environment` so the ~30 Hz tick invalidates
/// only this text, not the tile grid. Oversized nominal font + `minimumScaleFactor` fits the width.
private struct PortraitCommandTimecode: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        let tc = model.liveTimecode
        return
            (Text(String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second))
            .foregroundStyle(LiveDesign.text)
            + Text(String(format: ":%02d", tc.frame))
            .foregroundStyle(LiveDesign.accent))
            .font(.system(size: 96, weight: .regular, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.2)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Unified capture-settings strip for both monitor shells: a row of `CaptureSettingButton`s
/// (ISO / SHUTTER / IRIS / FOCUS / WB).
///
/// Landscape (`fitsWidth: true`) content-hugs — the wide rail always has room for all five
/// readouts. Portrait fill mode (`fitsWidth: false`) scales the same cells to span the bar width.
/// Both publish `captureBarFrame` (the exposure picker anchors to it) with identical
/// onAppear/onChange/onDisappear reset semantics; regressing that reopens the rotation
/// stale-frame bug class (the bar unmounts on rotation and a lingering frame would mislead
/// `bottomPickerBody`'s hasBar / `handleBackdropTap`'s hit-test in the now-hidden shell).
struct MonitorCaptureStrip: View {
    @Environment(NativeAppModel.self) private var model
    /// True for the landscape rail (content-hugging, room for every readout); false for the
    /// portrait fill-mode bar (fits all five to the width by scaling the cells).
    var fitsWidth: Bool
    /// Portrait-only: the row's natural (scale-1) width, measured off-screen so the fitted row
    /// can derive its scale on any device width.
    @State private var naturalRowWidth: CGFloat = 0

    var body: some View {
        if fitsWidth {
            landscapeBody
        } else {
            portraitBody
        }
    }

    /// The stills tiles own the whole band (assist lives on the left rail), so they run
    /// at the cinema scale; the fitted GeometryReader row stays portrait-only because the
    /// shell sizes this side with `fixedSize`.
    private var landscapeTileScale: CGFloat { 1 }

    /// True while the body reports photo mode — the strip then renders the stills readouts
    /// through the exact same bar, tiles and typography as the cinema settings.
    private var isPhotography: Bool {
        StillCapturePolicy.prefersPhotographyChrome(
            selector: model.cameraPropertySnapshot.captureSelector)
    }

    private var stripValues: [CameraValue] {
        isPhotography
            ? model.cameraPropertySnapshot.photographyCaptureValues
            : model.cameraState.values
    }

    // MARK: - fitsWidth: true (former `BottomCaptureSettingsModule`)

    private var landscapeBody: some View {
        GlassPanel(
            padding: EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        ) {
            HStack(spacing: 8) {
                ForEach(stripValues) { item in
                    CaptureSettingButton(value: item, scale: landscapeTileScale)
                }
            }
            // Fill the bar height so both bottom bars render at the same height (GlassPanel
            // otherwise hugs its content, leaving this pill shorter or taller than the toolbar).
            .frame(maxHeight: .infinity)
        }
        // Report the whole bar's global frame; the exposure picker right-aligns to it.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.captureBarFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        model.captureBarFrame = frame
                    }
                    // Rotating to portrait unmounts this whole landscape-chrome branch. Without
                    // this the bar's last landscape frame lingers and every portrait consumer that
                    // trusts "width > 1" as "the bar exists" anchors off-screen. Clearing here heals
                    // all of them (bottomPickerBody's hasBar, handleBackdropTap's hit-test) at once.
                    .onDisappear { model.captureBarFrame = .zero }
            }
        )
        // Make the whole bar (gaps and glass padding included) swallow taps so they don't fall
        // through to the live feed's display-mode toggle behind it. The setting buttons are nested
        // children, so they still receive their own taps.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: - fitsWidth: false (portrait fill bar — fits the width by scaling, never scrolls)

    /// Base inter-cell spacing at scale 1 (matches the landscape row).
    private static let baseSpacing: CGFloat = 8
    /// Smallest inter-cell gap the fitted row may compress to.
    private static let minSpacing: CGFloat = 4
    /// Cells never render above their landscape (scale-1) size — the vertical cap. On wide
    /// screens (Pro Max, iPad) the leftover width grows the spacing instead.
    private static let maxScale: CGFloat = 1
    /// Legibility floor; below this the tail cells may clip (unreachable on supported phones).
    private static let minScale: CGFloat = 0.5

    private var portraitBody: some View {
        GlassPanel(
            padding: EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        ) {
            fittedRow
                .frame(maxHeight: .infinity)
        }
        // Report the bar's global frame; the exposure picker right-aligns to it (same as landscape).
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.captureBarFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        model.captureBarFrame = frame
                    }
                    .onDisappear { model.captureBarFrame = .zero }
            }
        )
        // Swallow taps in the gaps so they don't fall through to the feed's tap-to-focus behind.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    /// The five settings, scaled so the row spans the bar edge-to-edge on any device width:
    /// scale = what makes cells + minimum gaps fill the width, capped at scale 1 (the vertical
    /// max) — past the cap the leftover width becomes spacing (Pro Max, iPad). The natural
    /// scale-1 row is measured hidden so the math holds for any cell set or future widths.
    private var fittedRow: some View {
        GeometryReader { proxy in
            let values = stripValues
            let n = CGFloat(max(1, values.count))
            let gaps = n - 1
            let cellsNatural = max(1, naturalRowWidth - Self.baseSpacing * gaps)
            let fitScale = (proxy.size.width - Self.minSpacing * gaps) / cellsNatural
            let scale = min(Self.maxScale, max(Self.minScale, fitScale))
            let spacing =
                gaps > 0
                ? max(Self.minSpacing, (proxy.size.width - cellsNatural * scale) / gaps)
                : 0
            HStack(spacing: spacing) {
                ForEach(values) { item in
                    CaptureSettingButton(value: item, scale: scale)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .opacity(naturalRowWidth > 0 ? 1 : 0)  // one measurement pass before first paint
        }
        .background(naturalRowMeasurer)
    }

    /// Off-screen scale-1 row whose width feeds `fittedRow`'s math. Hidden and non-interactive.
    private var naturalRowMeasurer: some View {
        HStack(spacing: Self.baseSpacing) {
            ForEach(stripValues) { item in
                CaptureSettingButton(value: item)
            }
        }
        .fixedSize()
        .hidden()
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            naturalRowWidth = width
        }
    }
}

/// Unified assist-tools strip for both monitor shells: a sequence of `AssistToolButtonRow`s.
///
/// `axis: .horizontal, collapsible: false` is the landscape bottom toolbar — a horizontal scroller
/// with gold edge chevrons, grouped into threes by a divider, publishing `assistToolbarFrame` so
/// assist popups right-align to it. `axis: .vertical, collapsible: true` is the portrait rail — a
/// collapsed circular pill expanding into a full-feed-height vertical scroller with a bottom fade.
/// `AssistToolButtonRow` is shared unforked; it owns the tap/long-press gestures and haptics.
struct MonitorAssistStrip: View {
    @Environment(NativeAppModel.self) private var model
    var axis: Axis
    /// Documents intent at call sites; `collapsible` always co-varies with `axis` today
    /// (horizontal → false, vertical → true), so the body branches on `axis` alone.
    var collapsible: Bool
    /// Horizontal-only: packs the default tool set into the reduced classic-notch lane.
    var compactHorizontal: Bool
    /// Vertical-only: height of the feed zone the rail should span when expanded.
    var feedHeight: CGFloat = 0
    /// Vertical-only: expand/collapse state, owned by the parent (`MonitorShell` sizes around it).
    @Binding var expanded: Bool
    /// Horizontal-only: which edges fade out to signal more to scroll that way. Defaults to the
    /// resting right-only fade (toolbar scrolled to its start).
    @State private var edgeFades = ScrollEdgeFades(leading: false, trailing: true)

    init(
        axis: Axis, collapsible: Bool, compactHorizontal: Bool = false, feedHeight: CGFloat = 0,
        expanded: Binding<Bool> = .constant(false)
    ) {
        self.axis = axis
        self.collapsible = collapsible
        self.compactHorizontal = compactHorizontal
        self.feedHeight = feedHeight
        self._expanded = expanded
    }

    var body: some View {
        if axis == .horizontal {
            horizontalBody
        } else {
            verticalBody
        }
    }

    // MARK: - axis: .horizontal, collapsible: false (former `BottomAssistToolsModule`)

    private var horizontalBody: some View {
        GlassPanel(
            padding: EdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 14)
        ) {
            scroller
                .mask(edgeFades.gradient)
                // Fill the bar height so the glass matches the capture pill; GlassPanel hugs its
                // content, so the row-height frame alone would only centre a short panel.
                .frame(maxHeight: .infinity)
        }
        // Gold chevrons at each edge when there are more tools to scroll that way (mockup `.tb-chev`).
        .overlay(alignment: .leading) { scrollChevron(.leading) }
        .overlay(alignment: .trailing) { scrollChevron(.trailing) }
        .animation(.easeInOut(duration: 0.18), value: edgeFades)
        // Report the toolbar's global frame; assist popups right-align to its trailing edge.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.assistToolbarFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        model.assistToolbarFrame = frame
                    }
                    // See MonitorCaptureStrip's matching reset: this landscape-only view unmounts
                    // on rotation to portrait, so clear the frame rather than let it go stale for
                    // AssistOptionsPopupAnchor's hasToolbar check.
                    .onDisappear { model.assistToolbarFrame = .zero }
            }
        }
    }

    /// A small accent chevron hinting at off-screen tools; fades in only when that edge can scroll.
    private func scrollChevron(_ edge: HorizontalEdge) -> some View {
        Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LiveDesign.accent)
            .shadow(color: .black.opacity(0.65), radius: 4)
            .padding(.horizontal, 5)
            .opacity((edge == .leading ? edgeFades.leading : edgeFades.trailing) ? 1 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var scroller: some View {
        if #available(iOS 18.0, *) {
            toolScroll
                .onScrollGeometryChange(for: ScrollEdgeFades.self) { geometry in
                    // The reported content width carries ~21px of slack (the panel's leading +
                    // trailing padding), so the last tool sits flush while ~23px of "scroll" still
                    // remains. Use a wide trailing tolerance so the chevron clears at the real end;
                    // the leading edge has no such slack, so a tiny tolerance suffices there.
                    let remaining =
                        geometry.contentSize.width - geometry.containerSize.width
                        - geometry.contentOffset.x
                    return ScrollEdgeFades(
                        leading: geometry.contentOffset.x > 6,
                        trailing: remaining > 28
                    )
                } action: { _, fades in
                    edgeFades = fades
                }
        } else {
            // Older systems can't observe scroll geometry cheaply; fade both edges constantly.
            toolScroll
                .onAppear { edgeFades = ScrollEdgeFades(leading: true, trailing: true) }
        }
    }

    private var toolScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            toolRow
                .fixedSize(horizontal: true, vertical: false)
        }
        // Size to visible tools when short; accept parent width cap and scroll when tools overflow.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var toolRow: some View {
        HStack(spacing: compactHorizontal ? 2 : 4) {
            ForEach(
                Array(visibleToolbarTools.enumerated()),
                id: \.element.id
            ) { index, tool in
                if index > 0 && index.isMultiple(of: 3) {
                    assistDivider
                }
                AssistToolButtonRow(tool: tool, compact: compactHorizontal)
            }
            // Audio monitoring rides in its own section at the end of the strip, separated from
            // the exposure-tool groups regardless of how the groups-of-three chunking lands.
            if audioMetersButtonVisible {
                if !visibleToolbarTools.isEmpty {
                    assistDivider
                }
                AssistToolButtonRow(tool: .audioMeters, compact: compactHorizontal)
            }
        }
    }

    /// Photography narrows the toolbar to the stills-relevant tools (the cinema scopes,
    /// LUT and audio monitoring drop out), which also frees bar width for the photo strip.
    private var isPhotographyToolset: Bool {
        StillCapturePolicy.prefersPhotographyChrome(
            selector: model.cameraPropertySnapshot.captureSelector)
    }

    private var visibleToolbarTools: [MonitorAssistTool] {
        model.preferences.assistToolbarOrder.filter {
            // Audio meters render as their own trailing section (above), not inside the groups.
            $0 != .audioMeters && model.preferences.isAssistToolbarButtonVisible($0)
                && (isPhotographyToolset ? $0.appliesToPhotography : !$0.isPhotographyOnly)
        }
    }

    private var audioMetersButtonVisible: Bool {
        model.preferences.isAssistToolbarButtonVisible(.audioMeters) && !isPhotographyToolset
    }

    /// Thin vertical rule separating assist tools into groups of three.
    private var assistDivider: some View {
        Rectangle()
            .fill(LiveDesign.hairlineStrong)
            .frame(width: 1, height: 28)
            .padding(.horizontal, compactHorizontal ? 3 : 4)
    }

    // MARK: - axis: .vertical, collapsible: true (former `PortraitAssistRail`)

    /// Expanded-rail width — wide enough for `AssistToolButtonRow`'s icon + label. Also used by
    /// `MonitorShell`'s portrait branch for the outer frame it sizes around this view.
    static let expandedWidth: CGFloat = 60
    /// Height of the bottom scroll-fade so the last tool row never hard-clips mid-glyph.
    private static let bottomFadeHeight: CGFloat = 28

    private var tools: [MonitorAssistTool] {
        // Audio monitoring stays last — the vertical rail's counterpart of the horizontal strip's
        // trailing audio section.
        let regular = model.preferences.assistToolbarOrder.filter {
            $0 != .audioMeters && model.preferences.isAssistToolbarButtonVisible($0)
                && (isPhotographyToolset ? $0.appliesToPhotography : !$0.isPhotographyOnly)
        }
        return regular + (audioMetersButtonVisible ? [.audioMeters] : [])
    }

    private var verticalBody: some View {
        Group {
            if expanded {
                expandedRail
            } else {
                collapsedPill
            }
        }
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private var collapsedPill: some View {
        Button {
            expanded = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LiveDesign.text.opacity(0.86))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.zcTapTarget)
    }

    private var expandedRail: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    collapseHandle
                    ForEach(tools) { tool in
                        AssistToolButtonRow(tool: tool)
                    }
                }
                .padding(.top, 10)
                // The last row must be able to scroll fully clear of the bottom fade —
                // without this it parks half-faded against the rail's rounded end.
                .padding(.bottom, Self.bottomFadeHeight + 10)
                .padding(.horizontal, 6)
            }
            // Mirrors MediaBrowser's `portraitGridControlsBand` fade shape: rows scroll UNDER a
            // bottom gradient so the last tool never hard-clips mid-glyph against the rail's
            // rounded edge — the fade itself is the scroll affordance.
            LinearGradient(
                colors: [LiveDesign.background.opacity(0), LiveDesign.background.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.bottomFadeHeight)
            .allowsHitTesting(false)
        }
        .frame(width: Self.expandedWidth, height: feedHeight)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }

    /// Collapses the rail without hunting for the pill (which is gone while expanded).
    private var collapseHandle: some View {
        Button {
            expanded = false
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LiveDesign.muted)
                .frame(width: 44, height: 32)
        }
        .buttonStyle(.zcTapTarget)
    }
}

/// Unified system-control cluster for both monitor shells: lock, DISP, record (with its
/// confirmation alert), media, and settings.
///
/// `.axisVertical` renders the landscape lock + right-rail buttons, each positioned absolutely at
/// its `slots` frame (viewport-absolute, from the zone map). `.axisHorizontal` renders the portrait
/// bottom bar row. Mounted once per orientation inside `canvasLayer` (landscape) or at the
/// `systemBar` zone (portrait).
struct MonitorSystemCluster: View {
    @Environment(NativeAppModel.self) private var model
    /// Absolute (landscape) or column-relative (portrait) frames for the five controls.
    var slots: MonitorSystemSlotFrames
    var axis: MonitorZoneStyle
    /// Visual press feedback for the press-tracked photo shutter (no Button style there).
    @State private var shutterPressed = false

    var body: some View {
        switch axis {
        case .axisVertical:
            landscapeBody
        case .axisHorizontal:
            portraitBody
        default:
            EmptyView()
        }
    }

    // MARK: - .axisVertical (former `LockButtonModule` + `RightRailControlsModule`)

    @ViewBuilder private var landscapeBody: some View {
        lockButton
            .monitorModuleFrame(slots.lock)
        settingsButton
            .monitorModuleFrame(slots.settings)
        mediaButton
            .monitorModuleFrame(slots.media)
        recordButton
            .monitorModuleFrame(slots.record)
        displayButton
            .monitorModuleFrame(slots.disp)
    }

    private var lockButton: some View {
        let locked = model.interfaceLocked
        return Button {
            model.toggleInterfaceLock()
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(locked ? LiveDesign.accent : LiveDesign.text.opacity(0.86))
                .frame(
                    width: CGFloat(MonitorLiveViewModuleLayout.lockButtonSize),
                    height: CGFloat(MonitorLiveViewModuleLayout.lockButtonSize)
                )
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                )
                .overlay {
                    if locked {
                        RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                            .stroke(LiveDesign.accent.opacity(0.75), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.zcTapTarget)
        .sensoryFeedback(.impact(weight: .medium), trigger: locked)
        .accessibilityLabel(locked ? "Unlock monitor controls" : "Lock monitor controls")
        .accessibilityHint("Prevents accidental camera and View Assist changes")
        .accessibilityIdentifier("monitor.system.lock")
        .liveViewGuideAnchor(.lock)
    }

    private var settingsButton: some View {
        Button {
            model.activePanel = .settings
        } label: {
            AssetCircleButton(
                assetName: "IconSettings",
                systemName: "gearshape",
                size: CGFloat(MonitorSideRailControlLayout.auxiliaryButtonSize)
            )
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel("Open Operator Setup")
        .accessibilityIdentifier("monitor.system.settings")
        .liveViewGuideAnchor(.settings)
    }

    private var mediaButton: some View {
        let size = CGFloat(MonitorSideRailControlLayout.auxiliaryButtonSize)
        let isPhotography = StillCapturePolicy.prefersPhotographyChrome(
            selector: model.cameraPropertySnapshot.captureSelector)
        return Button {
            model.openMediaBrowser()
        } label: {
            if isPhotography {
                // The photo-stack glyph (formerly the strip's instant-playback icon) reads
                // better as "media" on the stills side; cinema keeps the film-roll asset.
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(LiveDesign.text.opacity(0.86))
                    .frame(width: size, height: size)
                    .liquidGlass(in: Circle())
            } else {
                AssetCircleButton(
                    assetName: "IconMedia",
                    systemName: "rectangle.stack",
                    size: size
                )
            }
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel("Open Media")
        .accessibilityIdentifier("monitor.system.media")
        .liveViewGuideAnchor(.media)
    }

    private var displayButton: some View {
        Button {
            model.cycleDisplayMode()
        } label: {
            VStack(spacing: 3) {
                Text("DISP")
                    .font(.system(size: 12, weight: .bold, design: .default))
                HStack(spacing: 3) {
                    ForEach(model.displayOrder) { mode in
                        Capsule()
                            .fill(
                                mode == model.displayMode
                                    ? LiveDesign.info : LiveDesign.hairlineStrong
                            )
                            .frame(width: 14, height: 3)
                    }
                }
            }
            .foregroundStyle(model.displayMode == .live ? LiveDesign.info : LiveDesign.text)
            .frame(
                width: CGFloat(MonitorSideRailControlLayout.displayButtonWidth),
                height: CGFloat(MonitorSideRailControlLayout.displayButtonHeight)
            )
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel("Change display mode")
        .accessibilityIdentifier("monitor.system.display")
        .liveViewGuideAnchor(.display)
    }

    // MARK: - .axisHorizontal (former `PortraitSystemBar`)

    private var portraitBody: some View {
        // Equal GAPS via equal spacers, not equal columns: the wide record button in an equal
        // column left DISP nearly touching record while far from lock.
        HStack(spacing: 0) {
            Spacer(minLength: 14)
            lockButton
            Spacer(minLength: 14)
            PortraitDisplayButton()
                .accessibilityLabel("Change display mode")
                .accessibilityIdentifier("monitor.system.display")
                .liveViewGuideAnchor(.display)
            Spacer(minLength: 14)
            recordButton
            Spacer(minLength: 14)
            mediaButton
            Spacer(minLength: 14)
            settingsButton
            Spacer(minLength: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Record / shutter + confirmation alert (shared by both axes)

    private var isPhotographyMode: Bool {
        StillCapturePolicy.prefersPhotographyChrome(
            selector: model.cameraPropertySnapshot.captureSelector)
    }

    @ViewBuilder private var recordButton: some View {
        if isPhotographyMode {
            // Press-tracked, not a Button: finger-down fires the release (or ends an open
            // bulb/time exposure) and finger-up ends a latched continuous burst — a disabled
            // Button would swallow exactly that finger-up. Re-press gating during an
            // in-flight single release lives in `shutterButtonPressed`.
            PhotographyShutterButton(
                isCapturing: model.isStillCapturing,
                countdown: model.stillTimerRemaining,
                timerArmed: model.photoTimerDelaySeconds > 0
            )
            .scaleEffect(shutterPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: shutterPressed)
            .contentShape(Circle())
            // Zero-distance drag, not a zero-duration long-press: the latter recognizes
            // instantly and never reports `onPressingChanged(true)`, swallowing the press.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !shutterPressed else { return }
                        shutterPressed = true
                        model.shutterButtonPressed()
                    }
                    .onEnded { _ in
                        shutterPressed = false
                        model.shutterButtonReleased()
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.captureStill() }
            .accessibilityLabel(
                model.stillReleaseIsOpenShutter
                    ? "End exposure" : model.isStillCapturing ? "Capturing" : "Shutter"
            )
            .accessibilityIdentifier("monitor.system.shutter")
            .liveViewGuideAnchor(.record)
        } else {
            Button {
                model.toggleRecording()
            } label: {
                RecordButton(isRecording: model.cameraState.recordState == .recording)
            }
            .buttonStyle(.zcTapTarget)
            .accessibilityLabel(
                model.cameraState.recordState == .recording ? "Stop recording" : "Start recording"
            )
            .accessibilityIdentifier("monitor.system.record")
            .liveViewGuideAnchor(.record)
            .alert(recordConfirmationTitle, isPresented: isRecordConfirmationPresented) {
                Button("Cancel", role: .cancel) {
                    model.cancelRecordToggle()
                }
                Button(recordConfirmationActionTitle, role: .destructive) {
                    model.confirmRecordToggle()
                }
            } message: {
                Text(recordConfirmationMessage)
            }
        }
    }

    private var recordConfirmationTitle: String {
        model.pendingRecordConfirmation == true ? "Start recording?" : "Stop recording?"
    }

    private var recordConfirmationActionTitle: String {
        model.pendingRecordConfirmation == true ? "Start" : "Stop"
    }

    private var recordConfirmationMessage: String {
        if model.pendingRecordConfirmation == true {
            return "Send the record command to the camera."
        }
        return "Stop the current take on the camera."
    }

    private var isRecordConfirmationPresented: Binding<Bool> {
        Binding(
            get: { model.pendingRecordConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelRecordToggle()
                }
            }
        )
    }
}

/// Unified scopes host for both monitor shells, selected by `MonitorZoneStyle`.
///
/// `.scopesFloating` (landscape) wraps `FeedAssistOverlayModule` with
/// `suppressFloatingScopes: false` — the draggable `MovablePanel` set — and needs the overlay's
/// feed-canvas coordinates (`safeArea`/`viewportWidth`/`canvasOffsetX`). `.scopesStacked`
/// (portrait) mounts the self-sizing `PortraitScopesStack`. Any other style renders nothing.
struct MonitorScopes: View {
    @Environment(NativeAppModel.self) private var model
    var style: MonitorZoneStyle
    /// Floating-only feed-canvas geometry (unused by the stacked style).
    var safeArea: MonitorEdgeInsets = .zero
    var viewportWidth: Double = 0
    var canvasOffsetX: Double = 0
    var horizontalDirection: MonitorHorizontalLayoutDirection = .standard

    var body: some View {
        switch style {
        case .scopesFloating:
            FeedAssistOverlayModule(
                safeArea: safeArea,
                viewportWidth: viewportWidth,
                canvasOffsetX: canvasOffsetX,
                horizontalDirection: horizontalDirection,
                suppressFloatingScopes: false
            )
            .environment(model)
        case .scopesStacked:
            PortraitScopesStack()
                .environment(model)
        default:
            EmptyView()
        }
    }
}

/// The one monitor view tree for both orientations. Computes `MonitorZoneLayout.map(...)` once per
/// layout pass and mounts each unified container and shared feed / command / panel view exactly at
/// its zone frame. `LiveViewShell` mounts it directly; its `.easeInOut(value: isPortrait)` makes
/// rotation a geometry change under stable view identity rather than a tree swap.
///
/// Frame source: the zone map returns absolute frames in the full-physical-viewport space.
/// Landscape frames are placed in the feed canvas space (`viewportWidth`-wide, shifted by
/// `canvasOffsetX`); portrait frames are viewport-absolute and placed directly.
///
/// **Mode gating.** The landscape map is mode-invariant, so this shell gates live/clean/command
/// itself: `.live` = full deck + bottom strips + rails + floating scopes; `.clean` = compact deck +
/// rails + scopes; `.command` = `CommandMonitor` + rails, feed unmounted. `displayChrome.*`
/// preference toggles gate each region. The portrait map already encodes per-mode zones
/// (nil / zero-height), so the portrait branch reads visibility straight off the map.
struct MonitorShell: View {
    @Environment(NativeAppModel.self) private var model
    let context: LiveViewLayoutContext
    /// Portrait assist-rail expand state (owned here so the rail's own frame can size around it).
    @State private var railExpanded = false
    /// Photography's landscape assist rail (in the notch-side gap the 3:2 feed opens up).
    @State private var photoRailExpanded = true

    /// The photography feed frame, recomputed with the module's own inputs so the shell can
    /// place chrome in the notch-side gap the rail-anchored 3:2/1:1 frame opens up.
    private func photographyFeedFrame() -> MonitorFeedFrame {
        MonitorFeedLayout.fullBleedFrame(
            viewportWidth: context.viewportWidth,
            viewportHeight: context.viewportHeight,
            safeArea: context.feedSafeArea,
            horizontalDirection: context.horizontalDirection,
            aspect: model.cameraPropertySnapshot.photographyFeedAspect,
            centered: true
        )
    }

    /// Count of scopes the portrait-fit stacked zone displays — the recency-selected ≤2 (R8);
    /// sizes the portrait scopes zone. Fit-only: fill floats all active scopes independently.
    private var scopeCount: Int {
        model.preferences.displayedFitScopes.count
    }

    var body: some View {
        GeometryReader { proxy in
            if context.isPortrait {
                portraitShell(proxy: proxy)
            } else {
                landscapeShell(proxy: proxy)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.displayMode)
        .animation(.easeOut(duration: 0.10), value: model.activePanel)
        // Scope the fit-mode 2-scope cap to the portrait tree; `initial: true` covers launch.
        .onChange(of: context.isPortrait, initial: true) { _, isPortrait in
            model.monitorIsPortrait = isPortrait
        }
        // Neither `MonitorFullScreenPanelOverlay` nor the recording tally mounts here: this
        // `GeometryReader` reports the safe-area-inset frame (`.ignoresSafeArea` is applied by
        // the `LiveViewShell` caller one level up), so an overlay at this level stays pinned to
        // the safe-area frame instead of reaching the bezel. `LiveViewShell.body`
        // (MonitorExperience.swift) is the one true extended-layer mount point; the overlay is
        // its own top-level `View` there because reading it as a property off a sibling
        // `MonitorShell` instance also crashed on `@Environment` resolution.
    }

    // MARK: - Landscape

    @ViewBuilder private func landscapeShell(proxy: GeometryProxy) -> some View {
        // The outer reader reports the safe-area-inset height, but `.fit` expects the FULL
        // physical height — use the context's restored full height for both the map and the
        // canvas frame, otherwise lock/battery/rail frames land short.
        let fullHeight = context.viewportHeight
        let map = MonitorZoneLayout.map(
            viewportWidth: context.viewportWidth,
            viewportHeight: fullHeight,
            safeArea: context.feedSafeArea,
            // Carries the iPadOS 26 window-control clearance the safe area lacks (see
            // `clearingWindowControls`), so the lock button and top deck render below the pill.
            chromeInsets: context.chromeInsets,
            mode: model.displayMode,
            isPortrait: false,
            aspect: model.preferences.portraitFeedAspect,
            scopeCount: scopeCount,
            horizontalDirection: context.horizontalDirection,
            bottomBarHeight: landscapeBottomBarHeight
        )
        let chrome = model.preferences.displayChrome

        ZStack(alignment: .topLeading) {
            // Feed base. Command pauses/hides the feed behind a full-screen black base.
            if model.displayMode == .command {
                Color.black.ignoresSafeArea()
            } else {
                LiveFeedModule(
                    safeArea: context.feedSafeArea,
                    viewportWidth: context.viewportWidth,
                    canvasOffsetX: context.canvasOffsetX,
                    horizontalDirection: context.horizontalDirection
                )
                MonitorScopes(
                    style: .scopesFloating,
                    safeArea: context.feedSafeArea,
                    viewportWidth: context.viewportWidth,
                    canvasOffsetX: context.canvasOffsetX,
                    horizontalDirection: context.horizontalDirection
                )
            }

            // Chrome + rails hide entirely behind a full-screen panel (edge-to-edge), matching the
            // legacy shell. Floating popups keep them.
            if model.activePanel?.coversFullScreen != true {
                switch model.displayMode {
                case .command:
                    // CommandMonitor owns its own full-screen canvas + offset, so it mounts
                    // directly — NOT inside `canvasLayer`, which would double-apply the offset.
                    CommandMonitor(
                        viewportWidth: context.viewportWidth,
                        canvasOffsetX: context.canvasOffsetX,
                        feedSafeArea: context.feedSafeArea,
                        chromeInsets: context.chromeInsets,
                        horizontalDirection: context.horizontalDirection
                    )
                    .environment(model)
                case .live, .clean:
                    canvasLayer {
                        landscapeChrome(map: map, chrome: chrome)
                    }
                }

                // Persistent side rails (batteries + system cluster) render on top of every mode.
                if chrome.sideRailsVisible {
                    canvasLayer {
                        if let battery = map.batteryCluster {
                            if battery.style == .batteryInline {
                                // Width-constrained (iPad): inline row beside the lock button.
                                // The frame is a nominal band; content hugs its leading edge.
                                BatteryInlineCluster()
                                    .environment(model)
                                    .monitorModuleFrame(battery.frame, alignment: .leading)
                            } else {
                                let phoneTopClearance =
                                    map.systemSlots.lock.y + map.systemSlots.lock.height
                                    - battery.frame.y
                                    + MonitorBatteryRailLayout.lockButtonGap
                                BatteryRailModule(
                                    safeArea: context.feedSafeArea,
                                    phoneTopClearance: phoneTopClearance
                                )
                                .environment(model)
                                .monitorModuleFrame(battery.frame)
                            }
                        }
                        MonitorSystemCluster(slots: map.systemSlots, axis: .axisVertical)
                            .environment(model)
                    }
                }
            }

            // Floating popups (exposure picker, assist options) anchor to the feed and bars.
            if let panel = model.activePanel, !panel.coversFullScreen {
                PanelHost(
                    panel: panel, chromeInsets: context.chromeInsets,
                    feedSafeArea: context.feedSafeArea
                )
                .environment(model)
                .transition(panelTransition(panel))
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .ignoresSafeArea(.container, edges: .all)
    }

    /// The live/clean chrome: full-width info deck (compact in clean) and the bottom
    /// assist/capture strips (live only). Mode gating is straight mount/unmount.
    @ViewBuilder private func landscapeChrome(
        map: MonitorZoneMap, chrome: DisplayChromeVisibility
    ) -> some View {
        let isClean = model.displayMode == .clean
        let deck = map.infoBar.frame

        // Status deck — compact in clean, full in live. The zone map centers it over the
        // native 16:9 feed; photography recenters it on the rail-anchored photo frame so
        // the pill tracks the visible image, not the old frame's footprint.
        if chrome.statusBarVisible {
            let isPhotographyDeck = StillCapturePolicy.prefersPhotographyChrome(
                selector: model.cameraPropertySnapshot.captureSelector)
            let photoFeed = isPhotographyDeck ? photographyFeedFrame() : nil
            let deckCenterX = photoFeed.map { $0.x + $0.width / 2 } ?? deck.midX
            let deckWidth = photoFeed.map { min(deck.width, $0.width) } ?? deck.width
            MonitorInfoBar(style: .infoPill, compact: isClean)
                .environment(model)
                .liveViewGuideAnchor(.infoBar)
                .frame(maxWidth: CGFloat(deckWidth))
                .position(x: CGFloat(deckCenterX), y: CGFloat(deck.midY))
        }

        // Bottom bars (assist + capture) — live only; clean/lock hide them. In photography
        // the assist tools always move to the lock-side vertical rail (below), handing the
        // whole band to the capture strip.
        if !isClean {
            let isPhotographyBand = StillCapturePolicy.prefersPhotographyChrome(
                selector: model.cameraPropertySnapshot.captureSelector)
            let assistVisible = chrome.assistToolbarVisible && !isPhotographyBand
            let captureVisible = chrome.cameraValuesVisible
            if let assist = map.assistStrip, let capture = map.captureStrip,
                assistVisible || captureVisible
            {
                let leftX = min(assist.frame.x, capture.frame.x)
                let rightX = max(
                    assist.frame.x + assist.frame.width, capture.frame.x + capture.frame.width)
                let width = rightX - leftX
                HStack(alignment: .bottom, spacing: 8) {
                    if assistVisible {
                        // The core map sets `collapsible` on the landscape assist zone, but there
                        // it denotes the edge-fade scroll strip — NOT a collapse pill (that is the
                        // vertical portrait rail). Rendering stays `axis`-driven (D5).
                        MonitorAssistStrip(
                            axis: .horizontal,
                            collapsible: false,
                            compactHorizontal: MonitorBatteryRailLayout.usesClassicSideNotch(
                                safeArea: context.feedSafeArea
                            )
                        )
                        .environment(model)
                        .liveViewGuideAnchor(.viewAssist)
                        .frame(
                            maxWidth: captureVisible ? .infinity : CGFloat(assist.frame.width),
                            alignment: .leading
                        )
                        .layoutPriority(0)
                        .frame(maxHeight: .infinity)
                    }
                    if captureVisible {
                        MonitorCaptureStrip(fitsWidth: true)
                            .environment(model)
                            .liveViewGuideAnchor(.cameraControls)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .opacity(model.interfaceLocked ? 0.4 : 1)
                // Photography centres the strip under the centred feed (cinema keeps the
                // assist-then-strip leading flow).
                .frame(
                    width: CGFloat(width), height: CGFloat(assist.frame.height),
                    alignment: isPhotographyBand && !assistVisible ? .center : .leading
                )
                .position(
                    x: CGFloat(leftX + width / 2),
                    y: CGFloat(assist.frame.y + assist.frame.height / 2))
            }

            // Photography's vertical assist rail, top-aligned next to the lock button and
            // expanding downward — the full tool column when the height allows (Pro Max),
            // otherwise filling (and scrolling) until it reaches the capture band. Overlaying
            // the feed edge is fine; the band strip is chrome over the feed too.
            if isPhotographyBand, chrome.assistToolbarVisible, !model.interfaceLocked,
                let band = map.assistStrip
            {
                let lock = map.systemSlots.lock
                let railX = lock.x + lock.width + 12 + Double(MonitorAssistStrip.expandedWidth) / 2
                let railTop = lock.y
                // "Fill until it hits the bottom bar": the trailing-aligned capture strip on a
                // wider body (Pro Max) never reaches the rail's lane, so the rail runs down to
                // the band's bottom edge there; it stops above the band only when the strip's
                // measured frame actually enters the lane.
                let laneTrailing =
                    lock.x + lock.width + 12 + Double(MonitorAssistStrip.expandedWidth)
                let stripFrame = model.captureBarFrame
                let stripEntersLane =
                    stripFrame.width > 1 && Double(stripFrame.minX) < laneTrailing + 16
                let railBottom =
                    stripEntersLane
                    ? band.frame.y - 10
                    : band.frame.y + band.frame.height
                let railHeight = max(0, railBottom - railTop)
                MonitorAssistStrip(
                    axis: .vertical,
                    collapsible: true,
                    feedHeight: CGFloat(railHeight),
                    expanded: $photoRailExpanded
                )
                .environment(model)
                .liveViewGuideAnchor(.viewAssist)
                // Top-aligned in the rail lane: a tool column shorter than the lane hugs the
                // lock row instead of centring in the leftover space.
                .frame(maxHeight: CGFloat(railHeight), alignment: .top)
                .position(
                    x: CGFloat(railX),
                    y: CGFloat(railTop + railHeight / 2))
            }

            // Recenter-focus affordance, bottom-left above the bars, when the AF point is off
            // centre or subject tracking is latched (reset ends tracking, so it must stay visible
            // while a tracked box drifts through centre). Live-only, hidden while locked;
            // battery-rail-relative x, scope-panel-clearance y (`focusResetButtonClearY`).
            if model.isFocusResetAvailable, !model.interfaceLocked,
                let battery = map.batteryCluster,
                let assist = map.assistStrip
            {
                let rail = battery.frame
                let size: CGFloat = 40
                // Inline battery (iPad) sits in the top band, so its frame no longer marks the
                // bottom-left lane; fall back to the assist bar's leading edge plus the same
                // clearance the rail layout produced (indicator width 38 + 24). Photography's
                // lock-side assist rail owns that lane instead, so clear past it there.
                let photographyRailTrailing =
                    map.systemSlots.lock.x + map.systemSlots.lock.width + 12
                    + Double(MonitorAssistStrip.expandedWidth)
                let x =
                    isPhotographyBand && chrome.assistToolbarVisible
                    ? CGFloat(photographyRailTrailing) + 24 + size / 2
                    : battery.style == .batteryInline
                        ? CGFloat(assist.frame.x) + 62
                        : CGFloat(rail.x + rail.width) + 24
                let y = model.focusResetButtonClearY(
                    centerX: x, baseY: CGFloat(assist.frame.y) - 30, size: size)
                Button {
                    model.resetFocusPoint()
                } label: {
                    Image(systemName: "dot.viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .frame(width: size, height: size)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(LiveDesign.hairline, lineWidth: 1))
                }
                .buttonStyle(.zcTapTarget)
                .position(x: x, y: y)
                .animation(.easeOut(duration: 0.2), value: y)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    /// Wraps chrome children in the feed-canvas coordinate space: a full-bleed `.ignoresSafeArea()`
    /// GeometryReader (physical-screen `proxy.size`), then a `viewportWidth`-wide top-leading
    /// canvas shifted by `canvasOffsetX`. Map-derived frames that sit inside the Dynamic Island
    /// lane (lock/battery at x≈16) land exactly instead of being clipped by a safe-area-inset
    /// parent.
    @ViewBuilder private func canvasLayer<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { canvasProxy in
            ZStack(alignment: .topLeading) { content() }
                .frame(
                    width: CGFloat(context.viewportWidth), height: canvasProxy.size.height,
                    alignment: .topLeading
                )
                .offset(x: CGFloat(context.canvasOffsetX))
        }
        .ignoresSafeArea()
    }

    /// Reserve the live bottom-bar band in every mode so the right rail never shifts between modes.
    private var landscapeBottomBarHeight: Double {
        model.preferences.displayChrome.assistToolbarVisible
            || model.preferences.displayChrome.cameraValuesVisible
            ? Double(LiveDesign.controlHeight)
            : 0
    }

    // MARK: - Portrait

    @ViewBuilder private func portraitShell(proxy: GeometryProxy) -> some View {
        // Command wants a full-height control grid regardless of the persisted aspect; `.fit16x9`
        // for the zone maths yields the topBar→systemBar span it needs.
        let persistedAspect = model.preferences.portraitFeedAspect
        let zoneAspect: PortraitFeedAspect =
            model.displayMode == .command ? .fit16x9 : persistedAspect
        let map = MonitorZoneLayout.map(
            viewportWidth: context.viewportWidth,
            viewportHeight: context.viewportHeight,
            safeArea: context.feedSafeArea,
            mode: model.displayMode,
            isPortrait: true,
            aspect: zoneAspect,
            scopeCount: scopeCount,
            horizontalDirection: context.horizontalDirection,
            // Fit-mode assist toolbar (R6): the core emits an `assistStrip` zone only when this is
            // non-zero (and only for fit + live). Fill/clean/command collapse it to nothing.
            bottomBarHeight: model.preferences.displayChrome.assistToolbarVisible
                ? MonitorPortraitLayout.assistToolbarHeight : 0
        )
        let feed = map.feed
        let isFill = persistedAspect == .fill
        // The zone map hands us the feed FRAME; the content aspect-fills within it: over-widen to
        // the source's 16:9 at the frame's height, center via the outer frame, clip to the frame.
        // Fit passes the frame width straight through (16:9 frame == 16:9 content, no crop).
        let feedContentWidth = isFill ? feed.height * 16 / 9 : feed.width

        ZStack(alignment: .topLeading) {
            // Sized to the FULL physical height explicitly: this ZStack is the safe-area frame
            // re-rooted to physical 0, so its own bottom edge sits `safeArea.top` short of the
            // screen bottom — a bare `.ignoresSafeArea()` can't extend past a boundary the view
            // never reaches at layout time, and the root background bled through under the
            // translucent system band (the "two bottom frames" artifact).
            Color.black
                .frame(
                    width: proxy.size.width, height: CGFloat(context.viewportHeight),
                    alignment: .topLeading
                )
                .ignoresSafeArea()

            if model.displayMode != .command {
                LiveFeedModule(
                    safeArea: context.feedSafeArea,
                    viewportWidth: feedContentWidth,
                    canvasOffsetX: context.canvasOffsetX,
                    // The portrait chain positions with render-transform offsets, so at LAYOUT
                    // time this box sits at the ZStack origin inside the safe-area region — the
                    // module's own measured-height path derives an undersized, up-shifted 16:9
                    // box from the mangled proposal (the fill "cropped on top and right" bug).
                    // Handing it the zone height makes the box independent of that machinery.
                    fixedContentHeight: feed.height
                )
                .frame(width: feedContentWidth, height: feed.height)
                // The over-widened content is centered by this outer frame's default center
                // alignment alone (R10): a redundant inner `.offset(x: feedContentOffsetX)` used
                // to composite ON TOP of this centering, adding the two together and landing the
                // fill crop on the right edge instead of dead-center. One centering mechanism now.
                .frame(width: feed.width, height: feed.height)
                .clipped()
                .offset(x: feed.x, y: feed.y)
                .simultaneousGesture(pinchAspectGesture)

                // Portrait suppresses the floating scope panels (redundant with the stacked scopes
                // zone below); feed-anchored assists live inside LiveFeedModule. Mounted with
                // suppression directly — `MonitorScopes(.scopesFloating)` is the non-suppressed
                // landscape case.
                FeedAssistOverlayModule(
                    safeArea: context.feedSafeArea,
                    viewportWidth: feedContentWidth,
                    canvasOffsetX: context.canvasOffsetX,
                    suppressFloatingScopes: true
                )
                .environment(model)
                .frame(width: feedContentWidth, height: feed.height)
                // Same single-centering fix as the feed chain above (R10).
                .frame(width: feed.width, height: feed.height)
                .clipped()
                .offset(x: feed.x, y: feed.y)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if railExpanded { railExpanded = false }
                    }
                )
            }

            // Fill mode: landscape-behaviour floating scopes over the visible feed (R8) —
            // draggable, resizable, uncapped, positions persisted by `MovablePanel`. Mounted
            // OUTSIDE the crop-clip chain at the *visible* feed zone, so `viewportWidth:
            // feed.width` clamps drag bounds to what the operator sees. This renders ONLY the
            // scope/false-colour panels, so it duplicates nothing from the suppressed inner
            // overlay above (that one renders no panels; it survives as the rail-collapse tap
            // catcher).
            if isFill, model.displayMode == .live {
                // No `.clipped()` here (G2): MovablePanel already clamps panels inside its
                // bounds, so clipping only ever manifests as a sliced panel edge when a panel
                // straddles the frame boundary (WAVE/PARADE cut mid-panel on device).
                MonitorScopes(
                    style: .scopesFloating,
                    safeArea: context.feedSafeArea,
                    viewportWidth: feed.width,
                    canvasOffsetX: 0
                )
                .environment(model)
                .frame(width: feed.width, height: feed.height)
                .offset(x: feed.x, y: feed.y)
            }

            // Overlaid top bar.
            MonitorInfoBar(style: .infoBar)
                .environment(model)
                .liveViewGuideAnchor(.infoBar)
                .frame(width: map.infoBar.frame.width, height: map.infoBar.frame.height)
                .offset(x: map.infoBar.frame.x, y: map.infoBar.frame.y)

            // REC options quick access: the zone map returns nil recOptions in both orientations,
            // so the shell places the button itself — top-right over the feed, below the top bar.
            if model.displayMode != .command {
                PortraitRecOptionsButton()
                    .environment(model)
                    .opacity(model.interfaceLocked ? 0.4 : 1)
                    .frame(width: 40, height: 40, alignment: .topTrailing)
                    .offset(
                        x: feed.x + feed.width - 40 - 10,
                        y: map.infoBar.frame.y + map.infoBar.frame.height + 8
                    )
            }

            // Fit mode: dedicated stacked scopes zone below the feed.
            if !isFill, let scopes = map.scopes {
                MonitorScopes(style: .scopesStacked)
                    .padding(.horizontal, 12)
                    .frame(width: scopes.frame.width, height: scopes.frame.height)
                    .offset(x: scopes.frame.x, y: scopes.frame.y)
            }

            // Controls zone: fill → capture strip over the feed bottom; fit/command → command grid.
            // The core adapter emits a non-nil `controlsGrid` for every fit-aspect pass, including
            // clean mode where the region collapses to zero height — guard on the frame height so
            // clean shows no grid.
            if let capture = map.captureStrip {
                MonitorCaptureStrip(fitsWidth: false)
                    .environment(model)
                    .liveViewGuideAnchor(.cameraControls)
                    .opacity(model.interfaceLocked ? 0.4 : 1)
                    .frame(width: capture.frame.width, height: capture.frame.height)
                    .offset(x: capture.frame.x, y: capture.frame.y)
            } else if let grid = map.controlsGrid, grid.frame.height > 0 {
                // Command (DISP 3) reserves a hero-timecode band off the top of the tile region
                // and shifts the tiles down by it; fit-mode live tiles carry no band. The timecode
                // isn't lock-dimmed (live status, like the top bar); only the tiles dim.
                let isCommand = model.displayMode == .command
                let tcBand: CGFloat = isCommand ? 80 : 0
                if isCommand {
                    PortraitCommandTimecode()
                        .environment(model)
                        .padding(.horizontal, 12)
                        .frame(width: grid.frame.width, height: tcBand)
                        .offset(x: grid.frame.x, y: grid.frame.y)
                }
                CommandPrimaryGrid(
                    availableHeight: CGFloat(grid.frame.height) - tcBand
                        - (isCommand ? 0 : 8),
                    columns: 3
                )
                .environment(model)
                .liveViewGuideAnchor(.cameraControls)
                .padding(.horizontal, 12)
                .opacity(model.interfaceLocked ? 0.4 : 1)
                .frame(width: grid.frame.width, height: grid.frame.height - tcBand)
                .offset(x: grid.frame.x, y: grid.frame.y + tcBand)
            }

            // Fit mode: horizontal assist toolbar between the scopes zone and the tile grid (R6).
            // The core emits `assistStrip` only for fit + live; 12/4pt insets float the glass pill
            // off the screen edges. The vertical rail is fill-only (below).
            if let assist = map.assistStrip {
                MonitorAssistStrip(axis: .horizontal, collapsible: false)
                    .environment(model)
                    .liveViewGuideAnchor(.viewAssist)
                    .opacity(model.interfaceLocked ? 0.4 : 1)
                    .frame(width: assist.frame.width - 24, height: assist.frame.height - 8)
                    .offset(x: assist.frame.x + 12, y: assist.frame.y + 4)

                // Scope-cap notice (R7): self-dissolving capsule centered above the toolbar zone.
                MonitorToast(text: model.scopeCapNoticeText, trigger: model.scopeCapNotice)
                    .frame(width: assist.frame.width)
                    .offset(x: assist.frame.x, y: assist.frame.y - 40)
            }

            // Assist rail (fill only): collapsed pill on the feed's bottom-left; expanded spans the
            // feed height. Fit mode uses the horizontal toolbar above instead.
            // `axis: .vertical, collapsible: true` renders the collapse pill.
            if model.displayMode != .command, isFill {
                let controlsHeight = map.captureStrip?.frame.height ?? 0
                let bottomClearance = isFill ? controlsHeight + 10 : 10
                // The bar no longer overlays the feed, so the expanded rail spans the feed from
                // a plain margin rather than clearing the info bar's height.
                let railTop = feed.y + 10
                let railHeight = feed.height - 10
                MonitorAssistStrip(
                    axis: .vertical, collapsible: true, feedHeight: railHeight,
                    expanded: $railExpanded
                )
                .environment(model)
                .liveViewGuideAnchor(.viewAssist)
                .opacity(model.interfaceLocked ? 0.4 : 1)
                .frame(
                    width: railExpanded ? MonitorAssistStrip.expandedWidth : 44,
                    height: railExpanded ? railHeight : 44,
                    alignment: .bottomLeading
                )
                .offset(
                    x: feed.x + 10,
                    y: railExpanded
                        ? railTop
                        : feed.y + feed.height - 44 - bottomClearance
                )
            }

            // Recenter-focus affordance, bottom-right of the feed — the portrait counterpart of
            // the landscape `focusResetButton`. In fill the capture strip overlays the feed
            // bottom, so lift it clear (same clearance as the assist rail); in fit the feed
            // bottom is free.
            if model.displayMode != .command, model.isFocusResetAvailable, !model.interfaceLocked {
                let size: CGFloat = 40
                let controlsHeight = map.captureStrip?.frame.height ?? 0
                let bottomClearance = isFill ? controlsHeight + 10 : 10
                let x = feed.x + feed.width - size - 10
                let y = feed.y + feed.height - size - bottomClearance
                Button {
                    model.resetFocusPoint()
                } label: {
                    Image(systemName: "dot.viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .frame(width: size, height: size)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(LiveDesign.hairline, lineWidth: 1))
                }
                .buttonStyle(.zcTapTarget)
                .offset(x: x, y: y)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            // Opaque band behind the system controls, from the cluster's top through the physical
            // bottom edge (home-indicator area) so the record button no longer floats on bare
            // black (R4). `context.viewportHeight` is the restored full physical height; the ZStack
            // is top-anchored at physical 0 (no safe-area centering — the offset children carry
            // physical coordinates), so this reaches the true bottom edge.
            Rectangle()
                .fill(LiveDesign.glass)
                .frame(
                    width: map.systemCluster.frame.width,
                    height: CGFloat(context.viewportHeight) - map.systemCluster.frame.y
                )
                .offset(x: map.systemCluster.frame.x, y: map.systemCluster.frame.y)
                .allowsHitTesting(false)

            // Persistent bottom system band.
            MonitorSystemCluster(slots: map.systemSlots, axis: .axisHorizontal)
                .environment(model)
                .frame(width: map.systemCluster.frame.width, height: map.systemCluster.frame.height)
                .offset(x: map.systemCluster.frame.x, y: map.systemCluster.frame.y)

            // Pickers / assist popups (portrait-anchored host).
            if let panel = model.activePanel, !panel.coversFullScreen {
                PanelHost(
                    panel: panel, chromeInsets: context.chromeInsets,
                    feedSafeArea: context.feedSafeArea, isPortrait: true
                )
                .environment(model)
                .transition(panelTransition(panel))
            }
        }
        // `.top`: the full-physical-height base black inflates the ZStack's layout union past
        // this frame — default center alignment would shift the whole physical-coordinate tree
        // up by half the overshoot. Top-aligned, the canvas stays rooted at physical 0.
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        .ignoresSafeArea(.container, edges: .all)
    }

    /// Pinch-to-snap the portrait feed aspect.
    private var pinchAspectGesture: some Gesture {
        MagnificationGesture()
            .onEnded { value in
                let next: PortraitFeedAspect?
                if value > 1.15 {
                    next = .fill
                } else if value < 0.87 {
                    next = .fit16x9
                } else {
                    next = nil
                }
                guard let next, next != model.preferences.portraitFeedAspect else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.preferences.portraitFeedAspect = next
                }
            }
    }

    private func panelTransition(_ panel: NativeAppModel.ActivePanel) -> AnyTransition {
        panel.managesOwnAppearance
            ? .asymmetric(insertion: .identity, removal: .opacity)
            : .opacity.combined(with: .scale(scale: 0.98))
    }
}

/// Self-dissolving notice pill (scope cap, R7). One at a time; a new `trigger` restarts the clock.
/// Tap-through — it never intercepts touches on the toolbar beneath it.
struct MonitorToast: View {
    let text: String
    let trigger: Int
    @State private var visible = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LiveDesign.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(in: Capsule())
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .task(id: trigger) {
                guard trigger > 0 else { return }
                visible = true
                try? await Task.sleep(for: .seconds(2.5))
                visible = false
            }
    }
}

/// A full-screen panel (Operator Setup, Media, Tool Library) rendered on the extended
/// physical-screen layer so its opaque surface reaches the bezel. A standalone `View` (not a
/// `MonitorShell` computed property) so `LiveViewShell` constructs it directly, past its
/// `.ignoresSafeArea(.container, edges: .all)` — the one true extended-layer mount point (see
/// `MonitorShell.body`). Reading it off a sibling `MonitorShell` instance crashed: `@Environment`
/// resolves against THIS view's tree position, and a bare property getter never gets one.
struct MonitorFullScreenPanelOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let context: LiveViewLayoutContext

    var body: some View {
        if let panel = model.activePanel, panel.coversFullScreen {
            GeometryReader { phys in
                PanelHost(
                    panel: panel, chromeInsets: context.chromeInsets,
                    feedSafeArea: fullScreenPanelSafeArea,
                    isPortrait: context.isPortrait
                )
                .environment(model)
                .frame(width: phys.size.width, height: phys.size.height)
            }
            .ignoresSafeArea()
            .transition(.opacity.animation(.easeInOut(duration: 0.22)))
        }
    }

    /// Insets a landscape full-screen panel should clear — zero the clean short edge so the
    /// surface hugs that bezel while clearing the Dynamic Island on the side it sits. Portrait
    /// passes the safe area straight through.
    private var fullScreenPanelSafeArea: MonitorEdgeInsets {
        guard !context.isPortrait else { return context.feedSafeArea.clearingWindowControls }
        let islandOnLeading = context.horizontalDirection != .mirrored
        return MonitorEdgeInsets(
            top: context.feedSafeArea.top,
            leading: islandOnLeading ? context.feedSafeArea.leading : 0,
            bottom: context.feedSafeArea.bottom,
            trailing: islandOnLeading ? 0 : context.feedSafeArea.trailing
        ).clearingWindowControls
    }
}
