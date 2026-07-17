import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CommandMonitor: View {
    @Environment(NativeAppModel.self) private var model
    /// Full-screen viewport width and its horizontal shift — the dashboard renders in the same
    /// coordinate space as the shared side rails so it lines up with them exactly.
    let viewportWidth: Double
    var canvasOffsetX: Double = 0
    /// Real device safe area — the dashboard fills the screen, so it must clear the Dynamic Island
    /// lane and the landscape home-indicator band.
    var feedSafeArea: MonitorEdgeInsets = .zero
    let chromeInsets: MonitorEdgeInsets
    let horizontalDirection: MonitorHorizontalLayoutDirection

    var body: some View {
        ZStack {
            LiveDesign.background.ignoresSafeArea()

            GeometryReader { proxy in
                // The rails own the leading and trailing lanes; the dashboard fills the gap between
                // them, derived from the same `MonitorLiveViewModuleLayout.fit` the rails use.
                let layout = MonitorLiveViewModuleLayout.fit(
                    viewportWidth: viewportWidth,
                    viewportHeight: Double(proxy.size.height),
                    feedSafeArea: feedSafeArea,
                    chromeInsets: chromeInsets,
                    bottomBarHeight: 0,
                    horizontalDirection: horizontalDirection
                )
                // Match the live-mode deck's span so the dashboard lines up with the live HUD
                // and clears both rails the same way.
                let leading = layout.topInfoDeck.x
                let trailing = viewportWidth - (layout.topInfoDeck.x + layout.topInfoDeck.width)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(
                        EdgeInsets(
                            top: max(14, CGFloat(feedSafeArea.top)),
                            leading: CGFloat(leading),
                            bottom: CGFloat(feedSafeArea.bottom) + 16,
                            trailing: CGFloat(trailing))
                    )
                    .frame(
                        width: CGFloat(viewportWidth), height: proxy.size.height,
                        alignment: .topLeading
                    )
                    .offset(x: CGFloat(canvasOffsetX))
            }
            .ignoresSafeArea()
        }
    }

    private var content: some View {
        // Top-level 2.35fr : 0.85fr split (prototype `.cmd-body`): the left two-thirds stack the
        // timecode, status strip and primary grid; the right third (Image/Focus/Audio) runs full
        // height alongside them, so the status strip spans only the left columns — not the whole bar.
        GeometryReader { proxy in
            let sideWidth = max(160, proxy.size.width * 0.27)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 11) {
                        RecordChip(state: model.cameraState.recordState)
                        CommandTimecodeReadout()
                        Spacer(minLength: 0)
                    }

                    CommandHealthStrip()
                        .environment(model)

                    GeometryReader { gridProxy in
                        CommandPrimaryGrid(availableHeight: gridProxy.size.height)
                            .environment(model)
                            // Lock dims the tiles into a read-only look (CommandMonitor only ever
                            // renders in command mode, so no display-mode guard needed).
                            .opacity(model.interfaceLocked ? 0.4 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                CommandSideColumn()
                    .environment(model)
                    .frame(width: sideWidth)
                    // Dim the side-column setting tiles too, so lock reads as read-only across the
                    // whole command dashboard (the status strip + system rail stay live).
                    .opacity(model.interfaceLocked ? 0.4 : 1)
            }
        }
    }

}

/// Hero timecode with the frame field tinted accent (prototype `.tc .fr`). Its own view so the
/// per-frame `model.liveTimecode` updates invalidate just this text, not the whole dashboard.
private struct CommandTimecodeReadout: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        let tc = model.liveTimecode
        return
            (Text(String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second))
            .foregroundStyle(LiveDesign.text)
            + Text(String(format: ":%02d", tc.frame))
            .foregroundStyle(LiveDesign.accent))
            .font(.system(size: 60, weight: .regular, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }
}

/// The command-monitor primary grid (DISP 3): eight ride-along controls the operator can reorder by
/// long-press-dragging a tile. Tiles are absolutely positioned so a dragged tile follows the finger
/// while the others animate to their new slots; the order persists via `model.commandGridOrder`.
struct CommandPrimaryGrid: View {
    @Environment(NativeAppModel.self) private var model
    let availableHeight: CGFloat

    @State private var draggingKind: CommandTileKind?
    @State private var dragLocation: CGPoint = .zero

    /// Column count. Landscape (DISP-3) and portrait v2 both pass the default 3.
    var columns: Int = 3
    private let spacing: CGFloat = 9
    private static let space = "commandGrid"

    /// Spring used for both the live shuffle and the drop — smooth with a touch of life.
    private let shuffle = Animation.spring(response: 0.3, dampingFraction: 0.72)

    var body: some View {
        GeometryReader { proxy in
            let order = model.visibleCommandGridOrder
            let rows = max(1, Int((Double(order.count) / Double(columns)).rounded(.up)))
            let rowHeight = max(
                44, (proxy.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            let tileWidth = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ZStack(alignment: .topLeading) {
                ForEach(Array(order.enumerated()), id: \.element) { index, kind in
                    let isDragging = draggingKind == kind
                    CommandTile(title: title(kind), value: value(kind), height: rowHeight)
                        .frame(width: tileWidth)
                        .scaleEffect(isDragging ? 1.06 : 1)
                        .shadow(color: .black.opacity(isDragging ? 0.5 : 0), radius: 16, y: 8)
                        .zIndex(isDragging ? 1 : 0)
                        // The dragged tile tracks the finger (set outside the shuffle animation, so it's
                        // instant); the rest read their slot from `index` and spring there.
                        .position(
                            isDragging
                                ? dragLocation
                                : center(index: index, tileWidth: tileWidth, rowHeight: rowHeight)
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.space))
            // Quick tap opens the tile's picker; a 0.3s long-press picks it up to reorder. The tap
            // MUST be a `.simultaneousGesture` — `.onTapGesture` / `.exclusively(before:)` are
            // subordinate to `.gesture(reorderGesture)`, whose long-press+drag swallows the touch
            // (the popups-don't-open bug). The drag stays on the *stable* container so it survives
            // every shuffle; `draggingKind` guards a stray tap mid-reorder.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(Self.space))
                    .onEnded { value in
                        guard draggingKind == nil else { return }
                        let s = slot(
                            at: value.location, tileWidth: tileWidth, rowHeight: rowHeight,
                            count: order.count)
                        guard s < order.count, let picker = picker(order[s]) else { return }
                        model.showPicker(picker)
                    }
            )
            .gesture(reorderGesture(tileWidth: tileWidth, rowHeight: rowHeight, count: order.count))
        }
    }

    private func center(index: Int, tileWidth: CGFloat, rowHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: CGFloat(index % columns) * (tileWidth + spacing) + tileWidth / 2,
            y: CGFloat(index / columns) * (rowHeight + spacing) + rowHeight / 2)
    }

    private func slot(at point: CGPoint, tileWidth: CGFloat, rowHeight: CGFloat, count: Int) -> Int
    {
        let col = min(max(Int(point.x / (tileWidth + spacing)), 0), columns - 1)
        let row = max(Int(point.y / (rowHeight + spacing)), 0)
        return min(max(row * columns + col, 0), count - 1)
    }

    /// Long-press the grid to pick up the tile under the finger, then drag to reorder; the others
    /// spring to their new slots. A quick tap instead falls through to the tile's picker button.
    private func reorderGesture(tileWidth: CGFloat, rowHeight: CGFloat, count: Int) -> some Gesture
    {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if draggingKind == nil {
                    let order = model.visibleCommandGridOrder
                    let start = slot(
                        at: drag.startLocation, tileWidth: tileWidth, rowHeight: rowHeight,
                        count: count)
                    guard start < order.count else { return }
                    draggingKind = order[start]
                    dragLocation = drag.startLocation
                }
                guard let kind = draggingKind else { return }
                dragLocation = drag.location
                let target = slot(
                    at: drag.location, tileWidth: tileWidth, rowHeight: rowHeight, count: count)
                if model.commandGridOrder.firstIndex(of: kind) != target {
                    withAnimation(shuffle) { model.moveCommandTile(kind, to: target) }
                }
            }
            .onEnded { _ in
                withAnimation(shuffle) { draggingKind = nil }
            }
    }

    private func title(_ kind: CommandTileKind) -> String {
        switch kind {
        case .mode: "Mode"
        case .iso: "ISO"
        case .shutter: "Shutter"
        case .iris: "Iris"
        case .whiteBalance: "White Bal"
        case .resolutionFramerate: "Resolution Framerate"
        case .codec: "Codec"
        case .ibis: "VR / e-VR"
        }
    }

    private func picker(_ kind: CommandTileKind) -> CameraPicker? {
        switch kind {
        case .mode: .mode
        case .iso: .iso
        case .shutter: .shutter
        case .iris: .iris
        case .whiteBalance: .whiteBalance
        case .resolutionFramerate: .resolution
        case .codec: .codec
        case .ibis: .stabilization
        }
    }

    private func value(_ kind: CommandTileKind) -> String {
        switch kind {
        case .mode: model.commandExposureMode
        case .iso: cameraValue("ISO", fallback: "—")
        case .shutter: cameraValue("SHUTTER", fallback: "—")
        case .iris: cameraValue("IRIS", fallback: "—")
        case .whiteBalance: cameraValue("WB", fallback: "—")
        case .resolutionFramerate: model.cameraState.resolutionFrameRate
        case .codec: model.cameraState.codec
        case .ibis: model.commandStabilizationLabel
        }
    }

    private func cameraValue(_ label: String, fallback: String) -> String {
        model.cameraState.values.first(where: { $0.label == label })?.value ?? fallback
    }
}

struct CommandHealthStrip: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            CommandStatusBlock(label: "Temp", value: tempValue)
            CommandStatusBlock(label: "Storage", value: Text(model.mediaReadout))
            CommandStatusBlock(label: "Camera", value: Text(model.cameraState.cameraName))
            CommandStatusBlock(label: "Lens", value: Text(model.cameraState.lens))
            Spacer(minLength: 4)
            // Hold the FPS chip at its natural size; the wider status blocks scale down first.
            FPSChip(fps: model.liveFPS, signalBars: model.liveSignalBars)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
    }

    /// Temperature readout with a green "OK" prefix when the body reports healthy, mirroring `.cc-ok`.
    private var tempValue: Text {
        let raw = model.cameraState.temperature
        guard let range = raw.range(of: "OK") else { return Text(raw) }
        return Text("OK").foregroundStyle(LiveDesign.good) + Text(String(raw[range.upperBound...]))
    }
}

struct CommandStatusBlock: View {
    let label: String
    let value: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .default))
                .foregroundStyle(LiveDesign.faint)
                .textCase(.uppercase)
            value
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(minWidth: 52, maxWidth: 148, alignment: .leading)
    }
}

struct CommandSideColumn: View {
    @Environment(NativeAppModel.self) private var model
    /// True once the column is scrolled to (or fits within) the bottom, so the fade and the "More"
    /// hint clear instead of covering the last row.
    @State private var atBottom = false

    var body: some View {
        GeometryReader { outer in
            scroller(viewportHeight: outer.size.height)
        }
    }

    private func scroller(viewportHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                CommandSection(title: "Image") {
                    CmdRow {
                        CommandSmallTile(title: "Tone", value: model.commandToneLabel)
                        CommandSmallTile(title: "Picture Profile", value: "—", muted: true)
                    }
                }

                CommandSection(title: "Focus") {
                    CmdRow {
                        CommandSmallTile(
                            title: "Mode",
                            value: cameraValue("FOCUS", fallback: "—"),
                            picker: .focus,
                            pickerMode: 0)
                        CommandSmallTile(
                            title: "Area",
                            value: model.focusArea,
                            picker: .focus,
                            pickerMode: 1)
                    }
                    CmdRow {
                        CommandSmallTile(
                            title: "Subject",
                            value: model.focusSubject,
                            picker: .focus,
                            pickerMode: 2)
                    }
                }

                CommandSection(title: "Audio") {
                    CmdRow {
                        CommandSmallTile(
                            title: "Sens",
                            value: model.commandMicrophoneSensLabel,
                            picker: .audio,
                            pickerMode: 0,
                            amber: model.commandMicrophoneUsesManualLevel)
                        CommandSmallTile(
                            title: "32-bit Float",
                            value: model.commandAudio32BitFloatLabel,
                            picker: .audio,
                            pickerMode: 4)
                    }
                    CmdRow {
                        CommandSmallTile(
                            title: "Input",
                            value: model.commandMicrophoneInputLabel,
                            picker: .audio,
                            pickerMode: 1)
                        CommandSmallTile(
                            title: "Wind",
                            value: model.commandWindFilterLabel,
                            picker: .audio,
                            pickerMode: 2)
                    }
                    CmdRow {
                        CommandSmallTile(
                            title: "Atten",
                            value: model.commandInputAttenuatorLabel,
                            picker: .audio,
                            pickerMode: 3,
                            amber: model.commandInputAttenuatorOn)
                    }
                }

                CommandSection(title: "Monitor") {
                    CmdRow {
                        // Grid reads the camera's framing-grid setting (GridDisplay 0xD16C), not the
                        // app's local overlay toggle. Assist / DISP / Guides tiles were removed —
                        // they reflect app-only state with no camera connection point.
                        CommandSmallTile(title: "Grid", value: model.commandGridLabel)
                    }
                }
            }
            .padding(.bottom, 20)
            .background(
                // Reports the content's bottom edge in the scroll viewport's space; when it reaches
                // the viewport bottom, we're scrolled to the end (or it all fits).
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SideColumnBottomKey.self,
                        value: geo.frame(in: .named("cmdSideScroll")).maxY)
                }
            )
        }
        .coordinateSpace(.named("cmdSideScroll"))
        .onPreferenceChange(SideColumnBottomKey.self) { maxY in
            atBottom = maxY <= viewportHeight + 2
        }
        .mask {
            if atBottom {
                Rectangle()
            } else {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .bottom) {
            // Non-interactive "more below" scroll hint (prototype `.cmd-more`); clears at the end.
            if !atBottom {
                Text("MORE ⌄")
                    .font(.system(size: 9, weight: .semibold, design: .default))
                    .foregroundStyle(LiveDesign.muted)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: atBottom)
    }

    private func cameraValue(_ label: String, fallback: String) -> String {
        model.cameraState.values.first(where: { $0.label == label })?.value ?? fallback
    }
}

/// Carries the command side column's content-bottom Y (in the scroll viewport's space) up so the
/// view can tell when it's scrolled to the end.
private struct SideColumnBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Presentational only — `CommandPrimaryGrid` owns the tap (open picker) and the long-press-drag
/// (reorder) on one container gesture, so a reorder never also fires a tap.
struct CommandTile: View {
    let title: String
    let value: String
    var height: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .default))
                .foregroundStyle(LiveDesign.faint)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1)
                .minimumScaleFactor(0.46)
        }
        // Pad first, then clamp to `height`, so the tile is exactly `height` tall (padding outside
        // the frame was adding ~20pt per tile, overflowing the grid).
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(
            LiveDesign.surface, in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        }
    }
}

struct CommandSmallTile: View {
    @Environment(NativeAppModel.self) private var model
    let title: String
    let value: String
    var picker: CameraPicker?
    /// Segmented mode tab to open when `picker` is presented (e.g. FOCUS Area = 1).
    var pickerMode: Int = 0
    /// Accent-tinted value (the prototype's `.cmd-stile.amber`) — used for the audio readouts.
    var amber: Bool = false
    /// Dimmed value (the prototype's `.cmd-stile.muted`) — used for the placeholder picture profile.
    var muted: Bool = false

    private var valueColor: Color {
        if amber { return LiveDesign.accent }
        if muted { return LiveDesign.faint }
        return LiveDesign.text
    }

    var body: some View {
        Button {
            if let picker {
                model.showPicker(picker, mode: pickerMode)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .default))
                    .foregroundStyle(LiveDesign.muted)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                LiveDesign.surface, in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                    .stroke(LiveDesign.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.zcTapTarget)
        .disabled(picker == nil)
    }
}

struct CommandSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .default))
                .foregroundStyle(LiveDesign.faint)
                .textCase(.uppercase)
                .padding(.leading, 2)

            // Rows of paired tiles; a row holding a single tile spans the full width (the
            // prototype's `.span2`), since each tile claims the available width equally.
            VStack(spacing: 5) {
                content
            }
        }
    }
}

/// One row of the command side column — one tile fills the width, two split it evenly.
struct CmdRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            content
        }
    }
}

struct PanelHost: View {
    @Environment(NativeAppModel.self) private var model
    let panel: NativeAppModel.ActivePanel
    let chromeInsets: MonitorEdgeInsets
    /// The real device safe-area insets (unlike `chromeInsets`, these carry the landscape Dynamic
    /// Island lane) so leading-anchored panels can clear the cutout.
    var feedSafeArea: MonitorEdgeInsets = .zero
    /// Portrait has no capture/toolbar bar to anchor to, so the bottom picker/assist popups fall back
    /// to a viewport-fit box centred in the full width instead of the landscape chrome-inset anchor.
    var isPortrait: Bool = false
    /// Measured height of the active managed panel (exposure picker or assist options), so it can be
    /// parked fully below the screen edge for the slide-up reveal.
    @State private var pickerHeight: CGFloat = 280

    /// How far portrait bottom-sheet popups sit up from the physical bottom edge: the real bottom
    /// safe-area inset plus breathing room, so their lowest content (and any toast) clears the home
    /// indicator and stays readable rather than jamming against the edge.
    private var portraitPopupBottomLift: CGFloat {
        max(CGFloat(feedSafeArea.bottom), 20) + 44
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(coordinateSpace: .global) { location in
                    model.handleBackdropTap(at: location)
                }

            switch panel {
            case .picker(let picker):
                // Resolution/codec drop *down* from their top-deck cell; the exposure settings rise
                // *up* from the capture bar — same `PickerPanel` drum and `panelRevealed` slide,
                // only anchor and direction differ. Portrait has no top-deck cells, so
                // resolution/codec take the same bottom sheet every other portrait picker uses.
                if picker.isTopBar && !isPortrait {
                    topPickerBody(picker)
                } else {
                    bottomPickerBody(picker)
                }
            case .assist(let tool):
                bottomAssistBody(tool)
            case .assistLibrary:
                AssistLibraryPanel()
                    .environment(model)
                    .frame(width: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            case .media:
                MediaBrowserView(safeArea: feedSafeArea)
                    .environment(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .settings:
                OperatorSettingsPanel(safeArea: feedSafeArea)
                    .environment(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Measures the live picker height so it can be parked fully off-screen for the slide.
    private var panelHeightReader: some View {
        GeometryReader { panelProxy in
            Color.clear
                .onAppear { pickerHeight = panelProxy.size.height }
                .onChange(of: panelProxy.size.height) { _, newHeight in
                    pickerHeight = newHeight
                }
        }
    }

    /// The assist options panel: right edge aligned to the view-assist toolbar, rising up from just
    /// below the screen edge on the left side — sharing `panelRevealed`.
    private func bottomAssistBody(_ tool: MonitorAssistTool) -> some View {
        GeometryReader { proxy in
            let host = proxy.frame(in: .global)
            let anchor = AssistOptionsPopupAnchor(
                host: host,
                toolbar: model.assistToolbarFrame,
                topSafeArea: feedSafeArea.top,
                leadingSafeArea: feedSafeArea.leading,
                preferredPanelWidth: assistPanelWidth(for: tool),
                chromeInsets: chromeInsets,
                panelHeight: pickerHeight,
                fallbackBottomClearance: chromeInsets.bottom + LiveDesign.controlHeight + 16,
                isPortrait: isPortrait,
                portraitBottomLift: portraitPopupBottomLift
            )
            AssistPanel(tool: tool)
                .environment(model)
                .id(tool)
                .transition(.opacity)
                .frame(width: anchor.panelWidth)
                .background(panelHeightReader)
                .offset(y: model.panelRevealed ? 0 : anchor.slide)
                .opacity(model.panelRevealed ? 1 : 0)
                .frame(
                    width: anchor.boxWidth, height: anchor.boxHeight, alignment: anchor.boxAlignment
                )
                .padding(.leading, anchor.leadingPadding)
                .padding(.top, anchor.topInset)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    /// The bottom-bar exposure picker: anchored to the capture bar's measured frame, rising up from
    /// just below the screen edge.
    private func bottomPickerBody(_ picker: CameraPicker) -> some View {
        GeometryReader { proxy in
            // Anchor to the capture bar's measured global frame (mockup `.pk-card`). The host is
            // only the safe-area-inset width while the bar draws full-bleed, so size a box whose
            // bottom-right corner *is* the bar's top-right corner and align `.bottomTrailing`.
            let host = proxy.frame(in: .global)
            let bar = model.captureBarFrame
            // Belt-and-suspenders alongside the onDisappear reset in MonitorCaptureStrip: the bar
            // frame only means anything in landscape (this popup only anchors to the landscape body).
            let hasBar = !isPortrait && bar.width > 1
            // Landscape command mode (DISP 3) has no capture bar to anchor to and the whole screen
            // is the command dashboard, so centre the picker dead-centre rather than dropping it in
            // the trailing-inset corner.
            let isCommandCenter = !isPortrait && model.displayMode == .command
            let gap: CGFloat = 10
            // Portrait: no capture bar to anchor to — the sheet sits full-width (minus a 12pt
            // margin per side) with its bottom edge AT the screen bottom, overlapping the system
            // bar, instead of the landscape 420pt box that stops above the bar.
            let width = hasBar ? bar.width : (isPortrait ? max(0, host.width - 24) : 420)
            let boxWidth =
                hasBar
                ? max(0, bar.maxX - host.minX)
                : (isPortrait || isCommandCenter
                    ? host.width : max(0, host.width - chromeInsets.trailing))
            let boxHeight =
                hasBar
                ? max(0, bar.minY - gap - host.minY)
                : (isCommandCenter
                    ? host.height
                    : (isPortrait
                        ? max(0, host.height - portraitPopupBottomLift)
                        : max(
                            0, host.height - (chromeInsets.bottom + LiveDesign.controlHeight + 16))))
            let alignment: Alignment =
                isCommandCenter ? .center : ((hasBar || !isPortrait) ? .bottomTrailing : .bottom)
            // Hidden state parks the panel fully below the screen's bottom edge; the reveal then
            // slides it up into place (and the dismiss reverses it).
            let slide = (host.height - boxHeight) + pickerHeight + 20
            pickerBodyContent(picker)
                .environment(model)
                // Keying by picker makes a switch between settings cross-fade the contents in place,
                // while the slide container below stays put.
                .id(picker)
                .transition(.opacity)
                .frame(width: width)
                .background(panelHeightReader)
                .offset(y: model.panelRevealed ? 0 : slide)
                .opacity(model.panelRevealed ? 1 : 0)
                .frame(width: boxWidth, height: boxHeight, alignment: alignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The slide reveal is driven from `NativeAppModel.schedulePanelReveal()` on present — not a
        // panel `.onAppear` — so a spam-tap reuse of the still-fading view can't strand it off-screen.
        .ignoresSafeArea()
    }

    /// The bottom-bar picker's contents: every setting shares the `PickerPanel` drum except
    /// Stabilization, whose VR / e-VR pair is two independent on/off toggles, not a value wheel.
    @ViewBuilder
    private func pickerBodyContent(_ picker: CameraPicker) -> some View {
        if picker == .stabilization {
            GlassPanel(
                padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    // The two-row VR + e-VR panel: label it for what it controls rather than the
                    // compact "STAB" cell tag (`valueLabel`, kept for the reverse-lookup key).
                    PickerHeader(label: "VR / E-VR", subtitle: picker.subtitle) {
                        model.dismissActivePanel()
                    }
                    StabilizationPickerPanel()
                }
            }
        } else {
            PickerPanel(picker: picker)
        }
    }

    /// The top-deck picker (resolution / codec): anchored just beneath its cell, dropping *down*
    /// from above the screen edge. Frame + offset (never `.position`) so the header can't clip.
    private func topPickerBody(_ picker: CameraPicker) -> some View {
        GeometryReader { proxy in
            let host = proxy.frame(in: .global)
            let cell = model.topBarPickerFrames[picker] ?? .zero
            let hasCell = cell.width > 1
            // Landscape command mode has no top-deck cell to anchor to, so centre the resolution/
            // codec popup dead-centre like the other command pickers instead of the top-left corner.
            let isCommandCenter = !isPortrait && model.displayMode == .command
            let gap: CGFloat = 8
            let width: CGFloat = 340
            // Centre the popup on the cell, clamped so it never runs off either screen edge.
            let rawLeading = cell.midX - width / 2
            let leading =
                isCommandCenter
                ? host.midX - width / 2
                : (hasCell
                    ? min(max(rawLeading, host.minX + 8), host.maxX - width - 8)
                    : host.minX + 8)
            // Top edge sits a hair below the cell; the hidden state parks it fully above the screen.
            let top =
                isCommandCenter
                ? host.midY - pickerHeight / 2
                : (hasCell ? (cell.maxY + gap) : (host.minY + chromeInsets.top + 8))
            let slide = (top - host.minY) + pickerHeight + 40
            PickerPanel(picker: picker)
                .environment(model)
                .id(picker)
                .transition(.opacity)
                .frame(width: width)
                .background(panelHeightReader)
                .opacity(model.panelRevealed ? 1 : 0)
                .offset(
                    x: leading - host.minX,
                    y: (top - host.minY) + (model.panelRevealed ? 0 : -slide)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

/// The capture-picker header: a heavy setting label with its dimmed descriptor inline and a
/// trailing close button. Shared by the bottom-bar `PickerPanel` and the top-bar drum popdowns so
/// the two read identically.
struct PickerHeader: View {
    let label: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 18, weight: .heavy, design: .default))
                    .kerning(2)
                    .foregroundStyle(LiveDesign.text)
                    // The setting name is the anchor of the header — never let it wrap to a second
                    // line (e.g. "RESOLUTION" in the narrower top-bar popdown).
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .kerning(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(LiveDesign.faint)
            }
            Spacer(minLength: 8)
            CloseButton(action: onClose)
        }
    }
}

struct PickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    let picker: CameraPicker
    @State private var selectedMode = 0
    /// The drum's centred value. Seeded from camera state on appear, then applied each time the
    /// drum snaps to a new value, so the operator doesn't have to dismiss to confirm.
    @State private var selection = ""
    /// Last value written to the camera, so re-centring on the same value (including the initial
    /// seed) doesn't fire a redundant write.
    @State private var lastApplied = ""
    /// IRIS apertures the mounted lens can reach, captured on appear (never read from camera state
    /// in `body` — that reassigns every live-view frame and would jog the wheel mid-spin).
    @State private var lensApertures: [String] = []
    /// Recording modes the camera advertises, captured on appear so the resolution wheel only
    /// offers values the body will accept.
    @State private var screenModes: [String] = []
    /// Codecs the camera advertises, captured on appear (same rationale as `screenModes`).
    @State private var codecModes: [String] = []

    private var isShutterControlLocked: Bool {
        picker == .shutter && model.lockedControls.contains(.shutter)
    }

    private var isISORecordingLocked: Bool {
        picker == .iso && model.isISORecordingLocked
    }

    private var isPickerInteractionLocked: Bool {
        isShutterControlLocked || isISORecordingLocked
    }

    private var activePickerModes: [PickerMode] {
        model.pickerModes(for: picker)
    }

    /// WB's "Tint" tab renders the fine-tune pad instead of a value drum.
    private var isTintMode: Bool {
        picker == .whiteBalance
            && activePickerModes.indices.contains(selectedMode)
            && activePickerModes[selectedMode].title == "Tint"
    }

    var body: some View {
        GlassPanel(
            padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if isShutterControlLocked {
                    shutterLockBanner
                }
                if isISORecordingLocked {
                    isoRecordingLockBanner
                }
                if isTintMode {
                    // The WB Tint tab swaps the drum for the fine-tune pad.
                    WhiteBalanceTintPad()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AccentDrumWheel(
                        options: currentOptions,
                        selection: $selection,
                        markedValues: markedValues,
                        isInteractive: !isPickerInteractionLocked
                    )
                    // Fresh wheel per mode tab: ANGLE→SPEED (or ISO Low→High) swaps the option set
                    // *and* the centred value at once, which `.scrollPosition` alone doesn't follow
                    // reliably; re-identifying re-runs onAppear to land centred on the new value.
                    .id(selectedMode)
                }
                if !activePickerModes.isEmpty {
                    modeBar
                }
            }
        }
        // Seed once on appear — NOT in `body`. Camera state is reassigned every live-view frame, so
        // reading it per render would re-render the drum mid-spin and break its momentum. Open on the
        // mode the current value lives in (e.g. ISO 800 → Low Base, focus AF-C → AF Mode).
        .onAppear {
            if picker == .iris {
                lensApertures = model.irisApertures
            }
            if picker == .resolution {
                screenModes = model.resolutionOptions
            }
            if picker == .codec {
                codecModes = model.codecOptions
            }
            // Dual-circuit pickers always open on the camera's active circuit (`movieBaseISO` /
            // `movieShutterMode`), never via overlapping ISO steps or `showPicker`'s default mode.
            if picker == .iso {
                selectedMode = model.isoPickerModeIndex
            } else if picker == .shutter {
                selectedMode = model.shutterPickerModeIndex
            } else if selection.isEmpty {
                if let initial = model.pickerInitialMode {
                    selectedMode = initial
                    model.pickerInitialMode = nil
                } else {
                    let live = model.cameraValue(for: picker)
                    if let idx = activePickerModes.firstIndex(where: { $0.options.contains(live) })
                    {
                        selectedMode = idx
                    }
                }
            }
            if selection.isEmpty {
                let seeded = model.pickerModeValue(picker, mode: selectedMode)
                selection = seeded
                lastApplied = seeded
            }
        }
        // Keep the ANGLE/SPEED tab aligned when the camera (or a rejected write) changes mode.
        .onChange(of: model.shutterPickerModeIndex) { _, modeIndex in
            guard picker == .shutter, selectedMode != modeIndex else { return }
            selectedMode = modeIndex
            let value = model.pickerModeValue(picker, mode: modeIndex)
            selection = value
            lastApplied = value
        }
        // Keep the LOW/HIGH base tab aligned with `movieBaseISO` readback (R3D NE only).
        .onChange(of: model.isoPickerModeIndex) { _, modeIndex in
            guard picker == .iso, model.showsDualBaseISOPicker, selectedMode != modeIndex else {
                return
            }
            selectedMode = modeIndex
            let value = model.pickerModeValue(picker, mode: modeIndex)
            selection = value
            lastApplied = value
        }
        // Confirm-on-snap: apply each newly-centred value to the active mode's target.
        .onChange(of: selection) { _, newValue in
            guard !isPickerInteractionLocked else { return }
            guard !newValue.isEmpty, newValue != lastApplied else { return }
            lastApplied = newValue
            model.applyPicker(picker, mode: selectedMode, value: newValue)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            guard picker == .shutter else { return }
            if model.preferences.hapticsEnabled {
                if isShutterControlLocked {
                    OperatorSettingsHaptics.unlockConfirm()
                } else {
                    OperatorSettingsHaptics.lockConfirm()
                }
            }
            if isShutterControlLocked {
                model.unlockShutterControlOnCamera()
            } else {
                model.lockShutterControlOnCamera()
            }
        } onPressingChanged: { pressing in
            guard picker == .shutter, pressing else { return }
            model.connectionMessage =
                isShutterControlLocked
                ? "Hold to unlock shutter control on camera"
                : "Hold to lock shutter control on camera"
        }
    }

    /// Banner shown when the camera's shutter control lock is engaged — the drum is dimmed and
    /// non-interactive until the operator long-presses to queue an unlock write.
    private var shutterLockBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Shutter locked on camera — hold anywhere to unlock")
                .font(.system(size: 11.5, weight: .medium, design: .default))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(LiveDesign.accent.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.accentDim, in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius))
    }

    /// Banner shown when ISO cannot be changed during an R3D NE recording.
    private var isoRecordingLockBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 11, weight: .semibold))
            Text("ISO is locked while recording in R3D NE")
                .font(.system(size: 11.5, weight: .medium, design: .default))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(LiveDesign.rec.opacity(0.95))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.rec.opacity(0.12),
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius))
    }

    /// Native-base values flagged with stars in the ISO drum.
    private var markedValues: Set<String> {
        guard picker == .iso else {
            guard activePickerModes.indices.contains(selectedMode) else { return [] }
            let base = activePickerModes[selectedMode].base
            return base.isEmpty ? [] : [base]
        }
        return ISOPickerPolicy.markedValues(
            codec: model.cameraState.codec, modeIndex: selectedMode)
    }

    /// Setting name in bold with its dimmed descriptor inline, and an X close button trailing so
    /// the way out of the menu is explicit (in addition to tapping off).
    private var header: some View {
        PickerHeader(label: picker.valueLabel, subtitle: model.pickerSubtitle(for: picker)) {
            model.dismissActivePanel()
        }
    }

    /// Segmented tabs (e.g. ANGLE / SPEED) beneath the wheel; the active tab is gold-outlined.
    private var modeBar: some View {
        HStack(spacing: 10) {
            ForEach(Array(activePickerModes.enumerated()), id: \.offset) { index, mode in
                let active = index == selectedMode
                Button {
                    guard !isPickerInteractionLocked else { return }
                    selectedMode = index
                    // Re-centre on the mode's own value: a circuit's base (ISO High → 6400) or an
                    // independent FOCUS tab's stored value.
                    let value = model.pickerModeValue(picker, mode: index)
                    selection = value
                    lastApplied = value
                    // ISO's circuits are the camera's dual base — switch the base on the camera
                    // first, before the new ISO value is applied below.
                    if picker == .iso, model.showsDualBaseISOPicker {
                        model.switchBaseISO(highBase: index == 1)
                    }
                    if picker == .shutter {
                        model.switchShutterMode(speedMode: index == 1)
                    }
                    // Switching a circuit is itself a camera change, so confirm the mode's value
                    // right away — no drum nudge needed. Exceptions: shutter ANGLE/SPEED only
                    // selects the active stored circuit (`movieShutterMode`; a value write here
                    // can fail and falsely engage lock), and FOCUS tabs are independent settings,
                    // so switching writes nothing. `lastApplied` is pre-set above so this write
                    // isn't duplicated by the `selection` `onChange`.
                    if picker != .focus, picker != .shutter {
                        model.applyPicker(picker, mode: index, value: value)
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(mode.title)
                            .font(.system(size: 13, weight: .bold, design: .default))
                            .kerning(0.5)
                            .textCase(.uppercase)
                        if let detail = mode.detail {
                            Text(detail)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundStyle(active ? LiveDesign.accent : LiveDesign.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, mode.detail == nil ? 12 : 9)
                    .background(
                        active ? LiveDesign.accentDim : LiveDesign.background.opacity(0.28),
                        in: RoundedRectangle(
                            cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                            .stroke(
                                active ? LiveDesign.accent : LiveDesign.hairline, lineWidth: 1.5)
                    }
                }
                .buttonStyle(.zcTapTarget)
                .opacity(isPickerInteractionLocked ? 0.55 : 1)
                .allowsHitTesting(!isPickerInteractionLocked)
            }
        }
    }

    private var currentValue: String {
        switch picker {
        case .resolution: model.cameraState.resolutionFrameRate
        case .codec: model.cameraState.codec
        case .mode: model.commandExposureMode
        default:
            model.cameraState.values.first(where: { $0.label == picker.valueLabel })?.value ?? ""
        }
    }

    /// The drum's options for the active mode. IRIS is restricted to the mounted lens's reachable
    /// apertures; moded settings (ISO circuits, shutter angle/speed) swap the wheel per mode; the
    /// rest fall back to the flat picker list.
    private var currentOptions: [String] {
        if picker == .iris, !lensApertures.isEmpty { return lensApertures }
        if picker == .resolution, !screenModes.isEmpty { return screenModes }
        if picker == .codec, !codecModes.isEmpty { return codecModes }
        if picker == .iso {
            return ISOPickerPolicy.options(
                codec: model.cameraState.codec, modeIndex: selectedMode)
        }
        // Camera-advertised options for the active mode (focus tabs, shutter angle/speed, WB preset)
        // take precedence over the hardcoded list. Read live from the model — the ZR refreshes the
        // speed enum only after switching to speed mode, so a one-shot capture on appear would stick
        // on the single placeholder value advertised while in angle mode.
        if let property = picker.optionProperty(forMode: selectedMode),
            let cameraMode = model.cameraControlOptions[property], cameraMode.count > 1
        {
            return cameraMode
        }
        guard !activePickerModes.isEmpty else { return picker.options }
        let hardcoded = activePickerModes[selectedMode].options
        return hardcoded.isEmpty ? picker.options : hardcoded
    }
}

/// Stabilization picker (movie VR + electronic VR) for the command monitor's VR tile. Unlike the
/// other settings, VR and e-VR are two independent on/off-style toggles rather than one value wheel,
/// so this renders its own row-of-buttons layout instead of `PickerPanel`'s `AccentDrumWheel`.
struct StabilizationPickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    /// Bumped when the operator taps the disabled e-VR row, to flash the "unavailable in RAW" toast.
    @State private var evrBlockedNotice = 0

    private var vrOptions: [String] {
        // No runtime enumeration for this one: 2-byte 0xDxxx props have no describe op on this
        // body, so `.movieVibrationReduction` is deliberately left out of `enumeratedControls` and
        // this hardcoded ladder is the only source of options.
        model.cameraControlOptions[.movieVibrationReduction] ?? ["OFF", "ON", "SPORT"]
    }

    /// Electronic VR can't be applied to a RAW stream (R3D NE / N-RAW / ProRes RAW HQ), so the row
    /// is disabled with an explanatory toast rather than silently rejecting the write.
    private var electronicVRUnavailable: Bool {
        MonitorTextFormat.isRawCodec(model.cameraState.codec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            optionRow(
                title: "VR", options: vrOptions,
                selected: model.stabilizationVR
            ) { model.setVibrationReduction($0) }
            optionRow(
                title: "e-VR", options: ["OFF", "ON"],
                selected: model.stabilizationElectronicVR,
                disabled: electronicVRUnavailable,
                onDisabledTap: { evrBlockedNotice += 1 }
            ) { model.setElectronicVR(on: $0 == "ON") }
        }
        // No outer padding — `pickerBodyContent` already wraps this in a padded GlassPanel, so an
        // extra .padding(16) doubled the inset to ~36pt. The toast floats ABOVE the sheet header
        // so it's never cut off at the bottom edge.
        .overlay(alignment: .top) {
            MonitorToast(text: "e-VR is unavailable in RAW codecs", trigger: evrBlockedNotice)
                .offset(y: -52)
        }
    }

    private func optionRow(
        title: String, options: [String], selected: String?,
        disabled: Bool = false,
        onDisabledTap: (() -> Void)? = nil,
        action: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiveDesign.muted)
                .frame(width: 44, alignment: .leading)
            ForEach(options, id: \.self) { option in
                Button {
                    if disabled {
                        onDisabledTap?()
                    } else {
                        action(option)
                    }
                } label: {
                    Text(option)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(option == selected ? LiveDesign.accent : LiveDesign.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                                .fill(
                                    option == selected
                                        ? LiveDesign.accentDim : LiveDesign.surface)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        // Grey the whole row when disabled; it stays tappable so the toast can explain why.
        .opacity(disabled ? 0.35 : 1)
    }
}

/// A drum-style value wheel with the wireframe's look: a momentum scroll that snaps (`viewAligned`)
/// to each value like a drum, with the centred value enlarged and gold, the rest dimmed, bracketed
/// by hairlines and faded at the edges. The centred value is reported through `selection`, updating
/// as the drum locks onto each detent.
struct AccentDrumWheel: View {
    let options: [String]
    @Binding var selection: String
    /// Options to flag with small stars (e.g. native base ISO values).
    var markedValues: Set<String> = []
    /// When false the wheel is dimmed and non-scrollable (camera control lock engaged).
    var isInteractive: Bool = true

    /// Overall wheel height; callers can shrink it (e.g. the LUT picker, to leave room for tabs).
    var wheelHeight: CGFloat = 176
    /// Optional native long-press action for removable values. Omit it for protected wheels.
    var onDeleteOption: ((String) -> Void)? = nil

    /// Row pitch — a good bit taller than the glyphs so there's clear spacing between options.
    private let rowHeight: CGFloat = 52

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        let isCentered = option == selection
                        optionRow(option, isCentered: isCentered)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(
                id: Binding(get: { selection }, set: { if let value = $0 { selection = value } })
            )
            .scrollDisabled(!isInteractive)
            .opacity(isInteractive ? 1 : 0.55)
            // Symmetric margins let the first/last option reach the centre, so the snapped row sits
            // between the hairlines.
            .contentMargins(.vertical, (wheelHeight - rowHeight) / 2, for: .scrollContent)
            .frame(height: wheelHeight)
            // A light tick as the wheel snaps onto each value.
            .sensoryFeedback(.selection, trigger: selection)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.22),
                        .init(color: .black, location: 0.78),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay {
                Rectangle().fill(LiveDesign.hairlineStrong).frame(height: 1)
                    .offset(y: -rowHeight / 2)
                Rectangle().fill(LiveDesign.hairlineStrong).frame(height: 1)
                    .offset(y: rowHeight / 2)
            }
            // `scrollPosition` only reacts to *changes*, not the initial value, so place the wheel on
            // the current selection explicitly once the rows have laid out. (Switching tabs makes a
            // fresh wheel, so its own onAppear lands it on that tab's look.)
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func optionRow(_ option: String, isCentered: Bool) -> some View {
        let row = HStack(spacing: 6) {
            Text(option)
                .font(
                    .system(
                        size: isCentered ? 30 : 23,
                        weight: isCentered ? .semibold : .regular,
                        design: .monospaced)
                )
                // Long values shrink to fit the row rather than truncating.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if markedValues.contains(option) {
                Image(systemName: "star.fill")
                    .font(.system(size: isCentered ? 13 : 10))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(isCentered ? LiveDesign.accent : LiveDesign.muted.opacity(0.7))
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .id(option)

        if let onDeleteOption {
            row
                .contextMenu {
                    Button(role: .destructive) {
                        onDeleteOption(option)
                    } label: {
                        Label("Delete LUT", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: Text("Delete \(option)")) {
                    onDeleteOption(option)
                }
        } else {
            row
        }
    }
}

struct AssistQuickSettingsContent: View {
    @Environment(NativeAppModel.self) private var model
    let tool: MonitorAssistTool
    /// Narrow two-column operator-setup cards pass `true` so segmented controls share column width.
    var compact: Bool = false

    var body: some View {
        switch tool {
        case .falseColor:
            falseColorRows
        case .zebra:
            zebraRows
        case .waveform:
            waveformRows
        case .parade:
            paradeRows
        case .histogram:
            histogramRows
        case .vectorscope:
            vectorscopeRows
        case .trafficLights:
            trafficLightsRows
        case .peaking:
            peakingRows
        default:
            EmptyView()
        }
    }

    private var falseColorRows: some View {
        Group {
            SettingsInlineRow(
                title: "Scale",
                help:
                    "The camera signal selects Log3G10 or N-Log automatically. ZC Stops marks minimum exposure, −3, 18% gray, skin, +2, and three clip-relative highlight levels over luminance grayscale. IRE uses RED Video Mode-style monitor ranges after curve-aware display mapping, with 18% gray at 42 IRE and the camera clip at 100. Limits paints only shadow and highlight warnings, leaving other colors untouched.",
                showTopDivider: false,
                stacked: compact
            ) {
                SettingsSegmented(
                    options: ["ZC Stops", "IRE", "Limits"],
                    selected: falseColorScaleLabel,
                    compact: compact,
                    stacked: compact
                ) {
                    model.assistConfiguration.falseColorScale = falseColorScale(for: $0)
                }
            }
            SettingsSwitchInlineRow(
                title: "Reference Display",
                help: "Show a compact color key over live view while False Color is active.",
                stacked: compact,
                isOn: model.assistConfiguration.falseColorReferenceEnabled
            ) {
                model.assistConfiguration.falseColorReferenceEnabled.toggle()
                if model.assistConfiguration.falseColorReferenceEnabled {
                    model.setAssist(.falseColor, visible: true)
                }
            }
        }
    }

    private var falseColorScaleLabel: String {
        switch model.assistConfiguration.falseColorScale {
        case .stops: "ZC Stops"
        case .ire: "IRE"
        case .limits: "Limits"
        }
    }

    private func falseColorScale(for label: String) -> FalseColorScale {
        switch label {
        case "IRE": .ire
        case "Limits": .limits
        default: .stops
        }
    }

    private var zebraRows: some View {
        Group {
            SettingsInlineRow(
                title: "Units",
                help:
                    "Switch between Nikon-style native 0-255 codes and OpenZCine's normalized 0-100 monitoring IRE scale.",
                showTopDivider: false,
                stacked: compact
            ) {
                SettingsSegmented(
                    options: ["0-255", "IRE"],
                    selected: model.assistConfiguration.zebra.unit == .native
                        ? "0-255" : "IRE",
                    compact: compact,
                    stacked: compact
                ) {
                    model.assistConfiguration.zebra.unit = $0 == "0-255" ? .native : .ire
                }
            }
            zebraZoneRow(
                title: "Highlight",
                help:
                    "High zebra warns when bright detail approaches clipping after the active log curve is compensated.",
                enabled: model.assistConfiguration.zebra.highlightEnabled,
                onEnabledToggle: { model.assistConfiguration.zebra.highlightEnabled.toggle() },
                value: Binding(
                    get: {
                        model.assistConfiguration.zebra.displayValue(
                            for: model.assistConfiguration.zebra.highlightIRE,
                            mapping: model.exposureSignalMapping)
                    },
                    set: {
                        model.assistConfiguration.zebra.setHighlight(
                            fromDisplay: $0, mapping: model.exposureSignalMapping)
                    }),
                maxValue: model.assistConfiguration.zebra.unit == .native ? 255 : 100,
                colors: SettingsPalette.highlight,
                selectedColor: model.assistConfiguration.zebra.highlightColor.rawValue,
                onColor: { color in
                    if let parsed = AssistConfiguration.Zebra.StripeColor(rawValue: color) {
                        model.assistConfiguration.zebra.highlightColor = parsed
                    }
                })
            zebraZoneRow(
                title: "Midtone",
                help:
                    "Midtone zebra gives a curve-compensated reference band for faces or key subject exposure.",
                enabled: model.assistConfiguration.zebra.midtoneEnabled,
                onEnabledToggle: { model.assistConfiguration.zebra.midtoneEnabled.toggle() },
                value: Binding(
                    get: {
                        model.assistConfiguration.zebra.displayValue(
                            for: model.assistConfiguration.zebra.midtoneIRE,
                            mapping: model.exposureSignalMapping)
                    },
                    set: {
                        model.assistConfiguration.zebra.setMidtone(
                            fromDisplay: $0, mapping: model.exposureSignalMapping)
                    }),
                maxValue: model.assistConfiguration.zebra.unit == .native ? 255 : 100,
                colors: SettingsPalette.midtone,
                selectedColor: model.assistConfiguration.zebra.midtoneColor.rawValue,
                onColor: { color in
                    if let parsed = AssistConfiguration.Zebra.StripeColor(rawValue: color) {
                        model.assistConfiguration.zebra.midtoneColor = parsed
                    }
                })
        }
    }

    private var waveformRows: some View {
        Group {
            SettingsInlineRow(title: "Mode", showTopDivider: false, stacked: compact) {
                SettingsSegmented(
                    options: AssistConfiguration.Scopes.WaveformMode.allCases.map(\.rawValue),
                    selected: model.assistConfiguration.scopes.waveformMode.rawValue,
                    compact: compact,
                    stacked: compact
                ) {
                    if let mode = AssistConfiguration.Scopes.WaveformMode(rawValue: $0) {
                        model.assistConfiguration.scopes.waveformMode = mode
                    }
                }
            }
            SettingsInlineRow(
                title: "Brightness",
                help: "Raise trace intensity when the waveform is hard to read in bright light.",
                stacked: compact
            ) {
                SettingsPercentSlider(
                    value: Binding(
                        get: { model.assistConfiguration.scopes.waveformBrightness },
                        set: {
                            model.assistConfiguration.scopes.waveformBrightness =
                                AssistConfiguration.Scopes.clampedBrightness($0)
                        }),
                    range: AssistConfiguration.Scopes.brightnessRange)
            }
            SettingsSwitchInlineRow(
                title: "Safe Border Clip",
                stacked: compact,
                isOn: model.assistConfiguration.scopes.waveformGuides.clip
            ) { model.assistConfiguration.scopes.waveformGuides.clip.toggle() }
            SettingsSwitchInlineRow(
                title: "Safe Border Crush",
                stacked: compact,
                isOn: model.assistConfiguration.scopes.waveformGuides.crush
            ) { model.assistConfiguration.scopes.waveformGuides.crush.toggle() }
            SettingsSwitchInlineRow(
                title: "Middle Gray",
                stacked: compact,
                isOn: model.assistConfiguration.scopes.waveformGuides.middle
            ) { model.assistConfiguration.scopes.waveformGuides.middle.toggle() }
        }
    }

    private var paradeRows: some View {
        Group {
            SettingsInlineRow(title: "Mode", showTopDivider: false, stacked: compact) {
                SettingsSegmented(
                    options: AssistConfiguration.Scopes.ParadeMode.allCases.map(\.rawValue),
                    selected: model.assistConfiguration.scopes.paradeMode.rawValue,
                    compact: compact,
                    stacked: compact
                ) {
                    if let mode = AssistConfiguration.Scopes.ParadeMode(rawValue: $0) {
                        model.assistConfiguration.scopes.paradeMode = mode
                    }
                }
            }
            SettingsInlineRow(
                title: "Brightness",
                help: "Raise trace intensity when channel separation is hard to see.",
                stacked: compact
            ) {
                SettingsPercentSlider(
                    value: Binding(
                        get: { model.assistConfiguration.scopes.paradeBrightness },
                        set: {
                            model.assistConfiguration.scopes.paradeBrightness =
                                AssistConfiguration.Scopes.clampedBrightness($0)
                        }),
                    range: AssistConfiguration.Scopes.brightnessRange)
            }
            SettingsSwitchInlineRow(
                title: "Safe Border Clip",
                stacked: compact,
                isOn: model.assistConfiguration.scopes.paradeGuides.clip
            ) { model.assistConfiguration.scopes.paradeGuides.clip.toggle() }
            SettingsSwitchInlineRow(
                title: "Safe Border Crush",
                stacked: compact,
                isOn: model.assistConfiguration.scopes.paradeGuides.crush
            ) { model.assistConfiguration.scopes.paradeGuides.crush.toggle() }
            SettingsSwitchInlineRow(
                title: "Middle Gray",
                stacked: compact,
                isOn: model.assistConfiguration.scopes.paradeGuides.middle
            ) { model.assistConfiguration.scopes.paradeGuides.middle.toggle() }
        }
    }

    private var vectorscopeRows: some View {
        Group {
            SettingsInlineRow(
                title: "Trace Zoom",
                help:
                    "Magnifies only the chroma trace; the graticule stays at unity. The vectorscope reads the monitor image (your active LUT, or the built-in display tone map), where chroma is meaningful.",
                showTopDivider: false,
                stacked: compact
            ) {
                SettingsSegmented(
                    options: AssistConfiguration.Scopes.VectorscopeZoom.allCases.map(\.rawValue),
                    selected: model.assistConfiguration.scopes.vectorscopeZoom.rawValue,
                    compact: compact,
                    stacked: compact
                ) {
                    if let zoom = AssistConfiguration.Scopes.VectorscopeZoom(rawValue: $0) {
                        model.assistConfiguration.scopes.vectorscopeZoom = zoom
                    }
                }
            }
            SettingsInlineRow(
                title: "Brightness",
                help: "Raise trace intensity when the chroma plot is hard to read.",
                stacked: compact
            ) {
                SettingsPercentSlider(
                    value: Binding(
                        get: { model.assistConfiguration.scopes.vectorscopeBrightness },
                        set: {
                            model.assistConfiguration.scopes.vectorscopeBrightness =
                                AssistConfiguration.Scopes.clampedBrightness($0)
                        }),
                    range: AssistConfiguration.Scopes.brightnessRange)
            }
        }
    }

    private var histogramRows: some View {
        Group {
            SettingsSwitchInlineRow(
                title: "Traffic Lights",
                help: "Show small RGB edge blocks for crushed and clipped channels.",
                showTopDivider: false,
                stacked: compact,
                isOn: model.assistConfiguration.scopes.histogramTrafficLights
            ) { model.assistConfiguration.scopes.histogramTrafficLights.toggle() }
            SettingsInlineRow(
                title: "Crush/Clip Compensation",
                help:
                    "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter.",
                stacked: compact
            ) {
                SettingsCrushClipSegmented(
                    selected: model.assistConfiguration.scopes.crushClipCompensation,
                    compact: compact
                ) { match in
                    model.assistConfiguration.scopes.crushClipCompensation = match
                }
            }
        }
    }

    private var trafficLightsRows: some View {
        Group {
            SettingsInlineRow(
                title: "Crush/Clip Compensation",
                help:
                    "Stops of crush/clip tolerance before a channel indicator glows. Shared with the histogram traffic lights.",
                showTopDivider: false,
                stacked: compact
            ) {
                SettingsCrushClipSegmented(
                    selected: model.assistConfiguration.scopes.crushClipCompensation,
                    compact: compact
                ) { match in
                    model.assistConfiguration.scopes.crushClipCompensation = match
                }
            }
        }
    }

    private var peakingRows: some View {
        Group {
            SettingsInlineRow(
                title: "Sensitivity",
                help:
                    "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
                showTopDivider: false,
                stacked: compact
            ) {
                SettingsSegmented(
                    options: Peaking.Sensitivity.allCases.map(\.rawValue),
                    selected: model.assistConfiguration.peakingSensitivity.rawValue,
                    compact: compact,
                    stacked: compact
                ) {
                    if let level = Peaking.Sensitivity(rawValue: $0) {
                        model.assistConfiguration.peakingSensitivity = level
                    }
                }
            }
            SettingsInlineRow(
                title: "Color",
                help: "Choose the edge color that stays readable over your typical scene.",
                stacked: compact
            ) {
                SettingsColorDots(
                    dots: SettingsPalette.peaking,
                    selected: model.assistConfiguration.peakingColor.rawValue,
                    compact: compact
                ) {
                    if let color = Peaking.Color(rawValue: $0) {
                        model.assistConfiguration.peakingColor = color
                    }
                }
            }
        }
    }

    private func zebraZoneRow(
        title: String, help: String, enabled: Bool, onEnabledToggle: @escaping () -> Void,
        value: Binding<Int>, maxValue: Int, colors: [SettingsColorDots.Dot],
        selectedColor: String, onColor: @escaping (String) -> Void
    ) -> some View {
        SettingsInlineRow(title: title, help: help, stacked: compact) {
            if compact {
                HStack(spacing: 8) {
                    Button {
                        OperatorSettingsHaptics.selection(
                            enabled: model.preferences.hapticsEnabled)
                        onEnabledToggle()
                    } label: {
                        SettingsSwitchGraphic(isOn: enabled)
                    }
                    .buttonStyle(.zcTapTarget)
                    SettingsNumberField(value: value, maximum: maxValue)
                    Spacer(minLength: 4)
                    SettingsColorDots(
                        dots: colors, selected: selectedColor, compact: true, onSelect: onColor)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                        onEnabledToggle()
                    } label: {
                        SettingsSwitchGraphic(isOn: enabled)
                    }
                    .buttonStyle(.zcTapTarget)
                    SettingsNumberField(value: value, maximum: maxValue)
                    SettingsColorDots(dots: colors, selected: selectedColor, onSelect: onColor)
                }
            }
        }
    }
}

/// Popup width for long-press assist options — matches LUT / grid / level popups (guides is wider).
func assistPanelWidth(for tool: MonitorAssistTool) -> CGFloat {
    tool == .guides ? 472 : 400
}

struct AssistPanel: View {
    @Environment(NativeAppModel.self) private var model
    let tool: MonitorAssistTool
    /// When set, the header close control calls this instead of the default panel dismiss path.
    var onClose: (() -> Void)? = nil

    var body: some View {
        GlassPanel(
            padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label {
                        Text(tool.title)
                    } icon: {
                        AssistToolIcon(tool: tool, size: 15)
                    }
                    .font(.system(size: 15, weight: .bold, design: .default))
                    .kerning(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(LiveDesign.text)
                    Spacer()
                    CloseButton(action: onClose)
                }

                switch tool {
                case .guides:
                    SegmentedButtons(
                        items: AssistConfiguration.Guides.Family.allCases.map(\.rawValue),
                        selected: model.assistConfiguration.guides.family.rawValue
                    ) { value in
                        if let family = AssistConfiguration.Guides.Family(rawValue: value) {
                            model.assistConfiguration.guides.family = family
                        }
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10
                    ) {
                        // The active tab's ratios. Tapping toggles each in/out of the shared
                        // selection — several can be active at once, and the mask darkens the inverse
                        // of their union.
                        ForEach(
                            AssistConfiguration.Guides.AspectRatio.ratios(
                                for: model.assistConfiguration.guides.family)
                        ) { ratio in
                            Button {
                                model.assistConfiguration.guides.toggle(ratio)
                                model.setAssist(
                                    .guides,
                                    visible: !model.assistConfiguration.guides.selectedRatios
                                        .isEmpty)
                            } label: {
                                GlassChoice(
                                    title: ratio.rawValue,
                                    isSelected: model.assistConfiguration.guides.isSelected(ratio)
                                )
                            }
                            .buttonStyle(.zcTapTarget)
                        }
                    }
                    Button {
                        model.assistConfiguration.guides.maskEnabled.toggle()
                    } label: {
                        ToggleRow(
                            title: "Mask outside frame",
                            isOn: model.assistConfiguration.guides.maskEnabled
                        )
                    }
                    .buttonStyle(.zcTapTarget)
                case .grid:
                    HStack(spacing: 8) {
                        GridToggle(title: "Thirds", isOn: model.assistConfiguration.grid.thirds) {
                            model.assistConfiguration.grid.thirds.toggle()
                        }
                        GridToggle(title: "Phi Grid", isOn: model.assistConfiguration.grid.phi) {
                            model.assistConfiguration.grid.phi.toggle()
                        }
                        GridToggle(title: "Diagonal", isOn: model.assistConfiguration.grid.diagonal)
                        {
                            model.assistConfiguration.grid.diagonal.toggle()
                        }
                    }
                case .level:
                    SegmentedButtons(
                        items: AssistConfiguration.Level.Style.allCases.map(\.rawValue),
                        selected: model.assistConfiguration.level.style.rawValue
                    ) { value in
                        if let style = AssistConfiguration.Level.Style(rawValue: value) {
                            model.assistConfiguration.level.style = style
                        }
                    }
                case .desqueeze:
                    Button {
                        model.assistConfiguration.desqueeze.enabled.toggle()
                        model.setAssist(
                            .desqueeze,
                            visible: model.assistConfiguration.desqueeze.enabled
                        )
                    } label: {
                        ToggleRow(
                            title: "Enable", isOn: model.assistConfiguration.desqueeze.enabled)
                    }
                    .buttonStyle(.zcTapTarget)
                    SegmentedButtons(
                        items: AssistConfiguration.Desqueeze.Ratio.allCases.map(\.rawValue),
                        selected: model.assistConfiguration.desqueeze.ratio.rawValue
                    ) { value in
                        if let ratio = AssistConfiguration.Desqueeze.Ratio(rawValue: value) {
                            model.assistConfiguration.desqueeze.ratio = ratio
                        }
                    }
                    SegmentedButtons(
                        items: AssistConfiguration.Desqueeze.Orientation.allCases.map(\.rawValue),
                        selected: model.assistConfiguration.desqueeze.orientation.rawValue
                    ) { value in
                        if let orientation = AssistConfiguration.Desqueeze.Orientation(
                            rawValue: value)
                        {
                            model.assistConfiguration.desqueeze.orientation = orientation
                        }
                    }
                case .lut:
                    LUTPickerContent()
                case .falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope,
                    .trafficLights,
                    .peaking:
                    ScrollView {
                        AssistQuickSettingsContent(tool: tool)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: tool == .falseColor ? 110 : 360)
                case .crosshair:
                    Text("Tap the toolbar button to show or hide the centre crosshair.")
                        .font(.system(size: 13))
                        .foregroundStyle(LiveDesign.muted)
                case .audioMeters:
                    // Unreachable via long-press (`hasConfiguration == false`); kept for
                    // exhaustiveness and the Display settings strips.
                    Text("Meters the playing clip's audio. Available during media playback.")
                        .font(.system(size: 13))
                        .foregroundStyle(LiveDesign.muted)
                }
            }
        }
        // Swallow taps on the panel's own chrome so a mistap can't fall through to the backdrop
        // tap-catcher and dismiss it — only a tap *outside* closes. Buttons and the drum still
        // work: a child's own gesture takes priority over this container tap.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Anchor box for slide-up assist option popups — trailing edge pinned to the view-assist toolbar's
/// maxX on the left side, with leading clearance for the notch / Dynamic Island. Shared by live
/// monitor and playback.
private struct AssistOptionsPopupAnchor {
    let boxWidth: CGFloat
    let boxHeight: CGFloat
    let slide: CGFloat
    let topInset: CGFloat
    let leadingPadding: CGFloat
    let panelWidth: CGFloat
    let boxAlignment: Alignment

    init(
        host: CGRect,
        toolbar: CGRect,
        topSafeArea: CGFloat,
        leadingSafeArea: CGFloat,
        preferredPanelWidth: CGFloat,
        chromeInsets: MonitorEdgeInsets,
        panelHeight: CGFloat,
        fallbackBottomClearance: CGFloat,
        leadingClearance: CGFloat = 4,
        isPortrait: Bool = false,
        portraitBottomLift: CGFloat = 0
    ) {
        // Belt-and-suspenders alongside the onDisappear reset on assistToolbarFrame: the toolbar
        // frame only means anything in landscape (portrait never mounts that module). Defaults to
        // false so the media-playback call site — which owns its own toolbar frame lifecycle — is
        // unaffected.
        let hasToolbar = !isPortrait && toolbar.width > 1
        let gap: CGFloat = 10

        // Minimum global-X for the popup's leading edge — `chromeInsets` is a fixed margin that
        // ignores cutouts, so prefer the real safe-area leading inset when it is larger.
        let minLeadingX = host.minX + max(chromeInsets.leading, leadingSafeArea + leadingClearance)

        if hasToolbar {
            topInset = topSafeArea + 4
            let trailingX = toolbar.maxX
            // Box spans host leading → toolbar trailing; `.bottomTrailing` parks the popup there.
            boxWidth = max(0, trailingX - host.minX)
            let maxPanelWidth = max(0, trailingX - minLeadingX)
            panelWidth = min(preferredPanelWidth, maxPanelWidth)
            boxAlignment = .bottomTrailing
            leadingPadding = 0
            let rawBoxHeight = max(0, toolbar.minY - gap - host.minY)
            boxHeight = max(0, rawBoxHeight - topInset)
        } else if isPortrait {
            // Portrait: no toolbar to anchor to — a full-width bottom sheet (12pt margin per side),
            // lifted `portraitBottomLift` off the physical bottom edge so its lowest content (and
            // any toast) clears the home indicator.
            leadingPadding = 0
            topInset = 0
            boxWidth = host.width
            panelWidth = max(0, host.width - 24)
            boxAlignment = .bottom
            boxHeight = max(0, host.height - portraitBottomLift)
        } else {
            topInset = topSafeArea + 4
            // Toolbar not measured yet — fall back to a left-anchored band above the bottom chrome.
            leadingPadding = max(0, minLeadingX - host.minX)
            boxWidth = max(0, host.width - leadingPadding - chromeInsets.trailing)
            panelWidth = min(preferredPanelWidth, max(0, boxWidth))
            boxAlignment = .bottomLeading
            let rawBoxHeight = max(0, host.height - fallbackBottomClearance)
            boxHeight = max(0, rawBoxHeight - topInset)
        }
        slide = (host.height - boxHeight - topInset) + panelHeight + 20
    }
}

/// Slide-up assist options popup anchored above the view-assist toolbar — mirrors
/// `PanelHost.bottomAssistBody` for media playback (backdrop tap + identical width, padding, and reveal).
struct PlaybackAssistOptionsOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let tool: MonitorAssistTool
    let anchorToolbarFrame: CGRect
    let isRevealed: Bool
    let onBackdropTap: () -> Void
    var onClose: (() -> Void)? = nil
    var fallbackBottomClearance: CGFloat = 70
    @State private var panelHeight: CGFloat = 280

    var body: some View {
        GeometryReader { proxy in
            let host = proxy.frame(in: .global)
            let anchor = AssistOptionsPopupAnchor(
                host: host,
                toolbar: anchorToolbarFrame,
                topSafeArea: proxy.safeAreaInsets.top,
                leadingSafeArea: proxy.safeAreaInsets.leading,
                preferredPanelWidth: assistPanelWidth(for: tool),
                chromeInsets: .zero,
                panelHeight: panelHeight,
                fallbackBottomClearance: fallbackBottomClearance
            )

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { onBackdropTap() }

                AssistPanel(tool: tool, onClose: onClose)
                    .environment(model)
                    .id(tool)
                    .transition(.opacity)
                    .frame(width: anchor.panelWidth)
                    .background(panelHeightReader)
                    .offset(y: isRevealed ? 0 : anchor.slide)
                    .opacity(isRevealed ? 1 : 0)
                    .frame(
                        width: anchor.boxWidth, height: anchor.boxHeight,
                        alignment: anchor.boxAlignment
                    )
                    .padding(.leading, anchor.leadingPadding)
                    .padding(.top, anchor.topInset)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
    }

    private var panelHeightReader: some View {
        GeometryReader { panelProxy in
            Color.clear
                .onAppear { panelHeight = panelProxy.size.height }
                .onChange(of: panelProxy.size.height) { _, newHeight in
                    panelHeight = newHeight
                }
        }
    }
}

/// Tabbed LUT picker in the assist panel: category tabs over a drum of that category's looks.
struct LUTPickerContent: View {
    private struct PendingLUTDeletion: Identifiable {
        let category: LUTCategory
        let lut: StoredLUT
        var id: String { "\(category.rawValue):\(lut.fileName)" }
    }

    @Environment(NativeAppModel.self) private var model
    @State private var category: LUTCategory = .builtIn
    @State private var importing = false
    @State private var redFilter: RedOutputFilter = .all
    @State private var pendingDeletion: PendingLUTDeletion?
    @State private var deletionErrorMessage: String?
    /// Tracks whether a usable internet path exists, so the RED download (which needs the public
    /// internet) is blocked while the phone is on the camera's local-only Wi‑Fi AP.
    @State private var reachability = InternetReachability()

    /// Narrows the RED drum to one output color space (it ships ~16 looks per space).
    enum RedOutputFilter: String, CaseIterable {
        case all = "All"
        case rec709 = "Rec.709"
        case rec2020 = "Rec.2020"

        var match: String? {
            switch self {
            case .all: nil
            case .rec709: "REC709"
            case .rec2020: "REC2020"
            }
        }
    }

    /// Fixed height of the region below the tabs so the popup is the same size on every tab.
    private let contentHeight: CGFloat = 180
    private let footerHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 12) {
            SegmentedButtons(
                items: LUTCategory.allCases.map(\.rawValue),
                selected: category.rawValue
            ) { raw in
                guard let next = LUTCategory(rawValue: raw), next != category else { return }
                category = next
                // Switching tabs immediately applies that tab's look, so the live preview tracks the
                // tab without the operator having to nudge the drum first.
                applyRepresentativeLUT(for: next)
            }
            tabContent
                .frame(height: contentHeight)
        }
        .onAppear {
            model.refreshCustomLUTs()
            model.refreshRedLUTs()
            // Open on the tab of whatever's currently applied, so the drum lands on the live look.
            category = currentCategory
            // Warm the built-in cubes off the main thread so the first scroll doesn't hitch.
            Task.detached(priority: .utility) { LUTCubeCache.prewarmBuiltIns() }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.lut.displayName)?" } ?? "Delete LUT?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button("Delete LUT", role: .destructive) {
                    delete(pendingDeletion)
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the stored LUT from this device. This action cannot be undone.")
        }
        .alert(
            "Couldn’t Delete LUT",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } })
        ) {
            Button("OK") { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "The LUT could not be deleted.")
        }
    }

    /// The tab matching the currently-applied LUT, so the picker opens where the operator left off.
    private var currentCategory: LUTCategory {
        switch model.assistConfiguration.selectedLUT {
        case .builtIn: return .builtIn
        case .stored(let category, _): return category
        }
    }

    /// Applies a representative look when the operator switches to a tab: the current built-in (or
    /// Log3G10→709), the recommended RED default, or the first custom import. No-ops for an empty
    /// RED/Custom tab — its placeholder and import/download button shows instead.
    private func applyRepresentativeLUT(for category: LUTCategory) {
        switch category {
        case .builtIn:
            if case .builtIn = model.assistConfiguration.selectedLUT { return }
            model.assistConfiguration.selectedLUT = .builtIn(.log3G10Rec709)
        case .red:
            guard let lut = LUTLibraryIndex.defaultRedLUT(from: model.redLUTs) else { return }
            model.assistConfiguration.selectedLUT = .stored(category: .red, fileName: lut.fileName)
        case .custom:
            guard let lut = model.customLUTs.first else { return }
            model.assistConfiguration.selectedLUT = .stored(
                category: .custom, fileName: lut.fileName)
        }
        model.setAssist(.lut, visible: true)
    }

    @ViewBuilder private var tabContent: some View {
        switch category {
        case .builtIn:
            AccentDrumWheel(
                options: MonitorLUT.allCases.map(\.rawValue),
                selection: Binding(
                    get: {
                        if case .builtIn(let look) = model.assistConfiguration.selectedLUT {
                            return look.rawValue
                        }
                        return MonitorLUT.allCases.first?.rawValue ?? ""
                    },
                    set: { name in
                        guard let look = MonitorLUT(rawValue: name) else { return }
                        model.assistConfiguration.selectedLUT = .builtIn(look)
                        // Picking a look turns the LUT on; the bar toggle is the only "off".
                        model.setAssist(.lut, visible: true)
                    }
                ),
                wheelHeight: contentHeight
            )
        case .custom:
            customTab
        case .red:
            redTab
        }
    }

    /// Whether the RED download may be entered right now. Blocked (with a reason) while the phone
    /// is on the camera's Wi‑Fi AP or otherwise has no internet path, so the operator never lands
    /// on a broken/black download screen with no route to RED's servers.
    private var redDownloadAvailability: RedLUTDownloadAvailability {
        reachability.redLUTDownloadAvailability
    }

    @ViewBuilder private var redTab: some View {
        if model.redLUTs.isEmpty {
            VStack(spacing: 8) {
                placeholder(
                    "RED IPP2 LUTs",
                    redDownloadAvailability.blockedReason
                        ?? "Download RED's official looks — you'll accept RED's terms.")
                downloadRedButton
                    .frame(height: footerHeight)
            }
        } else {
            // Already downloaded — a color-space filter over the drum, no download button.
            VStack(spacing: 8) {
                redFilterRow
                redDrum
            }
        }
    }

    private var redFilterRow: some View {
        HStack(spacing: 6) {
            ForEach(RedOutputFilter.allCases, id: \.self) { filter in
                let isOn = redFilter == filter
                Button {
                    redFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(isOn ? LiveDesign.accent : LiveDesign.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isOn ? LiveDesign.accentDim : LiveDesign.glass, in: Capsule())
                }
                .buttonStyle(.zcTapTarget)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: redFilter) { _, _ in
            // Keep the applied RED LUT in sync with the visible drum: if the current selection falls
            // outside the new filter, snap to the filter's first item so the displayed and applied
            // looks can't diverge.
            guard case .stored(.red, let fileName) = model.assistConfiguration.selectedLUT else {
                return
            }
            if !filteredRedLUTs.contains(where: { $0.fileName == fileName }),
                let first = filteredRedLUTs.first
            {
                model.assistConfiguration.selectedLUT = .stored(
                    category: .red, fileName: first.fileName)
            }
        }
    }

    private var filteredRedLUTs: [StoredLUT] {
        let base =
            redFilter.match.map { needle in
                model.redLUTs.filter { $0.fileName.uppercased().contains(needle) }
            } ?? model.redLUTs
        // Float the recommended default (REC.709 Medium Contrast Soft) to the top so it's the first
        // item — and the one the drum lands on after a fresh download.
        guard let defaultLUT = LUTLibraryIndex.defaultRedLUT(from: model.redLUTs),
            let index = base.firstIndex(of: defaultLUT)
        else { return base }
        var reordered = base
        reordered.remove(at: index)
        reordered.insert(defaultLUT, at: 0)
        return reordered
    }

    /// The short name of the recommended default, flagged with a star in the drum.
    private var defaultRedShortName: String? {
        LUTLibraryIndex.defaultRedLUT(from: model.redLUTs).map { RedPresetName.short($0.fileName) }
    }

    private var redDrum: some View {
        AccentDrumWheel(
            options: filteredRedLUTs.map { RedPresetName.short($0.fileName) },
            selection: Binding(
                get: {
                    if case .stored(.red, let fileName) = model.assistConfiguration.selectedLUT,
                        filteredRedLUTs.contains(where: { $0.fileName == fileName }),
                        let lut = model.redLUTs.first(where: { $0.fileName == fileName })
                    {
                        return RedPresetName.short(lut.fileName)
                    }
                    return filteredRedLUTs.first.map { RedPresetName.short($0.fileName) } ?? ""
                },
                set: { shortName in
                    // Resolve within the *filtered* list so colliding short names across output
                    // spaces (Rec.709 vs Rec.2020) can't select the wrong stored file.
                    guard
                        let lut = filteredRedLUTs.first(where: {
                            RedPresetName.short($0.fileName) == shortName
                        })
                    else { return }
                    model.assistConfiguration.selectedLUT = .stored(
                        category: .red, fileName: lut.fileName)
                    model.setAssist(.lut, visible: true)
                }
            ),
            markedValues: defaultRedShortName.map { [$0] } ?? [],
            wheelHeight: contentHeight - 36,
            onDeleteOption: { shortName in
                guard
                    let lut = filteredRedLUTs.first(where: {
                        RedPresetName.short($0.fileName) == shortName
                    })
                else { return }
                pendingDeletion = PendingLUTDeletion(category: .red, lut: lut)
            }
        )
    }

    private var downloadRedButton: some View {
        // Enabled even while blocked: the download screen's gateway explains the block and, on
        // the camera AP, offers the internet hop (leave camera Wi‑Fi → download → reconnect).
        let isAvailable = redDownloadAvailability.isAvailable
        return Button {
            model.isRedDownloadPresented = true
        } label: {
            Label(
                "Download from RED",
                systemImage: isAvailable ? "arrow.down.circle" : "wifi.slash"
            )
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(LiveDesign.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LiveDesign.glassBright, in: Capsule())
        }
        .buttonStyle(.zcTapTarget)
    }

    @ViewBuilder private var customTab: some View {
        VStack(spacing: 8) {
            if model.customLUTs.isEmpty {
                placeholder("No custom LUTs yet", "Import a .cube file to add your own look.")
            } else {
                AccentDrumWheel(
                    options: model.customLUTs.map(\.displayName),
                    selection: Binding(
                        get: {
                            if case .stored(.custom, let fileName) = model.assistConfiguration
                                .selectedLUT,
                                let lut = model.customLUTs.first(where: { $0.fileName == fileName })
                            {
                                return lut.displayName
                            }
                            return model.customLUTs.first?.displayName ?? ""
                        },
                        set: { displayName in
                            guard
                                let lut = model.customLUTs.first(where: {
                                    $0.displayName == displayName
                                })
                            else { return }
                            model.assistConfiguration.selectedLUT = .stored(
                                category: .custom, fileName: lut.fileName)
                            model.setAssist(.lut, visible: true)
                        }
                    ),
                    wheelHeight: contentHeight - footerHeight - 8,
                    onDeleteOption: { displayName in
                        guard
                            let lut = model.customLUTs.first(where: {
                                $0.displayName == displayName
                            })
                        else { return }
                        pendingDeletion = PendingLUTDeletion(category: .custom, lut: lut)
                    }
                )
            }
            importButton
                .frame(height: footerHeight)
        }
    }

    private var importButton: some View {
        Button {
            importing = true
        } label: {
            Label("Import .cube", systemImage: "square.and.arrow.down")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(LiveDesign.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LiveDesign.glassBright, in: Capsule())
        }
        .buttonStyle(.zcTapTarget)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]
        ) { result in
            if case .success(let url) = result { model.importCustomLUT(from: url) }
        }
    }

    private func delete(_ pending: PendingLUTDeletion) {
        pendingDeletion = nil
        do {
            try model.deleteStoredLUT(pending.lut, from: pending.category)
            if pending.category == .red, filteredRedLUTs.isEmpty, !model.redLUTs.isEmpty {
                redFilter = .all
            }
        } catch {
            deletionErrorMessage = error.localizedDescription
        }
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(LiveDesign.text)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(LiveDesign.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AssistLibraryPanel: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("View Assist", systemImage: "rectangle.3.group")
                        .font(.system(size: 20, weight: .semibold, design: .default))
                        .foregroundStyle(LiveDesign.text)
                    Spacer()
                    CloseButton()
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(model.preferences.assistToolbarOrder) { tool in
                        Button {
                            model.toggleAssist(tool)
                            if tool.hasConfiguration {
                                model.showAssist(tool)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                AssistToolIcon(tool: tool, size: 17)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.title)
                                        .font(
                                            .system(size: 15, weight: .semibold, design: .rounded))
                                    Text(tool.rawValue)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(
                                    systemName: model.preferences.visibleAssistTools.contains(tool)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    model.preferences.visibleAssistTools.contains(tool)
                                        ? .blue : .secondary
                                )
                            }
                            .padding(12)
                            .background(
                                model.preferences.visibleAssistTools.contains(tool)
                                    ? LiveDesign.accentDim : LiveDesign.glassBright,
                                in: RoundedRectangle(
                                    cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: LiveDesign.cornerRadius, style: .continuous
                                )
                                .stroke(
                                    model.preferences.visibleAssistTools.contains(tool)
                                        ? LiveDesign.accentDim : LiveDesign.hairline,
                                    lineWidth: 1
                                )
                            }
                        }
                        .buttonStyle(.zcTapTarget)
                    }
                }
            }
        }
    }
}

/// Presentation-only mirror of the mockup's local assist/display state for controls the core model
/// does not persist yet. ponytail: lift these into OperatorPreferences/AssistConfiguration when the
/// live-view processor grows real support; for now they match the prototype's in-memory behaviour.

enum SettingsPalette {
    static let highlight: [SettingsColorDots.Dot] = [
        .init(name: "White", color: LiveDesign.text),
        .init(name: "Amber", color: LiveDesign.accent),
        .init(name: "Red", color: LiveDesign.rec),
    ]
    static let midtone: [SettingsColorDots.Dot] = [
        .init(name: "Amber", color: LiveDesign.accent),
        .init(name: "Cyan", color: LiveDesign.info),
        .init(name: "Green", color: LiveDesign.good),
    ]
    static let peaking: [SettingsColorDots.Dot] = [
        .init(name: "White", color: LiveDesign.text),
        .init(name: "Blue", color: LiveDesign.info),
        .init(name: "Red", color: LiveDesign.rec),
        .init(name: "Green", color: LiveDesign.good),
    ]
}

private struct ScrollViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum SettingsScrollMetrics {
    static let bottomCommitMinInterval: CFAbsoluteTime = 1.0 / 15.0
    static let bottomDeltaThreshold: CGFloat = 10
    /// Finger within this distance of the viewport top/bottom triggers auto-scroll.
    static let reorderEdgeThreshold: CGFloat = 56
    /// Peak auto-scroll speed (points per second) at the viewport edge.
    static let reorderMaxScrollSpeed: CGFloat = 220
    static let reorderScrollFrameInterval: UInt64 = 16_666_667
}

@MainActor
private final class SettingsScrollViewBox {
    weak var scrollView: UIScrollView?
}

/// Finds the enclosing `UIScrollView` so settings can auto-scroll during reorder drags, restore a
/// saved offset when the tab reappears, and persist scroll position back to session state.
private struct SettingsScrollViewFinder: UIViewRepresentable {
    let box: SettingsScrollViewBox
    var restoreOffset: CGFloat
    var onOffsetChange: (CGFloat) -> Void
    var onMoreBelowChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let restore = restoreOffset
        DispatchQueue.main.async {
            Task { @MainActor in
                guard let scrollView = uiView.enclosingScrollView else { return }
                context.coordinator.attach(
                    scrollView: scrollView,
                    box: box,
                    restoreOffset: restore,
                    onOffsetChange: onOffsetChange,
                    onMoreBelowChange: onMoreBelowChange
                )
            }
        }
    }

    @MainActor
    final class Coordinator {
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var sizeObservation: NSKeyValueObservation?
        private var didRestore = false
        private var lastReported: CGFloat = -1
        private var lastCommit: CFAbsoluteTime = 0
        private var lastMoreReported: CGFloat = -1
        private var onOffsetChange: ((CGFloat) -> Void)?
        private var onMoreBelowChange: ((CGFloat) -> Void)?

        func attach(
            scrollView: UIScrollView,
            box: SettingsScrollViewBox,
            restoreOffset: CGFloat,
            onOffsetChange: @escaping (CGFloat) -> Void,
            onMoreBelowChange: @escaping (CGFloat) -> Void
        ) {
            self.onOffsetChange = onOffsetChange
            self.onMoreBelowChange = onMoreBelowChange
            box.scrollView = scrollView
            if observedScrollView !== scrollView {
                observedScrollView = scrollView
                didRestore = false
                observation?.invalidate()
                sizeObservation?.invalidate()
                observation = scrollView.observe(\.contentOffset, options: [.new]) {
                    [weak self] scrollView, change in
                    guard change.newValue != nil else { return }
                    Task { @MainActor in
                        self?.reportOffset(scrollView)
                        self?.reportMoreBelow(scrollView)
                    }
                }
                // Content height changes on tab switch (and as rows expand) without any scroll, so
                // the "more below" cue must be recomputed from the size too, not only on offset.
                sizeObservation = scrollView.observe(\.contentSize, options: [.new]) {
                    [weak self] scrollView, _ in
                    Task { @MainActor in
                        self?.reportMoreBelow(scrollView)
                    }
                }
            }
            guard !didRestore else { return }
            didRestore = true
            scrollView.layoutIfNeeded()
            // Clamp to the in-bounds range: restoring past maxOffset would land the scroll view
            // overscrolled and immediately bounce.
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let target = min(max(restoreOffset, 0), maxOffset)
            if target > 0.5 {
                scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
            reportMoreBelow(scrollView)
        }

        private func reportOffset(_ scrollView: UIScrollView) {
            guard let onOffsetChange else { return }
            let offset = scrollView.contentOffset.y
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            // Only persist SETTLED, in-bounds positions. While the scroll view rubber-bands past
            // either edge, `contentOffset.y` overshoots (negative at the top, > maxOffset at the
            // bottom); persisting that bounce position — and restoring it on any later re-find of
            // the scroll view — re-drives the bounce, which is the "stuck bouncing at the bottom"
            // glitch. The bottom itself (offset == maxOffset) is in-bounds and still persists.
            guard offset >= 0, offset <= maxOffset else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard abs(offset - lastReported) > SettingsScrollMetrics.bottomDeltaThreshold else {
                return
            }
            guard now - lastCommit >= SettingsScrollMetrics.bottomCommitMinInterval else { return }
            lastCommit = now
            lastReported = offset
            onOffsetChange(offset)
        }

        /// Points of content sitting below the viewport bottom. Reading this straight off the
        /// scroll view (instead of a per-frame SwiftUI `PreferenceKey`) keeps the value from being
        /// rewritten multiple times during a single layout pass.
        private func reportMoreBelow(_ scrollView: UIScrollView) {
            guard let onMoreBelowChange else { return }
            let below = max(
                0,
                scrollView.contentSize.height
                    - (scrollView.contentOffset.y + scrollView.bounds.height))
            guard abs(below - lastMoreReported) > 1 else { return }
            lastMoreReported = below
            onMoreBelowChange(below)
        }
    }
}

extension UIView {
    fileprivate var enclosingScrollView: UIScrollView? {
        var view: UIView? = self
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }
}

/// Scroll region for operator settings tabs. Owns the bottom "MORE" cue state so preference
/// updates during scrolling do not invalidate the tab rail or content header.
private struct SettingsTabScrollArea<Content: View>: View {
    let tabID: String
    @Binding var savedOffset: CGFloat
    let content: Content
    @Binding var reorderActive: Bool
    @State private var moreBelow: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var lastOffsetCommit: CFAbsoluteTime = 0
    @State private var lastCommittedOffset: CGFloat = -1
    @State private var dragViewportY: CGFloat?
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var scrollViewBox = SettingsScrollViewBox()

    init(
        tabID: String,
        savedOffset: Binding<CGFloat>,
        reorderActive: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.tabID = tabID
        _savedOffset = savedOffset
        _reorderActive = reorderActive
        self.content = content()
    }

    private var showsMoreCue: Bool {
        moreBelow > 6
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 22)
        }
        // `.immediately` posts keyboard hide notifications on every scroll/drag even when no field
        // is focused — use interactive dismiss so reorder drags do not spuriously poke UIKit.
        .scrollDismissesKeyboard(.interactively)
        .coordinateSpace(name: SettingsScrollCoordinateSpace.name)
        .scrollDisabled(reorderActive)
        .background(
            GeometryReader { vp in
                Color.clear.preference(
                    key: ScrollViewportKey.self, value: vp.size.height)
            }
        )
        .background(
            SettingsScrollViewFinder(
                box: scrollViewBox,
                restoreOffset: savedOffset,
                onOffsetChange: commitScrollOffset,
                onMoreBelowChange: { moreBelow = $0 }
            )
        )
        .onPreferenceChange(ScrollViewportKey.self) { value in
            guard abs(value - viewportHeight) > 1 else { return }
            viewportHeight = value
            updateReorderAutoScroll()
        }
        .onPreferenceChange(SettingsReorderActiveKey.self) { reorderActive = $0 }
        .onPreferenceChange(SettingsReorderDragViewportYKey.self) { dragViewportY = $0 }
        .onChange(of: dragViewportY) { _, _ in updateReorderAutoScroll() }
        .onChange(of: reorderActive) { _, active in
            if !active {
                dragViewportY = nil
                stopReorderAutoScroll()
            } else {
                updateReorderAutoScroll()
            }
        }
        .onDisappear { stopReorderAutoScroll() }
        .overlay(alignment: .bottom) {
            ScrollMoreCue()
                .opacity(showsMoreCue ? 1 : 0)
                .allowsHitTesting(false)
        }
        .id(tabID)
    }

    private func commitScrollOffset(_ offset: CGFloat) {
        let now = CFAbsoluteTimeGetCurrent()
        guard abs(offset - lastCommittedOffset) > SettingsScrollMetrics.bottomDeltaThreshold else {
            return
        }
        guard now - lastOffsetCommit >= SettingsScrollMetrics.bottomCommitMinInterval else {
            return
        }
        lastOffsetCommit = now
        lastCommittedOffset = offset
        if abs(savedOffset - offset) > 0.5 {
            savedOffset = offset
        }
    }

    private func updateReorderAutoScroll() {
        guard reorderActive, viewportHeight > 0, let dragY = dragViewportY else {
            stopReorderAutoScroll()
            return
        }
        let edge = SettingsScrollMetrics.reorderEdgeThreshold
        let inTopZone = dragY < edge
        let inBottomZone = dragY > viewportHeight - edge
        guard inTopZone || inBottomZone else {
            stopReorderAutoScroll()
            return
        }
        guard autoScrollTask == nil else { return }

        autoScrollTask = Task { @MainActor in
            let frameSeconds =
                CGFloat(SettingsScrollMetrics.reorderScrollFrameInterval) / 1_000_000_000
            while !Task.isCancelled {
                guard reorderActive,
                    viewportHeight > 0,
                    let currentDragY = dragViewportY,
                    let scrollView = scrollViewBox.scrollView
                else { break }

                let edgeThreshold = SettingsScrollMetrics.reorderEdgeThreshold
                var delta: CGFloat = 0
                if currentDragY < edgeThreshold {
                    let proximity = (edgeThreshold - currentDragY) / edgeThreshold
                    let intensity = proximity * proximity
                    delta = -SettingsScrollMetrics.reorderMaxScrollSpeed * intensity * frameSeconds
                } else if currentDragY > viewportHeight - edgeThreshold {
                    let proximity =
                        (currentDragY - (viewportHeight - edgeThreshold)) / edgeThreshold
                    let intensity = proximity * proximity
                    delta = SettingsScrollMetrics.reorderMaxScrollSpeed * intensity * frameSeconds
                }

                guard delta != 0 else { break }

                let maxOffset = max(
                    scrollView.contentSize.height - scrollView.bounds.height, 0)
                let nextY = min(max(scrollView.contentOffset.y + delta, 0), maxOffset)
                guard nextY != scrollView.contentOffset.y else { break }
                scrollView.setContentOffset(CGPoint(x: 0, y: nextY), animated: false)
                scrollView.layoutIfNeeded()

                try? await Task.sleep(nanoseconds: SettingsScrollMetrics.reorderScrollFrameInterval)
            }
            autoScrollTask = nil
        }
    }

    private func stopReorderAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }
}

/// The mockup's bottom "MORE ⌄" affordance: a fade into the panel surface with a hint that more
/// settings sit below. Non-interactive so it never blocks the scroll gesture underneath.
struct ScrollMoreCue: View {
    var body: some View {
        VStack(spacing: 1) {
            Spacer(minLength: 0)
            Text("MORE")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(LiveDesign.muted)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LiveDesign.muted)
        }
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            LinearGradient(
                colors: [LiveDesign.surface.opacity(0), LiveDesign.surface],
                startPoint: .top, endPoint: .bottom)
        )
        .allowsHitTesting(false)
    }
}

/// Operator Setup rail tabs — selection and per-tab scroll offsets live in `NativeAppModel` so
/// they survive dismissing the panel back to live view.
enum OperatorSettingsTab: String, CaseIterable, Identifiable {
    case link = "Link"
    case assist = "View Assist"
    case controls = "Controls"
    case display = "Display"
    case storage = "Storage"
    case system = "System"
    var id: String { rawValue }

    /// Screenshot affordance (link/assist/controls/display/storage/system) picking the initial
    /// rail tab. Defaults to Link in normal launches.
    static var demoLaunchTab: OperatorSettingsTab {
        demoLaunchTab(DemoHarness.panelTab)
    }

    static func demoLaunchTab(_ rawValue: String?) -> OperatorSettingsTab {
        switch rawValue {
        case "assist": .assist
        case "controls": .controls
        case "display": .display
        case "storage": .storage
        case "system": .system
        default: .link
        }
    }
}

/// The internet-backed destination selected from Operator Setup.
///
/// Keeping the selection as a value lets the camera-AP confirmation survive the tap and route to
/// the exact page or in-app report flow after the camera session has been disconnected.
enum SettingsInternetDestination: String, CaseIterable, Identifiable {
    case support
    case reportProblem
    case featureRequest
    case sourceCode
    case privacyPolicy
    case termsOfUse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .support: "Support"
        case .reportProblem: "Report a Problem"
        case .featureRequest: "Request a Feature"
        case .sourceCode: "Source Code"
        case .privacyPolicy: "Privacy Policy"
        case .termsOfUse: "Terms of Use"
        }
    }

    var webURL: URL? {
        switch self {
        case .support: SupportLinkCatalog.support
        case .reportProblem: nil
        case .featureRequest: SupportLinkCatalog.featureRequest
        case .sourceCode: SupportLinkCatalog.source
        case .privacyPolicy: SupportLinkCatalog.privacy
        case .termsOfUse: SupportLinkCatalog.terms
        }
    }

    var opensInAppReport: Bool { self == .reportProblem }

    var confirmationMessage: String {
        "To open \(title), OpenZCine will disconnect from the camera's Wi-Fi and switch to cellular or another internet-connected Wi-Fi network. You can reconnect to the camera after you finish."
    }

    static func demoValue(_ rawValue: String?) -> SettingsInternetDestination? {
        switch rawValue {
        case "support": .support
        case "report": .reportProblem
        case "feature": .featureRequest
        default: nil
        }
    }
}

struct OperatorSettingsPanel: View {
    /// Real device safe-area insets (carries the landscape Dynamic Island lane) so the full-screen
    /// surface can fill the physical screen yet keep its content clear of the cutout.
    var safeArea: MonitorEdgeInsets = .zero

    @Environment(NativeAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var settingsReorderActive = false
    /// Bumped on Frame.io sign-in/out so the Storage card re-reads the (non-observable)
    /// keychain state.
    @State private var frameioAccountStamp = 0
    @State private var frameioSigningIn = false
    @State private var frameioSignInError: String?
    @State private var showFrameioHopConfirm = false
    @State private var cacheSizeBytes: UInt64?
    @State private var diagnosticsShareItem: DiagnosticsShareItem?
    @State private var diagnosticsErrorMessage: String?
    @State private var externalLinkErrorMessage: String?
    @State private var pendingInternetDestination: SettingsInternetDestination?
    @State private var isPreparingDiagnostics = false
    /// Standalone setup is already a root cover, so its report flow is presented above that cover.
    /// Camera-backed setup uses the root-owned presentation instead, which survives an AP hop.
    @State private var standaloneBugReportPresented = false

    private var selectedTab: OperatorSettingsTab {
        get { model.operatorSettingsTab }
        nonmutating set { model.operatorSettingsTab = newValue }
    }

    private var savedScrollOffset: Binding<CGFloat> {
        Binding(
            get: { model.operatorSettingsScrollOffsets[selectedTab.id, default: 0] },
            set: { model.operatorSettingsScrollOffsets[selectedTab.id] = $0 }
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LiveDesign.background
            GeometryReader { proxy in
                let portrait = proxy.size.height > proxy.size.width

                Group {
                    if portrait {
                        // The tab strip leads (with its own leading inset clearing the floating
                        // CloseButton — see settingsTabStrip); settingsTop's title then renders on
                        // the row below, entirely clear of the button's corner.
                        VStack(alignment: .leading, spacing: 8) {
                            settingsTabStrip
                            settingsTop
                            settingsContent(portrait: portrait)
                        }
                    } else {
                        VStack(spacing: 8) {
                            settingsTop
                                // The floating CloseButton overlays this row's leading corner
                                // whenever no Dynamic Island lane pushes the content past it
                                // (iPad, non-notched devices); inset the title to clear it. On
                                // notched iPhones the safe-area padding already clears the
                                // button and this resolves to 0.
                                .padding(.leading, closeButtonClearance)
                            HStack(alignment: .top, spacing: 8) {
                                settingsRail
                                settingsContent(portrait: portrait)
                                    .layoutPriority(1)
                                    .frame(minWidth: 0, maxWidth: .infinity)
                            }
                        }
                    }
                }
                // Fill the full physical screen, insetting only enough to clear the Dynamic Island
                // on whichever landscape edge it sits (safeArea.leading / .trailing) and a small
                // margin elsewhere — so the surface uses the whole width instead of the safe-area
                // frame.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, max(CGFloat(safeArea.top) + 6, 14))
                // The island side carries the full inset; the clean side (zeroed by the host) hugs
                // the bezel at the 16pt floor.
                .padding(.leading, max(CGFloat(safeArea.leading) + 6, 16))
                .padding(.trailing, max(CGFloat(safeArea.trailing) + 6, 16))
                .padding(.bottom, max(CGFloat(safeArea.bottom) + 4, 12))
            }

            // Close floats in the very top-left corner (clear of the rounded bezel) — the Dynamic
            // Island sits at the vertical centre, so the top corner is free even inside the lane. It
            // sits outside the layout flow so the title + content can rise to fill the header void.
            CloseButton(size: 37)
                .padding(.leading, 16)
                .padding(.top, max(CGFloat(safeArea.top) + 6, 22))
        }
        .ignoresSafeArea()
        .sheet(item: $diagnosticsShareItem) { item in
            DiagnosticsShareSheet(url: item.url)
        }
        .fullScreenCover(isPresented: $standaloneBugReportPresented) {
            BugReportFlowView(
                onDismiss: {
                    standaloneBugReportPresented = false
                    model.resumeBugReportInternetHandoffIfNeeded()
                },
                onBrowserHandoff: { standaloneBugReportPresented = false }
            )
            .environment(model)
        }
        .alert(
            "Couldn’t Share Diagnostics",
            isPresented: Binding(
                get: { diagnosticsErrorMessage != nil },
                set: { if !$0 { diagnosticsErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsErrorMessage ?? "Please try again.")
        }
        .alert(
            "Couldn’t Reach the Internet",
            isPresented: Binding(
                get: { externalLinkErrorMessage != nil },
                set: { if !$0 { externalLinkErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                externalLinkErrorMessage
                    ?? "Check cellular or another Wi-Fi network and try again."
            )
        }
        .alert(
            "Leave camera Wi-Fi?",
            isPresented: Binding(
                get: { pendingInternetDestination != nil },
                set: { if !$0 { pendingInternetDestination = nil } }
            ),
            presenting: pendingInternetDestination
        ) { destination in
            Button("Cancel", role: .cancel) { pendingInternetDestination = nil }
            Button("Continue") {
                pendingInternetDestination = nil
                activateInternetDestination(destination)
            }
        } message: { destination in
            Text(destination.confirmationMessage)
        }
        .onAppear {
            if let destination = SettingsInternetDestination.demoValue(
                DemoHarness.internetHandoffConfirmation
            ) {
                pendingInternetDestination = destination
            } else if DemoHarness.openBugReport {
                presentBugReport()
            }
        }
    }

    /// Extra leading inset the landscape header needs to clear the floating ``CloseButton``.
    /// The button sits at a fixed 16pt from the screen edge (37pt wide); the panel's own leading
    /// padding is `max(safeArea.leading + 6, 16)`. On notched iPhones the Dynamic Island lane
    /// already pushes the content past the button (result: 0); on iPad there is no leading
    /// safe-area inset, so the title would otherwise start exactly under the button.
    private var closeButtonClearance: CGFloat {
        max(0, (16 + 37 + 8) - max(CGFloat(safeArea.leading) + 6, 16))
    }

    private var settingsTop: some View {
        // Close floats in the very top-left corner (see `body`); the title leads this row, lined up
        // with the tab rail below, and the live tile stays pinned top-right.
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenZCine")
                    .font(.system(size: 9.5, weight: .bold, design: .default))
                    .kerning(0.8)
                    .foregroundStyle(LiveDesign.accent)
                    .textCase(.uppercase)
                Text("Operator Setup")
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(LiveDesign.text)
            }
            Spacer()
            SettingsLiveTile()
                .environment(model)
        }
    }

    private var settingsRail: some View {
        VStack(spacing: 5) {
            ForEach(OperatorSettingsTab.allCases) { tab in
                settingsTabButton(tab)
            }
        }
        .padding(6)
        .frame(width: 146)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: .infinity, alignment: .top)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }

    /// Horizontal tab strip for portrait: the same tab buttons the vertical ``settingsRail``
    /// renders, laid out in a scrollable row above ``settingsContent`` instead of a side rail.
    private var settingsTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(OperatorSettingsTab.allCases) { tab in
                    settingsTabButton(tab)
                        .frame(width: 146)
                }
            }
            .padding(6)
        }
        // Glass on the SCROLL VIEW, not its content — glass-on-content sizes the bar to every
        // tab and it runs dead off the trailing edge; on the container the bar fits the width
        // (both rounded ends on screen) and the tabs scroll inside it.
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        // The root's floating CloseButton overlays this same top-leading corner in portrait
        // (landscape clears it via settingsTop instead); inset the whole bar to start beside it.
        .padding(.leading, 45)
    }

    /// A single settings tab button — shared by the vertical rail (``settingsRail``) and the
    /// horizontal portrait strip (``settingsTabStrip``).
    private func settingsTabButton(_ tab: OperatorSettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 9) {
                Capsule()
                    .fill(selectedTab == tab ? LiveDesign.accent : Color.clear)
                    .frame(width: 6, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(
                            selectedTab == tab ? LiveDesign.text : LiveDesign.muted
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(tabSubtitle(tab))
                        .font(.system(size: 10.5, weight: .regular, design: .default))
                        .foregroundStyle(LiveDesign.faint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 43)
            .background(
                selectedTab == tab ? LiveDesign.surface : Color.clear,
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            )
        }
        .buttonStyle(.zcTapTarget)
    }

    private func settingsContent(portrait: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedTab.rawValue)
                        .font(.system(size: 24, weight: .semibold, design: .default))
                        .foregroundStyle(LiveDesign.text)
                    Text(subtitle)
                        .font(.system(size: 12.5, weight: .regular, design: .default))
                        .foregroundStyle(LiveDesign.muted)
                        .lineLimit(2)
                }
                Spacer()
                Text(pillText.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(0.6)
                    .foregroundStyle(LiveDesign.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(LiveDesign.accentDim, lineWidth: 1))
            }
            SettingsTabScrollArea(
                tabID: selectedTab.id,
                savedOffset: savedScrollOffset,
                reorderActive: $settingsReorderActive
            ) {
                settingsRows(portrait: portrait)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
        )
        .clipShape(RoundedRectangle(cornerRadius: LiveDesign.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
    }

    private var subtitle: String {
        switch selectedTab {
        case .link: "Connection state and link behavior."
        case .assist: "Behavior for live-view tools."
        case .controls: "Touch behavior and safety."
        case .display: "Live view buttons and chrome."
        case .storage: "Local cache and integrations."
        case .system: "App-level behavior."
        }
    }

    private var pillText: String {
        switch selectedTab {
        case .link: "Live"
        case .assist: "Assist"
        case .controls: "Touch"
        case .display: "Visibility"
        case .storage: "Data"
        case .system: "App"
        }
    }

    private func tabSubtitle(_ tab: OperatorSettingsTab) -> String {
        switch tab {
        case .link: "Connection"
        case .assist: "Scopes & overlays"
        case .controls: "Dials and safety"
        case .display: "Live view"
        case .storage: "Cache & accounts"
        case .system: "App behavior"
        }
    }

    @ViewBuilder private var linkRows: some View {
        SettingsDashScale(
            title: "Link Health",
            caption: linkHealthCaption,
            score: model.linkHealth)

        SettingsRowCard {
            SettingsInlineRow(
                title: "Current Transport",
                help:
                    "Transport is selected on the connection screen; USB-C and Wi-Fi are exclusive for the current session.",
                showTopDivider: false
            ) {
                SettingsValueText(value: transportLabel)
            }
            SettingsInlineRow(
                title: "Stream Preset",
                help:
                    "Combines Nikon live-view stream size and compression grade into three operator-facing choices."
            ) {
                SettingsSegmented(
                    options: OperatorPreferences.StreamPreset.allCases.map(\.rawValue),
                    selected: model.preferences.streamPreset.rawValue
                ) { value in
                    if let preset = OperatorPreferences.StreamPreset(rawValue: value) {
                        model.setStreamPreset(preset)
                    }
                }
            }
            SettingsInlineRow(
                title: "Quality Bias",
                help:
                    "Steers the selected stream preset toward smaller frames or more image detail."
            ) {
                SettingsSegmented(
                    options: ["Size", "Quality"],
                    selected: model.preferences.qualityBias == .detail ? "Quality" : "Size"
                ) { value in
                    // ponytail: the 3-way core bias collapses to the mockup's Size/Quality pair.
                    model.setQualityBias(value == "Quality" ? .detail : .latency)
                }
            }
            SettingsInlineRow(
                title: "Connection Action",
                help:
                    "Move into a Wi-Fi session when cable-light operation matters, or disconnect when Wi-Fi is already active."
            ) {
                SettingsActionPill(title: isConnected ? "Disconnect" : "Connect over Wi-Fi") {
                    if isConnected { model.disconnect() }
                }
            }
            SettingsInlineRow(
                title: "Health Threshold",
                help:
                    "Warn only when latency, heartbeat, or frame delivery stays degraded instead of reacting to a single short spike."
            ) {
                SettingsValueText(value: "Balanced")
            }
            SettingsInlineRow(
                title: "Reconnect Window",
                help: "How long the app waits before surfacing a lost-camera warning."
            ) {
                SettingsValueText(value: "4 sec")
            }
        }
    }

    @ViewBuilder private var controlsRows: some View {
        SettingsRowCard {
            SettingsSwitchInlineRow(
                title: "Record Confirmation",
                help: "Ask before starting or stopping recording to prevent mistaps.",
                showTopDivider: false,
                isOn: model.preferences.recordConfirmationEnabled
            ) { model.preferences.recordConfirmationEnabled.toggle() }
            SettingsSwitchInlineRow(
                title: "Bluetooth Remote Shutter",
                help:
                    "A paired Bluetooth shutter remote's button press starts or stops recording while the live view is up front. Inside Settings, Media, or other full-screen pages the volume keys behave normally. The phone's volume keys record too, and Record Confirmation is skipped. Presses arrive as volume commands, so the volume may move momentarily before snapping back; the system volume overlay stays hidden while armed.",
                isOn: model.preferences.bluetoothShutterEnabled
            ) { model.preferences.bluetoothShutterEnabled.toggle() }
            SettingsSwitchInlineRow(
                title: "Haptics",
                help: "Short confirmation pulses for critical switches and setting changes.",
                isOn: model.preferences.hapticsEnabled
            ) { model.preferences.hapticsEnabled.toggle() }
            SettingsSwitchInlineRow(
                title: "Keep Screen Awake",
                help:
                    "Prevents auto-lock while the live monitor or clip playback is active. Exposure assists increase GPU load — disable tools you are not using. iOS may still dim when the device overheats.",
                isOn: model.preferences.keepScreenAwake
            ) { model.preferences.keepScreenAwake.toggle() }
        }

    }

    @ViewBuilder private var displayRows: some View {
        SettingsGroupCard(
            title: "View Assist toolbar",
            caption: "Drag to reorder; tap the eye to show or hide each tool on the monitor bar.",
            onReset: { model.resetAssistToolbarPreferences() },
            content: {
                AssistToolbarOrderStrip()
                    .environment(model)
            }
        )

        SettingsGroupCard(
            title: "Live Status Readouts", caption: "Hide readouts you do not ride during a take."
        ) {
            displayToggleGrid([
                (
                    "REC", model.preferences.displayChrome.recReadoutVisible,
                    { model.preferences.displayChrome.recReadoutVisible.toggle() }
                ),
                (
                    "CODEC", model.preferences.displayChrome.codecReadoutVisible,
                    { model.preferences.displayChrome.codecReadoutVisible.toggle() }
                ),
                (
                    "MEDIA", model.preferences.displayChrome.mediaReadoutVisible,
                    { model.preferences.displayChrome.mediaReadoutVisible.toggle() }
                ),
                (
                    "FPS", model.preferences.displayChrome.fpsReadoutVisible,
                    { model.preferences.displayChrome.fpsReadoutVisible.toggle() }
                ),
            ])
        }

        SettingsGroupCard(
            title: "DISP Button Order",
            caption: "Drag to reorder; tap to enable or disable modes.",
            onReset: { model.resetDispPreferences() },
            content: {
                DisplayOrderStrip()
                    .environment(model)
            }
        )
    }

    /// Marketing version + build number from the bundle, e.g. "0.2.0 (9)", matching what
    /// TestFlight shows for the installed build (CI stamps CFBundleVersion per upload).
    static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @ViewBuilder private var systemRows: some View {
        SettingsRowCard(title: "Help & Feedback") {
            SettingsInlineRow(
                title: "Support",
                help: "Connection guides, camera controls, media workflows, and troubleshooting.",
                showTopDivider: false
            ) {
                systemLinkButton("Open", destination: .support, label: "Open Support")
            }
            SettingsInlineRow(
                title: "Report a Problem",
                help:
                    "Choose an anonymous in-app report or the richer signed-in GitHub form. Either creates a public GitHub issue."
            ) {
                SettingsActionPill(title: "Report") {
                    requestInternetDestination(.reportProblem)
                }
                .accessibilityLabel("Report a Problem")
            }
            SettingsInlineRow(
                title: "Request a Feature",
                help: "Start an idea in the project’s feature-request discussion category."
            ) {
                systemLinkButton(
                    "Request", destination: .featureRequest, label: "Request a Feature")
            }
            SettingsInlineRow(
                title: "Share Diagnostics",
                help:
                    "Create a local report with recent app events and Apple diagnostics. Review it before sharing."
            ) {
                SettingsActionPill(
                    title: isPreparingDiagnostics ? "Preparing…" : "Share"
                ) {
                    prepareDiagnosticsReport()
                }
                .disabled(isPreparingDiagnostics)
                .accessibilityLabel("Share Diagnostics")
            }
            SettingsInlineRow(
                title: "Live View Guide",
                help:
                    "Show the short control guide now when live view is open, or again on the next live view."
            ) {
                SettingsActionPill(title: "Show Again") {
                    model.replayLiveViewGuide()
                }
                .accessibilityLabel("Show Live View Guide Again")
            }
        }

        SettingsRowCard(title: "Project & Legal") {
            SettingsInlineRow(
                title: "Source Code",
                help: "View the OpenZCine project and contribute on GitHub.",
                showTopDivider: false
            ) {
                systemLinkButton(
                    "Open", destination: .sourceCode, label: "Open Source Code")
            }
            SettingsInlineRow(title: "Privacy", help: "Read the OpenZCine privacy policy.") {
                systemLinkButton(
                    "Open", destination: .privacyPolicy, label: "Open Privacy Policy")
            }
            SettingsInlineRow(title: "Terms", help: "Read the OpenZCine terms of use.") {
                systemLinkButton(
                    "Open", destination: .termsOfUse, label: "Open Terms of Use")
            }
        }

        SettingsRowCard(title: "App Information") {
            SettingsInlineRow(
                title: "Theme",
                help: "Dark earth interface tuned for low reflection on set.",
                showTopDivider: false
            ) {
                SettingsValueText(value: "Warm Dark")
            }
            SettingsInlineRow(
                title: "Protocol Implementation",
                help:
                    "Camera control speaks standard PTP over USB and PTP-IP over Wi-Fi; no vendor SDK is bundled or required."
            ) {
                SettingsValueText(value: "PTP / PTP-IP")
            }
            SettingsInlineRow(
                title: "App Version",
                help: "Current OpenZCine build from the native project metadata."
            ) {
                SettingsValueText(value: Self.appVersionText)
            }
        }
    }

    private func presentBugReport() {
        if model.isStandaloneSettingsPresented {
            model.isBugReportPresented = false
            standaloneBugReportPresented = true
        } else {
            model.isBugReportPresented = true
        }
    }

    private func systemLinkButton(
        _ title: String,
        destination: SettingsInternetDestination,
        label: String
    ) -> some View {
        Button(title) { requestInternetDestination(destination) }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LiveDesign.accent)
            .buttonStyle(.zcTapTarget)
            .accessibilityLabel(label)
    }

    private func requestInternetDestination(_ destination: SettingsInternetDestination) {
        guard !model.isOnCameraAccessPoint else {
            pendingInternetDestination = destination
            return
        }
        activateInternetDestination(destination)
    }

    private func activateInternetDestination(_ destination: SettingsInternetDestination) {
        let showsRouteProgress = model.isOnCameraAccessPoint
        if showsRouteProgress {
            model.beginInternetDestinationPreparation(destination.title)
        }
        Task {
            defer {
                if showsRouteProgress {
                    model.finishInternetDestinationPreparation(destination.title)
                }
            }
            let routeReady =
                if destination.opensInAppReport {
                    await model.prepareBugReportInternetHandoff()
                } else {
                    await model.prepareExternalInternetLinkHandoff()
                }
            guard routeReady else {
                externalLinkErrorMessage =
                    "OpenZCine couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
                return
            }
            if destination.opensInAppReport {
                presentBugReport()
                return
            }
            guard let url = destination.webURL else { return }
            openURL(url) { accepted in
                model.completeExternalInternetLinkHandoff(browserAccepted: accepted)
            }
        }
    }

    private func prepareDiagnosticsReport() {
        guard !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                diagnosticsShareItem = DiagnosticsShareItem(
                    url: try await AppDiagnostics.shared.makeReport())
            } catch {
                diagnosticsErrorMessage = error.localizedDescription
            }
        }
    }

    /// Storage tab: account integrations and the local media cache. Reachable without a camera
    /// (standalone settings from the startup home) — sign in to Frame.io before a shoot, clear
    /// cache after one.
    @ViewBuilder private var storageRows: some View {
        SettingsRowCard {
            SettingsInlineRow(
                title: "Frame.io",
                help:
                    "Sign in once here and the share sheet's Frame.io option unlocks everywhere. On the camera's Wi‑Fi, \"Sign in over internet\" hops to home Wi‑Fi or cellular, signs in, then reconnects the camera. Logging out removes the stored sign-in and remembered project.",
                showTopDivider: false
            ) {
                if model.isFrameioConnected {
                    Button {
                        model.disconnectFrameio()
                        frameioAccountStamp += 1
                    } label: {
                        Text("Log out")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(.systemRed))
                    }
                    .buttonStyle(.zcTapTarget)
                } else if !model.isFrameioConfigured {
                    SettingsValueText(value: "Not set up in this build")
                } else if frameioSigningIn {
                    ProgressView().tint(LiveDesign.accent)
                } else if model.isOnCameraAccessPoint {
                    Button {
                        showFrameioHopConfirm = true
                    } label: {
                        Text("Sign in over internet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiveDesign.accent)
                    }
                    .buttonStyle(.zcTapTarget)
                } else {
                    Button {
                        frameioSigningIn = true
                        frameioSignInError = nil
                        Task {
                            do {
                                try await model.connectFrameio()
                            } catch {
                                frameioSignInError = error.localizedDescription
                            }
                            frameioSigningIn = false
                            frameioAccountStamp += 1
                        }
                    } label: {
                        Text("Sign in")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiveDesign.accent)
                    }
                    .buttonStyle(.zcTapTarget)
                }
            }
            if let frameioSignInError {
                Text(frameioSignInError)
                    .font(.system(size: 11))
                    .foregroundStyle(LiveDesign.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Keychain-backed state isn't observable — the stamp forces the card to re-read
        // `isFrameioConnected` after sign-in/out.
        .id(frameioAccountStamp)
        .alert("Leave camera Wi‑Fi to sign in?", isPresented: $showFrameioHopConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign in") { signInFrameioOverInternet() }
        } message: {
            Text(
                "We'll hop to home Wi‑Fi or cellular so you can sign in to Frame.io, then reconnect to the camera automatically."
            )
        }

        SettingsRowCard {
            SettingsInlineRow(
                title: "Local Media Cache",
                help:
                    "Clips and thumbnails cached from the camera for offline playback and sharing, across all paired cameras.",
                showTopDivider: false
            ) {
                SettingsValueText(value: cacheSizeLabel)
            }
            SettingsInlineRow(
                title: "Clear Cache",
                help:
                    "Removes cached clip files and thumbnails for every camera. Favorites, upload history, and camera indexes survive — clips re-cache from the camera on demand."
            ) {
                Button {
                    model.clearAllMediaCaches()
                    cacheSizeBytes = model.totalMediaCacheByteCount()
                } label: {
                    Text("Clear")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(.systemRed))
                }
                .buttonStyle(.zcTapTarget)
            }
        }
        .onAppear { cacheSizeBytes = model.totalMediaCacheByteCount() }
    }

    private var cacheSizeLabel: String {
        guard let cacheSizeBytes else { return "—" }
        guard cacheSizeBytes > 0 else { return "Empty" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(cacheSizeBytes), countStyle: .file)
    }

    /// Consented internet hop for Frame.io sign-in from the camera AP: leave the camera Wi‑Fi,
    /// wait for a real internet path, run the Adobe sign-in, then rejoin the camera. `beginInternetHop`
    /// re-hosts this Settings surface as a standalone cover so it survives the monitor collapse.
    private func signInFrameioOverInternet() {
        frameioSignInError = nil
        frameioSigningIn = true
        Task {
            model.beginInternetHop()
            let online = await model.waitForInternetPath(timeoutSeconds: 30)
            if online {
                do {
                    try await model.connectFrameio()
                } catch {
                    frameioSignInError = error.localizedDescription
                }
            } else {
                frameioSignInError =
                    "Couldn't reach the internet after leaving the camera's Wi‑Fi. Check cellular or home Wi‑Fi."
            }
            // Rejoin the camera regardless of sign-in outcome (full join pipeline + progress card).
            model.endInternetHop()
            frameioSigningIn = false
            frameioAccountStamp += 1
        }
    }

    @ViewBuilder private func settingsRows(portrait: Bool) -> some View {
        switch selectedTab {
        case .link:
            linkRows
        case .assist:
            ViewAssistSettingsRows(portrait: portrait)
                .environment(model)
        case .controls:
            controlsRows
        case .display:
            displayRows
        case .storage:
            storageRows
        case .system:
            systemRows
        }
    }

    /// Whether a camera session is live (real or demo) — drives transport copy and the action pill.
    private var isConnected: Bool {
        model.isDemoSession
            || model.connection == .connected
            || model.connection == .preparingLiveView
    }

    private var linkHealthCaption: String {
        guard isConnected || model.isDemoSession else {
            return model.linkHealthDetail
        }
        return "\(model.linkHealthDetail) · \(scoreBand(model.linkHealth))"
    }

    private var transportLabel: String {
        if model.isDemoSession { return "Demo session" }
        guard isConnected else { return "Not connected" }
        return "\(model.activeTransportLabel ?? "Wi-Fi") active"
    }

    private func scoreBand(_ score: Int) -> String {
        score >= 80 ? "Stable" : (score >= 50 ? "Watch" : "Poor")
    }

    private func displayToggleGrid(
        _ items: [(title: String, isOn: Bool, action: () -> Void)]
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 7)], spacing: 7) {
            ForEach(items.indices, id: \.self) { index in
                DisplayToggleItem(
                    title: items[index].title, isOn: items[index].isOn,
                    action: items[index].action)
            }
        }
    }
}

/// Coordinates the two explicit routes for reporting a public GitHub issue.
///
/// The chooser deliberately keeps the account-free report separate from the signed-in GitHub
/// form: the former stays privacy-minimal while the latter opens the canonical web form in the
/// person's browser.
@MainActor
struct BugReportFlowView: View {
    private enum Destination {
        case chooser
        case anonymous
    }

    @State private var destination: Destination = .chooser

    private let onDismiss: () -> Void
    private let onBrowserHandoff: () -> Void

    init(
        onDismiss: @escaping () -> Void,
        onBrowserHandoff: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.onBrowserHandoff = onBrowserHandoff
    }

    var body: some View {
        switch destination {
        case .chooser:
            BugReportPathChooserView(
                onDismiss: onDismiss,
                onBrowserHandoff: onBrowserHandoff,
                onAnonymous: { destination = .anonymous }
            )
        case .anonymous:
            BugReportFormView(onDismiss: onDismiss)
        }
    }
}

/// Lets a person choose between a minimal anonymous report and GitHub's signed-in bug form.
///
/// Both choices produce public GitHub issues. The in-app route is intentionally limited to a
/// small, privacy-minimal payload; the browser route is for people who want to add richer details.
@MainActor
private struct BugReportPathChooserView: View {
    @Environment(NativeAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    @State private var externalLinkErrorMessage: String?

    private let onDismiss: () -> Void
    private let onBrowserHandoff: () -> Void
    private let onAnonymous: () -> Void

    init(
        onDismiss: @escaping () -> Void,
        onBrowserHandoff: @escaping () -> Void,
        onAnonymous: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.onBrowserHandoff = onBrowserHandoff
        self.onAnonymous = onAnonymous
    }

    var body: some View {
        ZStack {
            LiveDesign.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(LiveDesign.hairline)
                    .frame(height: 1)

                GeometryReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(
                                "Both choices create a public GitHub issue. Choose the route that fits the detail you want to share."
                            )
                            .font(.system(size: 13))
                            .foregroundStyle(LiveDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)

                            reportPaths(useTwoColumns: proxy.size.width >= 680)

                            safetyNotice
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            "Couldn’t Reach the Internet",
            isPresented: Binding(
                get: { externalLinkErrorMessage != nil },
                set: { if !$0 { externalLinkErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                externalLinkErrorMessage
                    ?? "Check cellular or another Wi-Fi network and try again."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Label("Close", systemImage: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
            }
            .buttonStyle(.zcTapTarget)
            .accessibilityLabel("Close report options")

            VStack(alignment: .leading, spacing: 2) {
                Text("Report a Problem")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                Text("Choose a public GitHub issue route")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    @ViewBuilder private func reportPaths(useTwoColumns: Bool) -> some View {
        if useTwoColumns {
            HStack(alignment: .top, spacing: 12) {
                anonymousPath
                githubPath
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                anonymousPath
                githubPath
            }
        }
    }

    private var anonymousPath: some View {
        BugReportPathCard(
            icon: "eye.slash",
            title: "Report anonymously",
            detail:
                "No GitHub account is required. Send a short, privacy-minimal report from the app. It becomes a public GitHub issue, and we cannot reply privately.",
            actionTitle: "Report Anonymously",
            action: onAnonymous,
            accessibilityLabel: "Report anonymously",
            accessibilityHint:
                "Creates a public GitHub issue without requiring a GitHub account."
        )
    }

    private var githubPath: some View {
        BugReportPathCard(
            icon: "person.crop.circle.badge.checkmark",
            title: "Continue with GitHub",
            detail:
                "Sign in in your browser to use the full GitHub bug form. It also becomes a public GitHub issue and supports richer details and attachments.",
            actionTitle: "Continue with GitHub",
            action: {
                openExternalURL(SupportLinkCatalog.githubBugReport, dismissWhenAccepted: true)
            },
            accessibilityLabel: "Continue with GitHub",
            accessibilityHint:
                "Opens the signed-in GitHub bug report form in your browser."
        )
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Keep reports public-safe", systemImage: "eye")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Text(
                "Do not include passwords, pairing codes, private media, camera serial numbers, or security details in either public route."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(LiveDesign.muted)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open private security advisory") {
                openExternalURL(SupportLinkCatalog.securityAdvisory)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(LiveDesign.accent)
            .buttonStyle(.zcTapTarget)
            .accessibilityLabel("Open private GitHub security advisory")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
    }

    private func openExternalURL(_ url: URL, dismissWhenAccepted: Bool = false) {
        Task {
            guard await appModel.prepareExternalInternetLinkHandoff() else {
                externalLinkErrorMessage =
                    "OpenZCine couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
                return
            }
            openURL(url) { accepted in
                appModel.completeExternalInternetLinkHandoff(browserAccepted: accepted)
                if dismissWhenAccepted {
                    BugReportGitHubHandoff.dismissAfterAcceptedBrowserOpen(
                        accepted,
                        dismiss: onBrowserHandoff
                    )
                }
            }
        }
    }
}

/// Keeps the report chooser open when the system declines the GitHub browser handoff.
enum BugReportGitHubHandoff {
    static func dismissAfterAcceptedBrowserOpen(
        _ accepted: Bool,
        dismiss: () -> Void
    ) {
        guard accepted else { return }
        dismiss()
    }
}

/// A large, accessible report-route control that keeps its route's privacy contract visible.
private struct BugReportPathCard: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void
    let accessibilityLabel: String
    let accessibilityHint: String

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LiveDesign.accent)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LiveDesign.text)
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LiveDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Label(actionTitle, systemImage: "arrow.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LiveDesign.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LiveDesign.surface,
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                    .stroke(LiveDesign.hairline, lineWidth: 1)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

/// A private, in-app form that sends an anonymous report to the public GitHub issue relay.
///
/// Optional attachments are strictly opt-in: a closed-vocabulary app activity snapshot and freshly
/// re-rendered PNG copies selected through the system photo picker. The form has no automatic
/// screenshot capture, raw diagnostics attachment, retry queue, or persistent draft storage.
@MainActor
struct BugReportFormView: View {
    @Environment(NativeAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var model: BugReportFormModel
    @State private var selectedScreenshotItems: [PhotosPickerItem] = []

    private let onDismiss: () -> Void

    init(
        onDismiss: @escaping () -> Void,
        model: BugReportFormModel = BugReportFormModel()
    ) {
        self.onDismiss = onDismiss
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var form = model

        ZStack {
            LiveDesign.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(LiveDesign.hairline)
                    .frame(height: 1)

                if let receipt = model.receipt {
                    submittedContent(receipt: receipt)
                } else {
                    formContent(
                        draft: $form.draft,
                        includeActivityLog: $form.includeActivityLog,
                        includeScreenshots: $form.includeScreenshots
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedScreenshotItems) { _, items in
            Task { await importSelectedScreenshots(items) }
        }
        .onChange(of: model.includeScreenshots) { _, includesScreenshots in
            if !includesScreenshots {
                selectedScreenshotItems = []
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Label("Close", systemImage: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
            }
            .buttonStyle(.zcTapTarget)
            .accessibilityLabel("Close bug report")

            VStack(alignment: .leading, spacing: 2) {
                Text("Report a Problem")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                Text("Anonymous bug report")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func formContent(
        draft: Binding<BugReportDraft>,
        includeActivityLog: Binding<Bool>,
        includeScreenshots: Binding<Bool>
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                BugReportTextField(
                    title: "Short summary",
                    hint: "What went wrong?",
                    text: draft.summary,
                    maximum: 120
                )

                BugReportTextEditor(
                    title: "What happened",
                    hint: "Describe the problem and what you expected instead.",
                    text: draft.whatHappened,
                    maximum: 4_000,
                    minimumHeight: 84
                )

                BugReportTextEditor(
                    title: "Steps to reproduce (optional)",
                    hint: "List the steps that make the problem happen.",
                    text: draft.stepsToReproduce,
                    maximum: 4_000,
                    minimumHeight: 72
                )

                BugReportChoiceRow(
                    title: "How often did it happen?",
                    selection: draft.frequency,
                    displayName: { $0.displayName }
                )

                BugReportChoiceRow(
                    title: "How was the camera connected?",
                    selection: draft.connection,
                    displayName: { $0.displayName }
                )

                attachmentControls(
                    includeActivityLog: includeActivityLog,
                    includeScreenshots: includeScreenshots
                )

                privacyNotice

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(.systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color(.systemOrange).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                        )
                        .accessibilityLabel("Report error: \(errorMessage)")
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            submissionFooter
        }
    }

    private func attachmentControls(
        includeActivityLog: Binding<Bool>,
        includeScreenshots: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Optional attachments", systemImage: "paperclip")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiveDesign.text)

            BugReportAttachmentCheckbox(
                title: "Include privacy-filtered app activity log",
                detail:
                    "Up to 200 closed event names only; no timestamps, device name, MetricKit, or raw diagnostics.",
                isOn: includeActivityLog
            )

            BugReportAttachmentCheckbox(
                title: "Include selected screenshots",
                detail:
                    "Choose up to three images. OpenZCine creates fresh PNG copies without embedded file metadata.",
                isOn: includeScreenshots
            )

            if includeScreenshots.wrappedValue {
                screenshotPicker
            }

            Text(
                "Attachments are public. We remove embedded file metadata and use a privacy-filtered app activity log, but screenshots can still show names, locations, notifications, or other sensitive details. Review them carefully before sending."
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color(.systemOrange))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.systemOrange).opacity(0.12),
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
            )
            .accessibilityLabel(
                "Public attachment warning. Review screenshots for sensitive details before sending."
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var screenshotPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.screenshots.count < BugReportAttachmentLimits.maximumScreenshotCount {
                PhotosPicker(
                    selection: $selectedScreenshotItems,
                    maxSelectionCount: BugReportAttachmentLimits.maximumScreenshotCount
                        - model.screenshots.count,
                    matching: .images
                ) {
                    Label("Choose screenshots", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiveDesign.accent)
                }
                .buttonStyle(.zcTapTarget)
                .accessibilityLabel("Choose screenshots to attach")
                .accessibilityHint(
                    "Selected images are re-rendered without embedded file metadata.")
            } else {
                Text("Three screenshots selected.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
            }

            if !model.screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.screenshots.enumerated()), id: \.element.id) {
                            index,
                            screenshot in
                            screenshotPreview(screenshot, index: index)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .accessibilityLabel("Selected screenshots")
            }

            if let attachmentErrorMessage = model.attachmentErrorMessage {
                Label(attachmentErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(.systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Screenshot error: \(attachmentErrorMessage)")
            }
        }
    }

    private func screenshotPreview(_ screenshot: BugReportScreenshot, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image = UIImage(data: screenshot.pngData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(LiveDesign.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 118, height: 76)
            .clipped()
            .background(LiveDesign.background)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(spacing: 5) {
                Text("Screenshot \(index + 1)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
                Button("Remove") {
                    model.removeScreenshot(id: screenshot.id)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LiveDesign.accent)
                .buttonStyle(.zcTapTarget)
                .accessibilityLabel("Remove screenshot \(index + 1)")
            }
        }
        .frame(width: 118, alignment: .leading)
    }

    private func importSelectedScreenshots(_ items: [PhotosPickerItem]) async {
        defer { selectedScreenshotItems = [] }
        guard model.includeScreenshots else { return }

        for item in items {
            guard model.screenshots.count < BugReportAttachmentLimits.maximumScreenshotCount else {
                return
            }
            do {
                guard let sourceData = try await item.loadTransferable(type: Data.self) else {
                    model.recordScreenshotImportFailure()
                    continue
                }
                model.addScreenshotData(sourceData)
            } catch {
                model.recordScreenshotImportFailure()
            }
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Before you send", systemImage: "eye.slash")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Text(
                "This creates a public GitHub issue. No GitHub account is required, the report is anonymous, and we cannot reply privately. Optional attachments are only the privacy-filtered app activity log and fresh PNG copies you select. Do not include passwords, pairing codes, private media, camera serial numbers, or anything sensitive."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(LiveDesign.muted)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Security issue? Use SECURITY.md and send a private GitHub security advisory instead."
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LiveDesign.text)
                .fixedSize(horizontal: false, vertical: true)
                Button("Open private security advisory") {
                    openExternalURL(SupportLinkCatalog.securityAdvisory)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LiveDesign.accent)
                .buttonStyle(.zcTapTarget)
                .accessibilityLabel("Open private GitHub security advisory")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
    }

    private var submissionFooter: some View {
        VStack(spacing: 7) {
            if model.isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LiveDesign.accent)
                    Text("Sending anonymous report…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LiveDesign.muted)
                }
                .accessibilityLabel("Sending anonymous bug report")
            }

            Button {
                Task { await submitReport() }
            } label: {
                Text(model.isSubmitting ? "Sending…" : "Submit Anonymous Report")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(LiveDesign.background)
                    .background(
                        model.isSubmitting ? LiveDesign.muted : LiveDesign.accent,
                        in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                    )
            }
            .buttonStyle(.zcTapTarget)
            .disabled(model.isSubmitting)
            .accessibilityLabel("Submit anonymous bug report")
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(LiveDesign.background.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle().fill(LiveDesign.hairline).frame(height: 1)
        }
    }

    private func submittedContent(receipt: BugReportSubmissionReceipt) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(LiveDesign.accent)
                .accessibilityHidden(true)
            Text("Report sent")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Text(submissionConfirmation(receipt: receipt))
                .font(.system(size: 13))
                .foregroundStyle(LiveDesign.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)

            if let issueURL = receipt.issueURL {
                Button("Open Public Issue") {
                    openExternalURL(issueURL)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiveDesign.accent)
                .buttonStyle(.zcTapTarget)
                .accessibilityLabel("Open public GitHub issue")
            }

            HStack(spacing: 16) {
                Button("Report Another") {
                    model.startAnotherReport()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiveDesign.accent)
                .buttonStyle(.zcTapTarget)

                Button("Done", action: onDismiss)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                    .buttonStyle(.zcTapTarget)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    private func submitReport() async {
        guard await appModel.prepareBugReportInternetHandoff() else {
            model.recordInternetRouteFailure()
            return
        }
        await model.submit()
        if model.receipt != nil {
            appModel.resumeBugReportInternetHandoffIfNeeded()
        }
    }

    private func openExternalURL(_ url: URL) {
        Task {
            guard await appModel.prepareExternalInternetLinkHandoff() else {
                model.recordInternetRouteFailure()
                return
            }
            openURL(url) { accepted in
                appModel.completeExternalInternetLinkHandoff(browserAccepted: accepted)
            }
        }
    }

    private func submissionConfirmation(receipt: BugReportSubmissionReceipt) -> String {
        if let number = receipt.issueNumber {
            "Your anonymous report is now public as GitHub issue #\(number). We cannot reply privately."
        } else {
            "Your anonymous report is now public on GitHub. We cannot reply privately."
        }
    }
}

/// A checkbox-style attachment control so public sharing remains an explicit, reversible choice.
private struct BugReportAttachmentCheckbox: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isOn ? LiveDesign.accent : LiveDesign.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LiveDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Included" : "Not included")
        .accessibilityHint("Double tap to \(isOn ? "exclude" : "include") this public attachment.")
    }
}

/// A labelled, character-limited single-line input for the anonymous bug-report form.
private struct BugReportTextField: View {
    let title: String
    let hint: String
    @Binding var text: String
    let maximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BugReportFieldLabel(title: title, count: text.count, maximum: maximum)
            TextField(hint, text: $text, axis: .vertical)
                .font(.system(size: 14))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .padding(10)
                .background(
                    LiveDesign.background,
                    in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                        .stroke(LiveDesign.hairline, lineWidth: 1)
                )
                .accessibilityLabel(title)
                .accessibilityHint(hint)
        }
    }
}

/// A labelled, character-limited multi-line input for the anonymous bug-report form.
private struct BugReportTextEditor: View {
    let title: String
    let hint: String
    @Binding var text: String
    let maximum: Int
    let minimumHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BugReportFieldLabel(title: title, count: text.count, maximum: maximum)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundStyle(LiveDesign.text)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: minimumHeight)
                .background(
                    LiveDesign.background,
                    in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                        .stroke(LiveDesign.hairline, lineWidth: 1)
                )
                .accessibilityLabel(title)
                .accessibilityHint(hint)
        }
    }
}

/// A shared title and character count for a bug-report input.
private struct BugReportFieldLabel: View {
    let title: String
    let count: Int
    let maximum: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Spacer(minLength: 8)
            Text("\(count)/\(maximum)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(count > maximum ? Color(.systemOrange) : LiveDesign.faint)
                .accessibilityLabel("\(count) of \(maximum) characters")
        }
    }
}

/// A compact, typed picker row for one coarse bug-report field.
private struct BugReportChoiceRow<Value: CaseIterable & RawRepresentable & Hashable>: View
where Value.RawValue == String {
    let title: String
    @Binding var selection: Value
    let displayName: (Value) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Picker(title, selection: $selection) {
                ForEach(Array(Value.allCases), id: \.self) { value in
                    Text(displayName(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(LiveDesign.accent)
            .accessibilityLabel(title)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
    }
}

/// View Assist settings tab — isolated from the panel shell so assist-configuration updates do
/// not invalidate link/display/system rows.
struct ViewAssistSettingsRows: View {
    @Environment(NativeAppModel.self) private var model
    var portrait: Bool = false

    var body: some View {
        if portrait {
            // Single full-width column: the two-column masonry below is cramped and right-clips
            // on portrait phones (spec G3). Reading order matches the masonry's column-major
            // order (left column then right column).
            VStack(spacing: 8) {
                ViewAssistToolSettingsCard(
                    title: "False Color", tool: .falseColor, onReset: resetFalseColor)
                ViewAssistToolSettingsCard(title: "Zebra", tool: .zebra, onReset: resetZebra)
                ViewAssistToolSettingsCard(
                    title: "Waveform", tool: .waveform, onReset: resetWaveform)
                ViewAssistToolSettingsCard(title: "Parade", tool: .parade, onReset: resetParade)
                ViewAssistToolSettingsCard(
                    title: "Histogram", tool: .histogram, onReset: resetHistogram)
                ViewAssistToolSettingsCard(
                    title: "Vectorscope", tool: .vectorscope, onReset: resetVectorscope)
                ViewAssistToolSettingsCard(title: "Peaking", tool: .peaking, onReset: resetPeaking)
                ViewAssistToolSettingsCard(
                    title: "Traffic Lights", tool: .trafficLights, onReset: resetTrafficLights)
            }
        } else {
            // Two-column masonry (not LazyVGrid): each column packs its cards tightly, so a short
            // card like False Color no longer leaves a gap matching the tallest card in its row.
            // Reading-order split — left column = odd cards, right = even — preserves the grid order.
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    ViewAssistToolSettingsCard(
                        title: "False Color", tool: .falseColor, onReset: resetFalseColor)
                    ViewAssistToolSettingsCard(
                        title: "Waveform", tool: .waveform, onReset: resetWaveform)
                    ViewAssistToolSettingsCard(
                        title: "Histogram", tool: .histogram, onReset: resetHistogram)
                    ViewAssistToolSettingsCard(
                        title: "Peaking", tool: .peaking, onReset: resetPeaking)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                VStack(spacing: 8) {
                    ViewAssistToolSettingsCard(title: "Zebra", tool: .zebra, onReset: resetZebra)
                    ViewAssistToolSettingsCard(title: "Parade", tool: .parade, onReset: resetParade)
                    ViewAssistToolSettingsCard(
                        title: "Vectorscope", tool: .vectorscope, onReset: resetVectorscope)
                    ViewAssistToolSettingsCard(
                        title: "Traffic Lights", tool: .trafficLights, onReset: resetTrafficLights)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resetFalseColor() {
        let defaults = AssistConfiguration.defaults
        model.assistConfiguration.falseColorScale = defaults.falseColorScale
        model.assistConfiguration.falseColorReferenceEnabled = defaults.falseColorReferenceEnabled
    }

    private func resetZebra() {
        model.assistConfiguration.zebra = AssistConfiguration.defaults.zebra
    }

    private func resetWaveform() {
        let defaults = AssistConfiguration.defaults.scopes
        model.assistConfiguration.scopes.waveformMode = defaults.waveformMode
        model.assistConfiguration.scopes.waveformGuides = defaults.waveformGuides
        model.assistConfiguration.scopes.waveformBrightness = defaults.waveformBrightness
    }

    private func resetParade() {
        let defaults = AssistConfiguration.defaults.scopes
        model.assistConfiguration.scopes.paradeMode = defaults.paradeMode
        model.assistConfiguration.scopes.paradeGuides = defaults.paradeGuides
        model.assistConfiguration.scopes.paradeBrightness = defaults.paradeBrightness
    }

    private func resetHistogram() {
        let defaults = AssistConfiguration.defaults.scopes
        model.assistConfiguration.scopes.histogramTrafficLights = defaults.histogramTrafficLights
        model.assistConfiguration.scopes.crushClipCompensation = defaults.crushClipCompensation
    }

    private func resetTrafficLights() {
        model.assistConfiguration.trafficLights = AssistConfiguration.defaults.trafficLights
        model.assistConfiguration.scopes.crushClipCompensation =
            AssistConfiguration.defaults.scopes.crushClipCompensation
    }

    private func resetPeaking() {
        let defaults = AssistConfiguration.defaults
        model.assistConfiguration.peakingSensitivity = defaults.peakingSensitivity
        model.assistConfiguration.peakingColor = defaults.peakingColor
    }

    private func resetVectorscope() {
        let defaults = AssistConfiguration.defaults.scopes
        model.assistConfiguration.scopes.vectorscopeZoom = defaults.vectorscopeZoom
        model.assistConfiguration.scopes.vectorscopeBrightness = defaults.vectorscopeBrightness
    }
}

/// One View Assist tool card in the operator-setup two-column grid.
private struct ViewAssistToolSettingsCard: View {
    let title: String
    let tool: MonitorAssistTool
    let onReset: () -> Void

    var body: some View {
        SettingsRowCard(title: title, onReset: onReset) {
            AssistQuickSettingsContent(tool: tool, compact: true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .gridCellAnchor(.top)
    }
}

private enum SettingsLiveTileMetrics {
    static let fpsCommitMinInterval: CFAbsoluteTime = 0.5
}

struct SettingsLiveTile: View {
    @Environment(NativeAppModel.self) private var model
    @State private var displayedFPS = CameraDisplayState.preview.liveFPS
    @State private var lastFPSCommit: CFAbsoluteTime = 0

    private var detail: String {
        let transport = model.isDemoSession ? "Demo" : (model.activeTransportLabel ?? "Wi-Fi")
        // Compact whole-number frame rates ("25.00" → "25") — the tile is width-constrained in
        // portrait and the long form ellipsized the FPS off the end.
        let fps = displayedFPS.hasSuffix(".00") ? String(displayedFPS.dropLast(3)) : displayedFPS
        return "\(model.cameraState.cameraName) · \(transport) · \(fps) FPS"
    }

    /// Live link state from the continuously-scored `model.linkHealth` (0–100).
    private var isLinked: Bool { model.isDemoSession || model.linkHealth > 0 }

    private var tint: Color {
        guard isLinked else { return LiveDesign.faint }
        switch model.linkHealth {
        case 70...: return LiveDesign.good
        case 40..<70: return LiveDesign.accent
        default: return model.isDemoSession ? LiveDesign.good : LiveDesign.rec
        }
    }

    /// 0–4 meter bars lit by health quartile; at least one while linked.
    private var litBars: Int {
        guard isLinked else { return 0 }
        guard !model.isDemoSession else { return 4 }
        return max(1, Int((Double(model.linkHealth) / 25.0).rounded(.up)))
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.7), radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(isLinked ? "Active Link" : "No Link")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(LiveDesign.text)
                Text(isLinked ? detail : model.linkHealthDetail)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            index < litBars
                                ? tint.opacity(0.52 + Double(index) * 0.12)
                                : LiveDesign.hairline
                        )
                        .frame(width: 3, height: CGFloat(6 + index * 3))
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: litBars)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LiveDesign.surface,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
        .onAppear {
            displayedFPS = model.liveFPS
        }
        .onChange(of: model.liveFPS) { _, newValue in
            let now = CFAbsoluteTimeGetCurrent()
            guard newValue != displayedFPS else { return }
            guard now - lastFPSCommit >= SettingsLiveTileMetrics.fpsCommitMinInterval else {
                return
            }
            lastFPSCommit = now
            displayedFPS = newValue
        }
    }
}
