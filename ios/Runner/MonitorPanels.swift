import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia
import OpenCineNikon
import OpenZCineCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    /// One resolved grid tile. Video tiles carry their `CommandTileKind` (long-press reorder);
    /// photography tiles mirror the landscape stills strip tile-for-tile in fixed order.
    private struct GridTileSpec: Identifiable {
        let id: String
        let title: String
        let value: String
        let picker: CameraPicker?
        let kind: CommandTileKind?
    }

    private var tiles: [GridTileSpec] {
        if model.isPhotographyMode {
            return model.cameraPropertySnapshot.photographyCaptureValues.map { entry in
                GridTileSpec(
                    id: entry.label,
                    title: stillsTitle(entry.label),
                    value: entry.value,
                    picker: CameraPicker.forValueLabel(entry.label, photography: true),
                    kind: nil)
            }
        }
        return model.visibleCommandGridOrder.map { kind in
            GridTileSpec(
                id: kind.rawValue, title: title(kind), value: value(kind),
                picker: picker(kind), kind: kind)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let tiles = self.tiles
            let rows = max(1, Int((Double(tiles.count) / Double(columns)).rounded(.up)))
            // Fill the height on phones, but never stretch a tile past a readable card —
            // the leftover breathing room reads better than title-and-value islands adrift
            // in an empty slab (the iPad complaint).
            let rowHeight = min(
                150,
                max(44, (proxy.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)))
            let tileWidth = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let isDragging = tile.kind != nil && draggingKind == tile.kind
                    CommandTile(title: tile.title, value: tile.value, height: rowHeight)
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
                        let current = self.tiles
                        let s = slot(
                            at: value.location, tileWidth: tileWidth, rowHeight: rowHeight,
                            count: current.count)
                        guard s < current.count, let picker = current[s].picker else { return }
                        model.showPicker(picker)
                    }
            )
            .gesture(reorderGesture(tileWidth: tileWidth, rowHeight: rowHeight, count: tiles.count))
        }
    }

    /// Grid title for a photography strip label (mirrors the video tiles' casing).
    private func stillsTitle(_ label: String) -> String {
        switch label {
        case "MODE": "Mode"
        case "ISO": "ISO"
        case "SHUTTER": "Shutter"
        case "IRIS": "Iris"
        case "DRIVE": "Drive"
        case "FOCUS": "Focus"
        case "WB": "White Bal"
        case "METER": "Meter"
        case "PROFILE": "Profile"
        default: label
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
                // Photography tiles ride the stills strip's fixed order — no reorder.
                guard !model.isPhotographyMode else { return }
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
        model.shownCameraValue(label) ?? fallback
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
        model.shownCameraValue(label) ?? fallback
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
                // Tall (tablet) tiles carry the value at dashboard scale; phone tiles keep
                // today's 24pt exactly.
                .font(
                    .system(size: height > 120 ? 34 : 24, weight: .medium, design: .monospaced)
                )
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
        .buttonStyle(.monitorTapTarget)
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
                GeometryReader { proxy in
                    NikonAssistInspector(
                        tool: tool, tools: model.liveAssistPaletteTools, viewport: proxy.size,
                        safeArea: EdgeInsets(
                            top: feedSafeArea.top, leading: feedSafeArea.leading,
                            bottom: feedSafeArea.bottom, trailing: feedSafeArea.trailing),
                        onSelect: { model.activePanel = .assist($0) },
                        onDismiss: { model.dismissActivePanel() })
                }
                .ignoresSafeArea()
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
            // Landscape panels cap at the top-popup width and centre over the bar rather than
            // spanning it — a bar-wide drum panel reads as a full-screen sheet.
            let width = hasBar ? min(bar.width, 420) : (isPortrait ? max(0, host.width - 24) : 420)
            let boxWidth =
                hasBar
                ? min(max(width, bar.midX - host.minX + width / 2), host.maxX - host.minX - 8)
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

    /// The picker's contents: every setting shares the `PickerPanel` drum except Stabilization
    /// (two independent on/off toggles, not a value wheel) and the photo Quality pair (two
    /// side-by-side drums with per-half sub-options).
    @ViewBuilder
    private func pickerBodyContent(_ picker: CameraPicker) -> some View {
        if picker == .stillQuality {
            QualityPickerPanel()
        } else if picker == .stabilization {
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
        } else if picker.usesVideoLadder {
            LadderPickerPanel(picker: picker)
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
            // The quality pair needs room for two drums side by side.
            let width: CGFloat = picker == .stillQuality ? 400 : 340
            // Centre the popup on the cell, clamped so it never runs off either screen edge.
            let rawLeading = cell.midX - width / 2
            let leading =
                isCommandCenter
                ? host.midX - width / 2
                : (hasCell
                    ? min(max(rawLeading, host.minX + 8), host.maxX - width - 8)
                    : host.minX + 8)
            // Top edge sits a hair below the cell; the hidden state parks it fully above the
            // screen. A panel taller than the space below the cell (the two-drum quality pair)
            // slides up over the deck rather than clipping at the screen bottom.
            let top =
                isCommandCenter
                ? host.midY - pickerHeight / 2
                : (hasCell
                    ? max(
                        min(cell.maxY + gap, host.maxY - pickerHeight - 8),
                        host.minY + chromeInsets.top + 8)
                    : (host.minY + chromeInsets.top + 8))
            let slide = (top - host.minY) + pickerHeight + 40
            pickerBodyContent(picker)
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
    /// The same codecs as picker rows, so a row the body offers at two bit depths can flank
    /// itself with them. Captured on appear alongside `codecModes`.
    @State private var codecRows: [PTPCameraCodecFamily] = []

    private var isShutterControlLocked: Bool {
        picker == .shutter && model.lockedControls.contains(.shutter)
    }

    private var isISORecordingLocked: Bool {
        picker == .iso && model.isISORecordingLocked
    }

    /// Auto ISO On or non-M (non-R3D): value drum is camera-owned.
    /// R3D NE dual-base is always manual — never locked by exposure mode.
    private var isISOAutoValueLocked: Bool {
        picker == .iso && model.showsAutoISOPicker && model.isISOValueCameraOwned
    }

    private var isPickerInteractionLocked: Bool {
        isShutterControlLocked || isISORecordingLocked
    }

    /// Photo ISO's Auto tab: the drum only mirrors the body's live pick.
    private var isStillISOAutoLocked: Bool {
        picker == .stillISO && selectedMode == 0
    }

    private var isDrumInteractionLocked: Bool {
        isPickerInteractionLocked || isISOAutoValueLocked || isStillISOAutoLocked
            || model.pickerModeDisabled(picker, mode: selectedMode)
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

    /// WB's "Kelvin" tab — dial ladder plus −10 / +10 beside the selected value.
    private var isKelvinMode: Bool {
        picker == .whiteBalance
            && activePickerModes.indices.contains(selectedMode)
            && activePickerModes[selectedMode].title == "Kelvin"
    }

    /// The advertised bit depths flanking the settled CODEC row — 8-bit left, 10-bit right, the
    /// same shape as WB Kelvin's −10 / +10 (Erik's ask on #276). Nil for every codec the body
    /// advertises at a single depth, so a depth the connected body cannot record is never a
    /// button. Both sides write an exact advertised value; the filled one is the depth the
    /// camera's own readback reports, so the pair survives closing and reopening the picker.
    private var codecDepthAdjust: DrumSideAdjust? {
        guard picker == .codec,
            let row = codecRows.first(where: { $0.label == selection }),
            row.offersBitDepthChoice,
            let low = row.depths.first, let high = row.depths.last
        else { return nil }
        let active = model.activeCodecMode?.bitDepth
        return DrumSideAdjust(
            minusEnabled: !isDrumInteractionLocked,
            plusEnabled: !isDrumInteractionLocked,
            onMinus: { model.applyPickerValue(low.label, for: .codec) },
            onPlus: { model.applyPickerValue(high.label, for: .codec) },
            minusTitle: low.bitDepthLabel,
            plusTitle: high.bitDepthLabel,
            minusAccessibilityLabel: "Record \(row.label) at \(low.bitDepth) bit",
            plusAccessibilityLabel: "Record \(row.label) at \(high.bitDepth) bit",
            minusSelected: active == low.bitDepth,
            plusSelected: active == high.bitDepth,
            hint: "Use the bit-depth buttons beside the codec to switch depth")
    }

    private func applyKelvinSideStep(delta: Int) {
        guard
            let next = WhiteBalanceKelvinPolicy.fineAdjust(from: selection, delta: delta),
            next != selection
        else { return }
        selection = next
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }

    /// Common movie values use the opened descriptor token. Nikon mode tabs and fine-tune
    /// controls remain typed adapters; a changed camera circuit retires the common drum.
    private var commonCaptureField: MonitorCaptureField? {
        guard let setting = picker.nikonControlSetting,
            !isTintMode, !isKelvinMode, !isISOAutoValueLocked, !isStillISOAutoLocked,
            !model.isDemoSession, model.videoSource != .relay,
            !model.pickerModeDisabled(picker, mode: selectedMode)
        else { return nil }
        return model.shell.control.captureField(setting.key)
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
                if isISOAutoValueLocked || isStillISOAutoLocked {
                    isoAutoLockBanner
                }
                if isTintMode {
                    // The WB Tint tab swaps the drum for the fine-tune pad.
                    WhiteBalanceTintPad()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let field = commonCaptureField {
                    let offered = currentOptions.compactMap { label in
                        picker.nikonControlSetting.flatMap {
                            NikonCameraSession.setting($0, label: label)
                        }
                    }
                    MonitorCaptureDrum(
                        control: model.shell.control, field: field,
                        enabled: !isDrumInteractionLocked,
                        haptics: model.preferences.hapticsEnabled,
                        choices: field.choices.filter { offered.contains($0.value) },
                        marked: markedValues
                    )
                    .id(selectedMode)
                } else {
                    // −10 / +10 permanently flank the selected Kelvin value; the CODEC drum
                    // reuses the pair for the bit depths a body advertises for that codec.
                    let sideAdjust =
                        !isKelvinMode
                        ? codecDepthAdjust
                        : DrumSideAdjust(
                            minusEnabled: !isDrumInteractionLocked
                                && WhiteBalanceKelvinPolicy.canFineAdjust(
                                    from: selection,
                                    delta: -WhiteBalanceKelvinPolicy.fineStepKelvin),
                            plusEnabled: !isDrumInteractionLocked
                                && WhiteBalanceKelvinPolicy.canFineAdjust(
                                    from: selection,
                                    delta: WhiteBalanceKelvinPolicy.fineStepKelvin),
                            onMinus: {
                                applyKelvinSideStep(
                                    delta: -WhiteBalanceKelvinPolicy.fineStepKelvin)
                            },
                            onPlus: {
                                applyKelvinSideStep(
                                    delta: WhiteBalanceKelvinPolicy.fineStepKelvin)
                            }
                        )
                    HStack(spacing: 8) {
                        if let sideAdjust {
                            DrumSideAdjustButton(
                                title: sideAdjust.minusTitle, enabled: sideAdjust.minusEnabled,
                                selected: sideAdjust.minusSelected,
                                label: sideAdjust.minusAccessibilityLabel,
                                action: sideAdjust.onMinus)
                        }
                        MonitorValueDrum(
                            options: currentOptions, selection: $selection,
                            markedValues: markedValues, isInteractive: !isDrumInteractionLocked,
                            haptics: model.preferences.hapticsEnabled)
                        if let sideAdjust {
                            DrumSideAdjustButton(
                                title: sideAdjust.plusTitle, enabled: sideAdjust.plusEnabled,
                                selected: sideAdjust.plusSelected,
                                label: sideAdjust.plusAccessibilityLabel,
                                action: sideAdjust.onPlus)
                        }
                    }
                    .accessibilityHint(sideAdjust?.hint ?? "")
                    // Fresh drum per mode tab: ANGLE→SPEED (or ISO Low→High) swaps the option set
                    // and the centred value at once.
                    .id(selectedMode)
                }
                if picker == .stillDrive, selectedMode == 1 || selectedMode == 2 {
                    // The timers' shared shot count rides inside both timer tabs — fired by
                    // the app after the countdown (the body's own count is menu-only).
                    timerShotsRow
                }
                if !activePickerModes.isEmpty {
                    modeBar
                }
                if picker == .focus || picker == .stillFocus {
                    mfScrubToggleRow
                }
            }
        }
        // Seed once on appear — NOT in `body`. Camera state is reassigned every live-view frame, so
        // reading it per render would re-render the drum mid-spin and break its momentum. Open on the
        // mode the current value lives in (e.g. ISO 800 → Low Base, focus AF-C → AF Mode).
        .onAppear {
            if picker == .iris || picker == .stillIris {
                lensApertures = model.irisApertures
            }
            if picker == .resolution {
                screenModes = model.resolutionOptions
            }
            if picker == .codec {
                codecRows = model.codecFamilies
                codecModes = codecRows.map(\.label)
            }
            // Dual-circuit pickers always open on the camera's active circuit (`movieBaseISO` /
            // `movieShutterMode`), never via overlapping ISO steps or `showPicker`'s default mode.
            if picker == .iso {
                selectedMode = model.isoPickerModeIndex
            } else if picker == .stillISO {
                selectedMode = model.stillISOPickerModeIndex
            } else if picker == .shutter {
                selectedMode = model.shutterPickerModeIndex
            } else if picker == .whiteBalance {
                // The body's WB mode picks the opening tab: a named preset opens PRESET;
                // colour temperature (or an unknown mode) opens KELVIN. The camera stays
                // source of truth — never a remembered tab.
                let mode = model.cameraPropertySnapshot.wbMode
                selectedMode = (mode == nil || mode == "Color temp") ? 0 : 1
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
        // Keep the photo Auto/Manual tab aligned with the body's Auto ISO readback — the
        // camera stays ground truth for a toggle flipped in its own menus.
        .onChange(of: model.stillISOPickerModeIndex) { _, modeIndex in
            guard picker == .stillISO, selectedMode != modeIndex else { return }
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
        // Auto ISO: keep the locked drum centred on the body's effective ISO as it changes
        // (movie Auto and the photo Auto tab alike).
        .onChange(of: model.cameraPropertySnapshot.iso) { _, iso in
            let autoTracks = (picker == .iso && isISOAutoValueLocked) || isStillISOAutoLocked
            guard autoTracks, let iso, iso > 0 else { return }
            let next = String(iso)
            guard next != selection else { return }
            selection = next
            lastApplied = next
        }
        // Confirm-on-snap: apply each newly-centred value to the active mode's target.
        .onChange(of: selection) { oldValue, newValue in
            guard !isDrumInteractionLocked else { return }
            guard !newValue.isEmpty, newValue != lastApplied else { return }
            // A descriptor refresh (60 s cadence, lens swap, shutter-circuit switch) can reshape
            // the option list while the picker is open. When the centred value leaves the list,
            // SwiftUI re-resolves `.scrollPosition` onto a neighbouring row and writes it back
            // through the binding — that is the LIST moving, not the operator, and pushing it to
            // the camera would change a setting nobody touched. Re-baseline silently instead.
            guard currentOptions.contains(oldValue) else {
                lastApplied = newValue
                return
            }
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

    /// `[−] n [+]` stepper for the timers' shot count, dimmed with its tab's gating.
    private var timerShotsRow: some View {
        let disabled = model.pickerModeDisabled(picker, mode: selectedMode)
        return HStack(spacing: 12) {
            Text("Shots")
                .font(.system(size: 12, weight: .semibold))
                .kerning(1)
                .textCase(.uppercase)
                .foregroundStyle(LiveDesign.muted)
            Spacer(minLength: 8)
            timerShotsStepButton("minus", enabled: model.photoTimerShotCount > 1) {
                model.adjustPhotoTimerShots(by: -1)
            }
            Text("\(model.photoTimerShotCount)")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .frame(minWidth: 28)
                .contentTransition(.numericText())
            timerShotsStepButton("plus", enabled: model.photoTimerShotCount < 9) {
                model.adjustPhotoTimerShots(by: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LiveDesign.background.opacity(0.28),
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        }
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }

    /// Focus popup toggle for the live-view focus scrub strip (shows in AF modes on a
    /// focus-by-wire lens). Off hides the strip regardless of mode.
    private var mfScrubToggleRow: some View {
        @Bindable var model = model
        return Toggle(isOn: $model.mfDriveScrubEnabled) {
            Text("Focus dial")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
        }
        .toggleStyle(SwitchToggleStyle(tint: LiveDesign.accent))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LiveDesign.background.opacity(0.28),
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        }
    }

    private func timerShotsStepButton(
        _ symbol: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? LiveDesign.accent : LiveDesign.faint)
                .frame(width: 32, height: 32)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.monitorTapTarget)
        .disabled(!enabled)
    }

    /// Segmented tabs (e.g. ANGLE / SPEED) beneath the wheel; the active tab is gold-outlined.
    private var modeBar: some View {
        // When any tab carries a detail line, every tab reserves the two-line height so the
        // row reads as one bar instead of mismatched chips.
        let anyDetail = activePickerModes.contains { $0.detail != nil }
        return HStack(spacing: 10) {
            ForEach(Array(activePickerModes.enumerated()), id: \.offset) { index, mode in
                let active = index == selectedMode
                let modeDisabled = model.pickerModeDisabled(picker, mode: index)
                Button {
                    guard !isPickerInteractionLocked, !modeDisabled else { return }
                    selectedMode = index
                    // Re-centre on the mode's own value: a circuit's base (ISO High → 6400) or an
                    // independent FOCUS tab's stored value.
                    let value = model.pickerModeValue(picker, mode: index)
                    selection = value
                    lastApplied = value
                    // ISO dual-base: switch Low/High on the body before applying the circuit value.
                    if picker == .iso, model.showsDualBaseISOPicker {
                        model.switchBaseISO(highBase: index == 1)
                    }
                    // ISO auto control (non-R3D NE): Auto On/Off toggles MovISOAutoControl.
                    if picker == .iso, model.showsAutoISOPicker {
                        model.switchAutoISO(enabled: index == 0)
                        // Auto On: no ISO write. Auto Off: apply the drum value in manual ISO.
                        if index == 0 { return }
                    }
                    if picker == .stillISO {
                        model.switchStillAutoISO(enabled: index == 0)
                        // Auto: the body owns the value. Manual: fall through and apply it.
                        if index == 0 { return }
                    }
                    if picker == .shutter {
                        model.switchShutterMode(speedMode: index == 1)
                    }
                    // Switching a circuit is itself a camera change, so confirm the mode's value
                    // right away — no drum nudge needed. Exceptions: shutter ANGLE/SPEED only
                    // selects the active stored circuit (`movieShutterMode`; a value write here
                    // can fail and falsely engage lock), and FOCUS / photo SIZE / photo DRIVE
                    // tabs are independent settings, so switching writes nothing. `lastApplied`
                    // is pre-set above so this write isn't duplicated by the `selection`
                    // `onChange`.
                    if picker != .focus, picker != .shutter, picker != .stillSize,
                        picker != .stillDrive, picker != .stillFocus, picker != .stillMode
                    {
                        model.applyPicker(picker, mode: index, value: value)
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(mode.title)
                            .font(.system(size: 13, weight: .bold, design: .default))
                            .kerning(0.5)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let detail = mode.detail {
                            Text(detail)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundStyle(active ? LiveDesign.accent : LiveDesign.muted)
                    .frame(maxWidth: .infinity, minHeight: anyDetail ? 46 : 1)
                    .padding(.vertical, mode.detail == nil ? (anyDetail ? 5 : 12) : 9)
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
                .buttonStyle(.monitorTapTarget)
                .opacity(modeDisabled ? 0.35 : 1)
                .disabled(modeDisabled)
                // Full locks (shutter / R3D record) freeze tabs; Auto ISO only freezes the drum.
                .opacity(isPickerInteractionLocked ? 0.55 : 1)
                .allowsHitTesting(!isPickerInteractionLocked)
            }
        }
    }

    private var isoAutoLockBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(isoAutoLockBannerText)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(LiveDesign.accent.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.accentDim,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
        )
    }

    private var isoAutoLockBannerText: String {
        if model.allowsManualISO {
            return
                "Auto ISO is on — the camera sets sensitivity. "
                + "Switch to Auto Off to choose a value."
        }
        return
            "Manual ISO needs exposure mode M. "
            + "The camera is setting sensitivity."
    }

    /// The drum's options for the active mode. IRIS is restricted to the mounted lens's reachable
    /// apertures; moded settings (ISO circuits, shutter angle/speed) swap the wheel per mode; the
    /// rest fall back to the flat picker list.
    private var currentOptions: [String] {
        if picker == .iris || picker == .stillIris, !lensApertures.isEmpty {
            return lensApertures
        }
        if picker == .resolution, !screenModes.isEmpty { return screenModes }
        if picker == .codec, !codecModes.isEmpty { return codecModes }
        if picker == .iso {
            // Inject live Auto ISO when it sits outside the fixed ladder (e.g. 51200).
            let liveISO: String? = {
                guard model.showsAutoISOPicker else { return nil }
                if let iso = model.cameraPropertySnapshot.iso, iso > 0 {
                    return String(iso)
                }
                return nil
            }()
            return ISOPickerPolicy.options(
                codec: model.cameraState.codec,
                modeIndex: selectedMode,
                includingLiveISO: liveISO)
        }
        // Kelvin dial ladder, with the live / fine-tuned value inserted when off-ladder.
        if isKelvinMode {
            return WhiteBalanceKelvinPolicy.options(including: selection)
        }
        // Camera-advertised options for the active mode (focus tabs, shutter angle/speed, WB preset)
        // take precedence over the hardcoded list. Read live from the model — the ZR refreshes the
        // speed enum only after switching to speed mode, so a one-shot capture on appear would stick
        // on the single placeholder value advertised while in angle mode.
        if var property = picker.optionProperty(forMode: selectedMode) {
            // The photography WB popup reuses the movie picker — its preset enum comes from
            // the stills WB property instead.
            if property == .movieWhiteBalance, model.isPhotographyMode {
                property = .whiteBalance
            }
            // A body advertising exactly one value means exactly one value is selectable — show
            // that, not the app's union. (The shutter circuits' single-value PLACEHOLDER enum is
            // filtered upstream in `refreshControlOption`, so it never reaches this cache.)
            if let cameraMode = model.cameraControlOptions[property], !cameraMode.isEmpty {
                // R3D NE forbids automatic WB, and the codec can change after the enum was
                // cached — filter at read time, not cache time. Movie chrome only: stills WB
                // keeps its autos regardless of the movie codec left behind.
                if property == .movieWhiteBalance {
                    return PTPCameraPropertyDecoders.whiteBalanceOptions(
                        advertised: cameraMode, codec: model.cameraState.codec)
                }
                // Same read-time shape as the WB filter above: the body's SET, this drum's order,
                // and without the two positions the DRIVE tab does not own.
                if picker == .stillDrive {
                    return StillDriveMode.driveDrumOptions(advertised: cameraMode)
                }
                return cameraMode
            }
        }
        guard !activePickerModes.isEmpty else { return picker.options }
        let hardcoded = activePickerModes[selectedMode].options
        let resolved = hardcoded.isEmpty ? picker.options : hardcoded
        if picker == .whiteBalance, !model.isPhotographyMode,
            activePickerModes[selectedMode].title == "Preset"
        {
            return PTPCameraPropertyDecoders.whiteBalanceOptions(
                advertised: resolved, codec: model.cameraState.codec)
        }
        return resolved
    }
}

/// Stabilization picker (movie VR + electronic VR) for the command monitor's VR tile. Unlike the
/// other settings, VR and e-VR are two independent on/off-style toggles rather than one value wheel,
/// so this renders its own row-of-buttons layout instead of `PickerPanel`'s value drum.
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
/// A pair of buttons flanking the settled drum value: WB Kelvin's −10 / +10, and the CODEC
/// drum's advertised bit depths (8-bit left, 10-bit right — same idiom, Erik's ask on #276).
/// The captions default to the Kelvin pair so that call site stays as it was.
struct DrumSideAdjust {
    var minusEnabled: Bool
    var plusEnabled: Bool
    var onMinus: () -> Void
    var onPlus: () -> Void
    var minusTitle: String = "−10"
    var plusTitle: String = "+10"
    var minusAccessibilityLabel: String = "Decrease Kelvin by 10"
    var plusAccessibilityLabel: String = "Increase Kelvin by 10"
    /// Filled treatment for a side that IS the current camera value (the active bit depth).
    /// Kelvin's steps are relative nudges, so neither side is ever "selected" there.
    var minusSelected: Bool = false
    var plusSelected: Bool = false
    /// Accessibility hint for the drum carrying the pair.
    var hint: String = "Use minus 10 and plus 10 beside the selected value to fine-adjust"
}

/// The photo Quality picker: two side-by-side drums — RAW on/off and the JPEG/HEIF tier —
/// each with its sub-option beneath (NEF compression under RAW, the ★ optimal-quality toggle
/// under the tier). The pair composes one image-quality write; NEF compression writes its own
/// property. There is no nothing-selected quality on the body, so turning the last active half
/// off bounces the other half back on, and each half's sub-option dims while that half is off.
struct QualityPickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    /// The composed pair, seeded from the camera once on appear (never re-read in `body` —
    /// the wheels would jog mid-spin like every other drum).
    @State private var config = StillQualityConfiguration(
        rawEnabled: true, tier: .fine, starred: false)
    @State private var rawSelection = ""
    @State private var tierSelection = ""
    /// Last composed label written, so bounces and re-seeds don't fire redundant writes.
    @State private var lastApplied = ""

    private static let rawOptions = ["On", "Off"]
    private static let tierOptions = StillQualityConfiguration.Tier.allCases.map(\.rawValue)
    /// Conservative fallback only — the body's own `RawCompressionType` enum wins below.
    /// First-generation Z bodies use the Compressed/Uncompressed pair and reject this trio, so
    /// offering it unconditionally is the same "options the body does not have" defect (#274).
    private static let nefOptions = [
        "High efficiency", "High efficiency★", "Lossless compression",
    ]

    var body: some View {
        GlassPanel(
            padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                PickerHeader(label: "QUALITY", subtitle: CameraPicker.stillQuality.subtitle) {
                    model.dismissActivePanel()
                }
                HStack(alignment: .top, spacing: 16) {
                    column(caption: "RAW") {
                        MonitorValueDrum(
                            options: Self.rawOptions, selection: $rawSelection,
                            haptics: model.preferences.hapticsEnabled)
                        nefRows
                    }
                    column(caption: "JPEG · HEIF") {
                        MonitorValueDrum(
                            options: Self.tierOptions, selection: $tierSelection,
                            haptics: model.preferences.hapticsEnabled)
                        starToggle
                    }
                }
            }
        }
        .onAppear(perform: seed)
        .onChange(of: rawSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            let enabled = newValue == "On"
            guard enabled != config.rawEnabled else { return }
            config.rawEnabled = enabled
            if !enabled, config.tier == .off {
                // Dropping RAW with the tier off would select nothing — bounce the tier on.
                config.tier = .fine
                tierSelection = config.tier.rawValue
            }
            applyIfChanged()
        }
        .onChange(of: tierSelection) { _, newValue in
            guard let tier = StillQualityConfiguration.Tier(rawValue: newValue),
                tier != config.tier
            else { return }
            config.tier = tier
            if tier == .off {
                config.starred = false
                if !config.rawEnabled {
                    // Tier off with RAW off would select nothing — bounce RAW on.
                    config.rawEnabled = true
                    rawSelection = "On"
                }
            }
            applyIfChanged()
        }
    }

    /// A captioned drum column, equal-width so the two wheels split the panel evenly.
    private func column(
        caption: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(1.5)
                .foregroundStyle(LiveDesign.faint)
                .frame(maxWidth: .infinity, alignment: .center)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    /// The NEF (RAW) recording compression rows — a RAW setting, parked while RAW is off.
    private var nefRows: some View {
        let enabled = config.rawEnabled
        let current = model.cameraPropertySnapshot.rawCompression
        let options = model.cameraControlOptions[.rawCompressionType] ?? Self.nefOptions
        return VStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                optionChip(option, active: current == option, enabled: enabled) {
                    model.applyStillRawCompression(option)
                }
            }
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    /// The ★ optimal-quality toggle — meaningless with the tier off, so it dims there.
    private var starToggle: some View {
        let enabled = config.tier != .off
        return optionChip("★ Optimal quality", active: config.starred, enabled: enabled) {
            config.starred.toggle()
            applyIfChanged()
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    /// A compact selectable row in the mode-bar chip style.
    private func optionChip(
        _ label: String, active: Bool, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(active ? LiveDesign.accent : LiveDesign.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    active ? LiveDesign.accentDim : LiveDesign.background.opacity(0.28),
                    in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                        .stroke(active ? LiveDesign.accent : LiveDesign.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.monitorTapTarget)
    }

    private func seed() {
        guard rawSelection.isEmpty else { return }
        if let label = model.cameraPropertySnapshot.compression,
            let code = PTPCameraPropertyDecoders.compressionSettingCode(for: label),
            let decoded = StillQualityConfiguration.decode(compressionCode: code)
        {
            config = decoded
        }
        rawSelection = config.rawEnabled ? "On" : "Off"
        tierSelection = config.tier.rawValue
        lastApplied = config.compressionLabel ?? ""
    }

    private func applyIfChanged() {
        guard let label = config.compressionLabel, label != lastApplied else { return }
        lastApplied = label
        model.applyPicker(.stillQuality, mode: 0, value: label)
    }
}

/// One button flanking a picker drum. `selected` fills it solid: the CODEC pair shows which bit
/// depth the body is on; Kelvin's relative steps never set it.
struct DrumSideAdjustButton: View {
    let title: String
    let enabled: Bool
    var selected = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(
                    selected
                        ? LiveDesign.background : (enabled ? LiveDesign.accent : LiveDesign.faint)
                )
                .frame(width: 56, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? LiveDesign.accent : LiveDesign.accentDim)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            enabled ? LiveDesign.accent : LiveDesign.hairline, lineWidth: 1.5)
                )
        }
        // 56×40 draws smaller than the 44pt HIG minimum on one axis, and the panel's glass
        // ripples past the drawn edge — pad the hit test out to it (`minTapTarget`).
        .buttonStyle(.monitorTapTarget)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Supplies current source-calibrated bindings to the concrete shared assist menus.
@MainActor struct NikonAssistMenuAdapter {
    let model: NativeAppModel
    var compact: Bool = false

    /// Nikon renders three ramps; the shared CineStop ramp has no Nikon counterpart.
    static let falseColorScales: [MonitorFalseColorSelection] = [.sceneStops, .ire, .limits]

    var falseColor: MonitorFalseColorMenu<MonitorFalseColorSelection> {
        MonitorFalseColorMenu(
            scales: Self.falseColorScales,
            scale: model.assist.binding(\.falseColorScale),
            referenceEnabled: model.assist.binding(\.falseColorReference),
            optionalReference: falseColorReference,
            title: { scale in
                switch scale.nikonScale {
                case .stops: "ZC Stops"
                case .ire: "IRE"
                case .limits: "Limits"
                }
            },
            scaleHelp:
                "The camera signal selects Log3G10 or N-Log automatically. ZC Stops marks minimum exposure, −3, 18% gray, skin, +2, and clip-relative highlight levels. IRE reads the curve-aware monitoring scale. Limits paints shadow and highlight warnings.",
            readHelp: "",
            referenceHelp: "Show a compact color key over live view while False Color is active.",
            compact: compact, selectionFeedback: selectionFeedback,
            referenceFeedback: selectionFeedback,
            onReferenceEnabled: { model.setAssist(.falseColor, visible: true) })
    }

    private var falseColorReference: MonitorFalseColorReferenceValues {
        FalseColorReference.values(
            scale: model.assist.falseColorScale.nikonScale, mapping: model.exposureSignalMapping)
    }

    var zebra: MonitorZebraMenu<AssistConfiguration.Zebra.Unit, MonitorZebraPaint> {
        MonitorZebraMenu(
            units: AssistConfiguration.Zebra.Unit.allCases,
            unit: Binding(
                get: { model.assistConfiguration.zebra.unit },
                set: { model.assistConfiguration.zebra.unit = $0 }),
            title: { $0 == .native ? "0-255" : "IRE" }, unitsTitle: "Units",
            unitsHelp:
                "Switch between Nikon-style native 0-255 codes and OpenZCine's normalized 0-100 monitoring IRE scale.",
            highlightHelp:
                "High zebra warns when bright detail approaches clipping after the active log curve is compensated.",
            midtoneHelp:
                "Midtone zebra marks the chosen monitoring level after curve compensation.",
            highlight: zebraZone(highlight: true), midtone: zebraZone(highlight: false),
            compact: compact, selectionFeedback: selectionFeedback,
            toggleFeedback: selectionFeedback)
    }

    private func zebraZone(highlight: Bool) -> MonitorZebraNumberZone<
        MonitorZebraPaint
    > {
        let assist = model.assist
        let unit = model.assistConfiguration.zebra.unit
        let level: ReferenceWritableKeyPath<NikonAssistState, Double> =
            highlight ? \.zebraHighlightIRE : \.zebraMidtoneIRE
        let threshold = Binding(
            get: {
                unit.displayValue(for: assist[keyPath: level], mapping: model.exposureSignalMapping)
            },
            set: {
                let ire = unit.monitorPercent(fromDisplay: $0, mapping: model.exposureSignalMapping)
                // In place, so observers hear it even when the level is unchanged (a plain set
                // skips equal values): a native code past the curve's clip then redraws as the
                // threshold it maps to.
                func write(_ stored: inout Double) { stored = ire }
                if highlight {
                    write(&assist.zebraHighlightIRE)
                } else {
                    write(&assist.zebraMidtoneIRE)
                }
                assist.persist()
            })
        let colors = (highlight ? SettingsPalette.highlight : SettingsPalette.midtone).compactMap {
            dot in
            MonitorZebraPaint(rawValue: dot.name).map {
                MonitorSettingsColorDot(value: $0, title: dot.name, color: dot.color)
            }
        }
        return MonitorZebraNumberZone(
            enabled: assist.binding(highlight ? \.zebraHighlight : \.zebraMidtone),
            entry: MonitorZebraNumberEntry(
                value: threshold,
                maximum: unit == .native ? 255 : 100,
                identifier: "settings.zebra.threshold.\(highlight ? "Highlight" : "Midtone")"),
            colors: colors,
            paint: assist.binding(highlight ? \.zebraHighlightColor : \.zebraMidtoneColor))
    }

    var waveform: MonitorScopeTraceMenu<MonitorWaveformMode> {
        let options = model.scopePanels.waveform.optionsBinding
        return MonitorScopeTraceMenu(
            modes: MonitorWaveformMode.allCases, mode: options.mode,
            brightness: Binding(
                get: { options.wrappedValue.brightness },
                set: {
                    options.wrappedValue.brightness = MonitorWaveformOptions.clampedBrightness($0)
                }),
            guides: options.guides, title: { $0.rawValue },
            brightnessHelp: "Raise trace intensity when the preview is dark or low contrast.",
            compact: compact, modeFeedback: selectionFeedback, guideFeedback: selectionFeedback)
    }

    var parade: MonitorScopeTraceMenu<MonitorParadeMode> {
        let options = model.scopePanels.parade.optionsBinding
        return MonitorScopeTraceMenu(
            modes: MonitorParadeMode.allCases, mode: options.mode,
            brightness: Binding(
                get: { options.wrappedValue.brightness },
                set: {
                    options.wrappedValue.brightness = MonitorParadeOptions.clampedBrightness($0)
                }),
            guides: options.guides, title: { $0.rawValue },
            brightnessHelp: "Raise trace intensity for the separated channel lanes.",
            compact: compact, modeFeedback: selectionFeedback, guideFeedback: selectionFeedback)
    }

    var vectorscope: MonitorVectorscopeMenu {
        let options = model.scopePanels.vectorscope.optionsBinding
        return MonitorVectorscopeMenu(
            zoom: options.zoom,
            brightness: Binding(
                get: { options.wrappedValue.brightness },
                set: {
                    options.wrappedValue.brightness = MonitorVectorscopeOptions.clampedBrightness(
                        $0)
                }),
            zoomHelp:
                "Magnifies only the chroma trace; the graticule stays at unity. The vectorscope reads the monitor image after its active LUT or display tone map.",
            brightnessHelp: "Raise trace intensity when the chroma plot is hard to read.",
            compact: compact, zoomFeedback: selectionFeedback)
    }

    private var compensation: Binding<MonitorCrushClipCompensation> {
        model.assist.binding(\.crushClipCompensation)
    }

    var histogram: MonitorHistogramMenu {
        MonitorHistogramMenu(
            trafficLights: model.scopePanels.histogram.optionsBinding.trafficLights,
            compensation: compensation,
            trafficHelp: "Show small RGB edge blocks for crushed and clipped channels.",
            compensationHelp:
                "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter.",
            compact: compact, trafficFeedback: selectionFeedback)
    }

    var trafficLights: MonitorCrushClipMenu {
        MonitorCrushClipMenu(
            compensation: compensation,
            help:
                "Stops of crush/clip tolerance before a channel indicator glows. Shared with histogram traffic lights.",
            compact: compact, showTopDivider: false)
    }

    var peaking: MonitorPeakingMenu {
        MonitorPeakingMenu(
            options: Binding(
                get: {
                    MonitorPeakingOptions(
                        color: model.assist.peakingColor,
                        sensitivity: model.assist.peakingSensitivity)
                },
                set: {
                    model.assist.peakingColor = $0.color
                    model.assist.peakingSensitivity = $0.sensitivity
                    model.assist.persist()
                }),
            colors: SettingsPalette.peaking.compactMap { dot in
                MonitorPeakingColor(rawValue: dot.name).map {
                    MonitorSettingsColorDot(value: $0, title: dot.name, color: dot.color)
                }
            },
            sensitivityHelp:
                "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
            colorHelp: "Choose the edge color that stays readable over your typical scene.",
            compact: compact, feedback: selectionFeedback)
    }

    private func selectionFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }
}

/// Tabbed LUT picker in the assist panel: category tabs over a drum of that category's looks.
struct LUTPickerContent: View {
    private struct PendingLUTDeletion: Identifiable {
        let category: LUTCategory
        let lut: StoredCustomLUT
        var id: String { "\(category.rawValue):\(lut.fileName)" }
    }

    @Environment(NativeAppModel.self) private var model
    @State private var category: LUTCategory = .builtIn
    @State private var importing = false
    @State private var redFilter: RedOutputFilter = .all
    @State private var pendingDeletion: PendingLUTDeletion?
    @State private var deletionErrorMessage: String?
    @State private var importErrorMessage: String?
    /// Tracks whether a usable internet path exists, so the RED download (which needs the public
    /// internet) is blocked while the phone is on the camera's local-only Wi‑Fi AP.
    /// Shared instance — see `InternetReachability.shared` for why a per-view `@State` is banned.
    private var reachability: InternetReachability { .shared }

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
    ///
    /// Landscape is ~400pt tall and this panel had no headroom left, so the 50/50 row below is
    /// paid for out of the drum rather than added to the panel — at 180 the panel's own header
    /// and the category tabs went off the top of the screen.
    private let contentHeight: CGFloat = 146
    private let footerHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 8) {
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
            splitComparisonControls
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
        .alert(
            "Couldn’t Import LUT",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } })
        ) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "The LUT could not be imported.")
        }
    }

    /// The 50/50 Log-vs-LUT comparison: an off-by-default toggle, with its orientation revealed
    /// beside it only while it is on. The orientation stays persisted either way, so switching the
    /// comparison off and back on returns to the operator's own choice.
    ///
    /// One row, not a stacked toggle-then-picker: landscape is ~400pt tall and this panel already
    /// spends most of it on the drum, so the two-row version pushed the category tabs off the top
    /// of the screen.
    @ViewBuilder private var splitComparisonControls: some View {
        HStack(spacing: 10) {
            Button {
                model.assist.splitComparison.toggle()
                model.assist.persist()
                OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                // Comparison is meaningless with the grade off, so switching it on switches the
                // tool on — the same rule the category tabs follow. Arming also clears the on-feed
                // key's mute, so the split is showing when the operator comes back to the image.
                if model.assist.splitComparison {
                    model.splitComparisonMuted = false
                    model.setAssist(.lut, visible: true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: model.assist.splitComparison
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(
                        model.assist.splitComparison
                            ? LiveDesign.accent : LiveDesign.muted)
                    Text("50/50")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(LiveDesign.text)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    model.assist.splitComparison
                        ? LiveDesign.accentDim : LiveDesign.glassBright,
                    in: Capsule())
            }
            .buttonStyle(.monitorTapTarget)
            if model.assist.splitComparison {
                SegmentedButtons(
                    items: SplitComparisonOrientation.allCases.map(\.rawValue),
                    selected: (model.assist.splitVertical
                        ? SplitComparisonOrientation.vertical : .horizontal).rawValue
                ) { raw in
                    guard let next = SplitComparisonOrientation(rawValue: raw) else { return }
                    model.assist.splitVertical = next == .vertical
                    model.assist.persist()
                    OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                }
            } else {
                Spacer(minLength: 0)
            }
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

    /// Height reserved under the built-in drum for the contributor credit. Always reserved, never
    /// conditional: a line that appears only on the contributed look would resize the drum mid-scroll.
    private let creditHeight: CGFloat = 16

    /// The look the built-in drum is currently on — `nil` while a stored LUT is applied.
    private var selectedBuiltIn: MonitorLUT? {
        guard case .builtIn(let look) = model.assistConfiguration.selectedLUT else { return nil }
        return look
    }

    @ViewBuilder private var tabContent: some View {
        switch category {
        case .builtIn:
            VStack(spacing: 0) {
                AccentDrumWheel(
                    options: MonitorLUT.allCases.map(\.rawValue),
                    selection: Binding(
                        get: {
                            selectedBuiltIn?.rawValue
                                ?? MonitorLUT.allCases.first?.rawValue ?? ""
                        },
                        set: { name in
                            guard let look = MonitorLUT(rawValue: name) else { return }
                            model.assistConfiguration.selectedLUT = .builtIn(look)
                            // Picking a look turns the LUT on; the bar toggle is the only "off".
                            model.setAssist(.lut, visible: true)
                        }
                    ),
                    wheelHeight: contentHeight - creditHeight
                )
                // Community-contributed looks are credited here rather than in the label — the drum
                // is one narrow monospaced line and a name would push the look's own name out.
                Text(selectedBuiltIn?.credit ?? "")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LiveDesign.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: creditHeight)
            }
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
                .buttonStyle(.monitorTapTarget)
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

    private var filteredRedLUTs: [StoredCustomLUT] {
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
        .buttonStyle(.monitorTapTarget)
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
        .buttonStyle(.monitorTapTarget)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]
        ) { result in
            if case .success(let url) = result {
                do {
                    try model.importCustomLUT(from: url)
                } catch {
                    importErrorMessage = error.localizedDescription
                }
            }
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

enum SettingsPalette {
    struct Dot {
        let name: String
        let color: Color
    }

    static let highlight: [SettingsPalette.Dot] = [
        .init(name: "White", color: LiveDesign.text),
        .init(name: "Amber", color: LiveDesign.accent),
        .init(name: "Red", color: LiveDesign.rec),
    ]
    static let midtone: [SettingsPalette.Dot] = [
        .init(name: "Amber", color: LiveDesign.accent),
        .init(name: "Cyan", color: LiveDesign.info),
        .init(name: "Green", color: LiveDesign.good),
    ]
    static let peaking: [SettingsPalette.Dot] = [
        .init(name: "White", color: LiveDesign.text),
        .init(name: "Blue", color: LiveDesign.info),
        .init(name: "Red", color: LiveDesign.rec),
        .init(name: "Green", color: LiveDesign.good),
    ]
}

extension MonitorSettingsTab {
    /// Screenshot affordance (link/assist/controls/display/storage/system) picking the initial
    /// rail tab. Defaults to Link in normal launches.
    static var demoLaunchTab: MonitorSettingsTab {
        demoLaunchTab(DemoHarness.panelTab)
    }

    static func demoLaunchTab(_ rawValue: String?) -> MonitorSettingsTab {
        switch rawValue {
        case "sharing": .sharing
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
    case featureRequest
    case sourceCode
    case privacyPolicy
    case termsOfUse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .support: "Support"
        case .featureRequest: "Request a Feature"
        case .sourceCode: "Source Code"
        case .privacyPolicy: "Privacy Policy"
        case .termsOfUse: "Terms of Use"
        }
    }

    var webURL: URL? {
        switch self {
        case .support: SupportLinkCatalog.support
        case .featureRequest: SupportLinkCatalog.featureRequest
        case .sourceCode: SupportLinkCatalog.source
        case .privacyPolicy: SupportLinkCatalog.privacy
        case .termsOfUse: SupportLinkCatalog.terms
        }
    }

    var confirmationMessage: String {
        "To open \(title), OpenZCine will disconnect from the camera's Wi-Fi and switch to cellular or another internet-connected Wi-Fi network. You can reconnect to the camera after you finish."
    }

    static func demoValue(_ rawValue: String?) -> SettingsInternetDestination? {
        switch rawValue {
        case "support": .support
        case "feature": .featureRequest
        default: nil
        }
    }
}

/// The settings cover has its own presentation environment. Observe its containing window
/// here so rotation cannot replace a physical cutout lane with child GeometryReader insets.
private struct NikonSettingsViewport<Content: View>: View {
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    let fallback: MonitorEdgeInsets
    @ViewBuilder let content: (EdgeInsets, Bool) -> Content

    var body: some View {
        GeometryReader { proxy in
            let insets =
                windowGeometry.validSize == nil
                ? EdgeInsets(
                    top: CGFloat(fallback.top), leading: CGFloat(fallback.leading),
                    bottom: CGFloat(fallback.bottom), trailing: CGFloat(fallback.trailing))
                : EdgeInsets(
                    top: windowGeometry.safeArea.top + windowGeometry.topControlInset,
                    leading: windowGeometry.safeArea.leading,
                    bottom: windowGeometry.safeArea.bottom,
                    trailing: windowGeometry.safeArea.trailing)
            content(insets, proxy.size.height > proxy.size.width)
        }
    }
}

struct OperatorSettingsPanel: View {
    /// Real device safe-area insets (carries the landscape Dynamic Island lane) so the full-screen
    /// surface can fill the physical screen yet keep its content clear of the cutout.
    var safeArea: MonitorEdgeInsets = .zero

    @Environment(NativeAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// Bumped on Frame.io sign-in/out so the Storage card re-reads the (non-observable)
    /// keychain state.
    @State private var frameioAccountStamp = 0
    @State private var frameioSigningIn = false
    @State private var frameioSignInError: String?
    @State private var showFrameioHopConfirm = false
    /// Digits typed so far; the model takes the passcode only at four digits or empty.
    @State private var relayPasscodeDraft: String?
    @State private var cacheSizeBytes: UInt64?
    @State private var diagnosticsShareItem: DiagnosticsShareItem?
    @State private var diagnosticsErrorMessage: String?
    @State private var externalLinkErrorMessage: String?
    @State private var pendingInternetDestination: SettingsInternetDestination?
    @State private var isPreparingDiagnostics = false
    /// Which DISP section on the Display tab is open. All three start collapsed — the tab is a
    /// short list of modes at a glance, and you open the one you want to set up.
    @State private var expandedDispSection: DispMode?
    /// Which capture side the Display tab's DISP sections are editing. `nil` until the operator
    /// picks one, so the tab opens on whichever side the camera is actually in.
    @State private var displayCaptureMode: CaptureLayoutMode?
    /// Standalone setup is already a root cover, so its report flow is presented above that cover.
    /// Camera-backed setup uses the root-owned presentation instead, which survives an AP hop.
    @State private var standaloneBugReportPresented = false
    @State private var reliabilityOptIn = ReliabilityDiagnostics.reporting.isOptedIn

    private var selectedTab: MonitorSettingsTab {
        get { model.operatorSettingsTab }
        nonmutating set { model.operatorSettingsTab = newValue }
    }

    var body: some View {
        NikonSettingsViewport(fallback: safeArea) { insets, portrait in
            MonitorSettingsPage(
                safeArea: insets,
                brand: "OpenZCine",
                selection: Binding(get: { selectedTab }, set: { selectedTab = $0 }),
                isLive: isConnected,
                phaseLabel: isConnected
                    ? "\(model.cameraState.cameraName) · \(transportLabel)"
                    : model.linkHealthDetail,
                sharingSubtitle: "Broadcast this feed and manage its watchers.",
                sharingRail: "Broadcast & watchers",
                scrollOffsets: Binding(
                    get: { model.operatorSettingsScrollOffsets },
                    set: { model.operatorSettingsScrollOffsets = $0 }),
                feedback: settingsFeedback,
                onClose: { model.dismissMediaLibrary() },
                disconnect: { model.disconnect() }
            ) { _ in
                settingsRows(portrait: portrait)
            }
        }
        .observeMonitorWindowGeometry()
        .sheet(item: $diagnosticsShareItem) { item in
            DiagnosticsShareSheet(url: item.url)
        }
        .sheet(isPresented: $standaloneBugReportPresented) { ProblemReportView() }
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

    private func settingsFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<OperatorPreferences, Bool>)
        -> Binding<Bool>
    {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { model.preferences[keyPath: keyPath] = $0 }
        )
    }

    @ViewBuilder private var sharingRows: some View {
        if model.videoSource == .relay {
            // A watcher rebroadcasting would daisy-chain feeds: a second generation of
            // encode, a second hop of latency, and a control-token tangle. Sharing is done
            // from the device that holds the camera.
            MonitorSettingsRowCard {
                MonitorSettingsInlineRow(
                    title: "Watching",
                    help:
                        "This device is watching another device's broadcast. Sharing is done from the broadcasting device — re-sharing a received feed would stack a second encode and a second hop of delay on everyone downstream.",
                    showTopDivider: false
                ) {
                    MonitorSettingsValueText(value: model.cameraState.cameraName)
                }
            }
        } else {
            sharingBroadcasterRows
        }
    }

    @ViewBuilder private var sharingBroadcasterRows: some View {
        MonitorFeedSharingSettings(
            sharing: Binding(
                get: { model.isRelayBroadcasting }, set: { model.setRelayBroadcasting($0) }),
            passcode: Binding(
                get: { relayPasscodeDraft ?? model.preferences.relayWatcherPasscode },
                set: { relayPasscodeDraft = String($0.filter(\.isNumber).prefix(4)) }),
            controlRequests: Binding(
                get: { model.preferences.relayAllowsControlRequests },
                set: { model.setRelayAllowsControlRequests($0) }),
            priority: Binding(
                get: { model.preferences.relayEncoderProfile.title },
                set: { title in
                    guard
                        let profile = RelayEncoderProfile.allCases.first(where: {
                            $0.title == title
                        })
                    else { return }
                    model.setRelayEncoderProfile(profile)
                }),
            priorities: RelayEncoderProfile.allCases.map(\.title),
            help: MonitorFeedSharingHelp(
                sharing:
                    "Serves this device's picture and the camera's readings to other devices running OpenZCine. The camera itself only ever talks to one device; this is how a second screen exists at all. Works on a shared network and directly device-to-device. Watchers should NOT join the camera's own Wi-Fi: its access point drops the monitor when a second device joins; they stay on their own network (or none) and find this broadcast in the camera list.",
                passcode:
                    "Four digits watchers must enter once per device before they receive anything: no picture, no readings without it. Leave empty for an open broadcast. Devices already watching keep their access until they leave.",
                controlRequests:
                    "Whether watchers may ask to drive the camera at all. Off hides the ask on their side; granting, declining and taking back stay here either way.",
                priority:
                    "Low latency is the tightest glass-to-glass path, the stance for pulling focus. Quality trades about four frames (~130 ms) for a steadier, better-looking stream: longer keyframe spacing spends the bitrate where it shows, and a deeper per-watcher window rides out network jitter instead of dropping. Changing it mid-broadcast briefly restarts the stream; watchers rejoin on their own."
            ),
            // Watchers never join a Nikon access point (it drops the monitor), so no Wi-Fi code row.
            showWiFiCode: nil,
            passcodeChanged: { code in
                if code.count == 4 || code.isEmpty { model.setRelayWatcherPasscode(code) }
            },
            feedback: settingsFeedback)
        if model.isRelayBroadcasting {
            MonitorSettingsRowCard(title: "Watchers") {
                MonitorSettingsInlineRow(
                    title: "Watching",
                    help:
                        "Devices currently receiving this feed. They see the picture and every view-assist tool, and cannot change anything on the camera unless handed control.",
                    showTopDivider: false
                ) {
                    MonitorSettingsValueText(
                        value: model.relayPeerCount == 1
                            ? "1 device" : "\(model.relayPeerCount) devices")
                }
                if let requester = model.relayPendingControlRequest {
                    MonitorSettingsInlineRow(
                        title: "Control Requested",
                        help:
                            "A device watching this feed is asking to drive the camera. Granting it does not move the camera link: this device keeps that and runs the other one's commands on its behalf, so you can take control back instantly."
                    ) {
                        HStack(spacing: 8) {
                            MonitorSettingsActionPill(title: "Decline") {
                                model.declineRelayControl()
                            }
                            MonitorSettingsActionPill(title: "Grant to \(requester)") {
                                model.grantRelayControl()
                            }
                        }
                    }
                }
                if let holder = model.relayControlHeldBy {
                    MonitorSettingsInlineRow(
                        title: "Camera Control",
                        help:
                            "Take the camera back. This device holds the link, so it never has to ask."
                    ) {
                        HStack(spacing: 8) {
                            MonitorSettingsValueText(value: holder)
                            MonitorSettingsActionPill(title: "Take back") {
                                model.reclaimRelayControl()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Picture sources this device can actually offer: the operator-selectable ones, minus HDMI
    /// where there is no UVC hardware to carry it.
    private var selectableVideoSources: [VideoSourceKind] {
        VideoSourceKind.operatorSelectableCases.filter {
            $0 != .hdmiCapture || UVCVideoSource.isSupportedHardware
        }
    }

    @ViewBuilder private var linkRows: some View {
        MonitorLinkHealthScale(
            title: "Link Health",
            caption: linkHealthCaption,
            score: model.linkHealth)

        MonitorConnectionSettings(
            transport: transportLabel,
            transportHelp:
                "Transport is selected on the connection screen; USB-C and Wi-Fi are exclusive for the current session.",
            phase: model.connection.label,
            phaseHelp: "The current connection state reported by this device."
        )
        if (selectableVideoSources.count > 1 && model.monitorAvailability.offersSourceSwitch)
            || model.videoSource == .hdmiCapture || model.videoSource == .relay
        {
            MonitorSettingsRowCard(title: "Picture Source") {
                // Gated on the count, not on "is this an iPad". HDMI capture needs UVC, which iOS
                // exposes only on iPad, so on a phone the list collapses to one entry — and a picker
                // offering a single choice is a readout pretending to be a control. Stating the rule
                // this way also means any future source that narrows the list hides it too.
                if selectableVideoSources.count > 1, model.monitorAvailability.offersSourceSwitch {
                    MonitorSettingsInlineRow(
                        title: "Picture Source",
                        help:
                            "Where the monitor's image comes from. HDMI shows the camera's clean output through a USB capture device — full rate, no live-view compression — while exposure, focus, record and the media browser keep working over the camera link. The AF boxes, the camera's audio meter and its timecode travel inside the live-view stream, so they leave with it."
                    ) {
                        NikonSettingsChoices(
                            options: selectableVideoSources.map(\.title),
                            selected: model.videoSource.title
                        ) { value in
                            guard
                                let kind = selectableVideoSources.first(where: { $0.title == value }
                                )
                            else { return }
                            model.selectVideoSource(kind)
                        }
                    }
                }
                if model.videoSource == .hdmiCapture {
                    MonitorSettingsInlineRow(
                        title: "Capture Device",
                        help:
                            "The attached USB capture device, the format it is sending, and what the signal claims to be (primaries/transfer/matrix). If the picture shows the device's own \"No Signal\" card while this still reads a healthy rate, the camera's HDMI output resolution is one the device cannot lock onto — 4K is the usual culprit, and 1080p is the safe choice. Set the camera to a clean output too, or its overlays arrive as part of the picture. And if the image looks flat or green-tinted next to the camera's own live view, the camera is sending its recording gamma (N-Log/HLG) over HDMI — apply your monitoring LUT, or set the camera's HDMI output to SDR."
                    ) {
                        MonitorSettingsValueText(value: model.hdmiCaptureState.shortStatus)
                    }
                }
                if model.videoSource == .relay {
                    // The ask/give-back moved onto the live view itself (bottom centre) — control
                    // is exercised while watching, not inside a settings sheet. The readout stays.
                    MonitorSettingsInlineRow(
                        title: "Held By",
                        help: "Which device the camera is currently taking commands from."
                    ) {
                        MonitorSettingsValueText(
                            value: model.relayHoldsControl
                                ? "This device"
                                : (model.relayControlHolderName ?? "The broadcaster"))
                    }
                }
            }
        }

        // The tab was one undifferentiated stack of rows. Three cards instead, because they answer
        // three different questions: what the link IS, what the camera SENDS, and what this device
        // DOES with it on the way to the panel.
        MonitorSettingsRowCard(title: "Picture") {
            MonitorSettingsInlineRow(
                title: "Stream Preset",
                help:
                    "Combines Nikon live-view stream size and compression grade into three operator-facing choices.",
                showTopDivider: false
            ) {
                NikonSettingsChoices(
                    options: LiveViewStreamPreset.allCases.map(\.rawValue),
                    selected: model.preferences.streamPreset.rawValue
                ) { value in
                    if let preset = LiveViewStreamPreset(rawValue: value) {
                        model.setStreamPreset(preset)
                    }
                }
            }
            MonitorSettingsInlineRow(
                title: "Quality Bias",
                help:
                    "Steers the selected stream preset toward smaller frames or more image detail."
            ) {
                // All three grades the body actually offers. The pair this used to show could not
                // name the middle one, so a stored `.balanced` displayed as "Size" — the same label
                // Android wrote as `.latency`, i.e. one label meaning two different bytes across
                // the two shells.
                NikonSettingsChoices(
                    options: LiveViewQualityBias.allCases.map(\.settingsLabel),
                    selected: model.preferences.qualityBias.settingsLabel
                ) { value in
                    guard
                        let bias = LiveViewQualityBias.allCases.first(where: {
                            $0.settingsLabel == value
                        })
                    else { return }
                    model.setQualityBias(bias)
                }
            }
        }

        // What this device does to the picture after the camera has sent it. Separate from
        // "Picture" above, which is what the camera is asked to send in the first place.
        MonitorSettingsRowCard(title: "Processing") {
            // Only what this device can actually run is listed, and the row disappears entirely
            // when that is just the floor — an option that quietly does nothing is worse than no
            // option at all.
            if MonitorUpscaler.supportedOnThisDevice.count > 1 {
                MonitorSettingsInlineRow(
                    title: "Feed Upscaler",
                    help:
                        "How the live-view frame is enlarged to fill the panel. The camera sends far fewer pixels than the panel has, so something always does this. Off is a plain sample, Fast is a fixed sharpening kernel, and Quality is the OS spatial upscaler.\n\nAI is different in kind: it is a machine-learning model that INFERS detail the camera never captured. It gives the sharpest-looking picture, but the fine texture it adds is invented — plausible rather than real — so it can suggest crispness the lens did not record. Judge critical focus on Quality or Fast, and treat AI as a viewing aid rather than evidence.\n\nOnly the options this device supports are shown.",
                    showTopDivider: false
                ) {
                    NikonSettingsChoices(
                        options: MonitorUpscaler.supportedOnThisDevice.map(\.rawValue),
                        selected: FeedUpscaleSwitch.shared.upscaler.rawValue,
                        compact: true
                    ) { value in
                        guard let choice = MonitorUpscaler(rawValue: value) else { return }
                        FeedUpscaleSwitch.shared.upscaler = choice
                    }
                }
            }
            if LiveDenoiseSwitch.isSupportedOnThisDevice,
                let reason = LiveDenoiseSwitch.decoderReportsUnavailable
            {
                // The filter gave up mid-session. Say so where the switch was, rather than leaving
                // a toggle sitting armed over something that has stopped running.
                MonitorSettingsInlineRow(
                    title: "Feed Noise Reduction",
                    help:
                        "The noise filter turned itself off after the camera sent something it could not take. Reconnecting the camera gives it another go.",
                    showTopDivider: MonitorUpscaler.supportedOnThisDevice.count > 1
                ) {
                    MonitorSettingsValueText(value: reason)
                }
            } else if LiveDenoiseSwitch.isSupportedOnThisDevice {
                NikonSettingsSwitch(
                    title: "Feed Noise Reduction",
                    help:
                        "Averages the live view against the frames either side of it to reduce sensor noise, which is worth having on a dim high-ISO set. It only removes grain that CHANGES between frames — the blocky structure of a compressed stream stays put — and it holds two frames back to see ahead, so the picture lags the camera slightly. The recording is never affected.",
                    showTopDivider: MonitorUpscaler.supportedOnThisDevice.count > 1,
                    isOn: LiveDenoiseSwitch.shared.enabled
                ) {
                    LiveDenoiseSwitch.shared.enabled.toggle()
                }
            }
            #if DEBUG
                MonitorSettingsInlineRow(
                    title: "Capture Frames",
                    help:
                        "Debug: saves raw live-view frames to the app container, one a second, for the focus-peaking test corpus. Start it, dismiss this panel, then rack focus slowly end to end."
                ) {
                    LiveViewCaptureControl()
                }
            #endif
        }
    }

    @ViewBuilder private var controlsRows: some View {
        MonitorOperatorSafetySettings(
            recordConfirmation: preferenceBinding(\.recordConfirmationEnabled),
            haptics: preferenceBinding(\.hapticsEnabled),
            keepScreenAwake: preferenceBinding(\.keepScreenAwake),
            hapticsHelp: "Short confirmation pulses for critical switches and setting changes.",
            keepScreenAwakeHelp:
                "Prevents auto-lock while the live monitor or clip playback is active. Exposure assists increase GPU load. Disable tools you are not using. iOS may still dim when the device overheats.",
            feedback: settingsFeedback
        )
        MonitorInputOrientationSettings(
            remoteShutter: preferenceBinding(\.bluetoothShutterEnabled),
            remoteTitle: "Bluetooth Remote Shutter",
            remoteHelp:
                "A paired Bluetooth shutter remote's button press starts or stops recording while the live view is up front. Inside Settings, Media, or other full-screen pages the volume keys behave normally. The phone's volume keys record too, and Record Confirmation is skipped. Presses arrive as volume commands, so the volume may move momentarily before snapping back; the system volume overlay stays hidden while armed.",
            autoRotateFeed: preferenceBinding(\.autoRotateFeedEnabled),
            rotationHelp:
                "Turns the monitoring image upright when the camera is held on its side or upside down. Off keeps the picture in the camera's native orientation. Display only. The recording is never affected.",
            feedback: settingsFeedback
        )
    }

    /// Supplies stored Nikon layouts and admitted actions to the common Display section.
    @ViewBuilder private var displayRows: some View {
        let capture = editedCaptureMode
        MonitorDisplaySettings(
            layoutHelp:
                "Video and photo keep their own monitor layouts. This picks which one the DISP sections set up; the camera's own mode dial picks which one the monitor renders.",
            choices: CaptureLayoutMode.allCases.map {
                MonitorDisplayChoice(id: $0.rawValue, title: $0.title)
            },
            selection: Binding(
                get: { editedCaptureMode.rawValue },
                set: {
                    guard let choice = CaptureLayoutMode(rawValue: $0) else { return }
                    settingsFeedback()
                    editedCaptureMode = choice
                }),
            expandedSection: Binding(
                get: { expandedDispSection?.rawValue },
                set: { expandedDispSection = $0.flatMap(DispMode.init(rawValue:)) }),
            sections: DispMode.allCases.map { mode in
                let eligible = mode != .command && capture == model.captureLayoutMode
                return MonitorDisplaySection(
                    id: mode.rawValue, title: "DISP \(dispNumber(mode)) · \(mode.title)",
                    caption: dispCaption(mode),
                    reset: {
                        settingsFeedback()
                        model.resetChromeVisibility(for: mode, capture: capture)
                    },
                    editHint: "Opens the monitor with an eye on each element you can show or hide",
                    edit: eligible ? { model.beginChromeEditing(mode) } : nil,
                    unavailableEditHelp: mode == .command
                        ? nil
                        : "Switch the camera to \(capture.title.lowercased()) to arrange this on the monitor.",
                    visibility: chromeToggles(for: mode, capture: capture),
                    pinsTitle: "View assists that stay on in clean view",
                    pins: mode == .clean ? cleanPins : []
                )
            },
            order: displayOrder
        )
        .onAppear {
            guard let returning = model.chromeEditorReturnMode else { return }
            expandedDispSection = returning
            model.chromeEditorReturnMode = nil
        }
    }

    private var editedCaptureMode: CaptureLayoutMode {
        get { displayCaptureMode ?? model.captureLayoutMode }
        nonmutating set { displayCaptureMode = newValue }
    }

    private var cleanPins: [MonitorDisplayToggle] {
        MonitorAssistTool.activeCases.filter { $0 != .evMeter }.map { tool in
            MonitorDisplayToggle(
                id: tool.rawValue, title: tool.displaySettingsTitle,
                isOn: model.assist.cleanViewPinnedTools.contains(tool.selection),
                accessibilityLabel: "Keep \(tool.displaySettingsTitle) in clean view"
            ) {
                model.toggleCleanViewPin(tool)
            }
        }
    }

    private var displayOrder: MonitorDisplayOrderGroup {
        MonitorDisplayOrderGroup(
            title: "DISP Button Order",
            caption: "Drag to reorder; tap to enable or disable modes.",
            items: model.preferences.dispOrder.map { mode in
                MonitorDisplayOrderItem(
                    id: mode.rawValue, title: mode.title,
                    isOn: model.preferences.enabledDispModes.contains(mode),
                    highlighted: mode == model.displayMode
                        && model.preferences.enabledDispModes.contains(mode),
                    toggle: { model.toggleDispMode(mode) })
            },
            reset: {
                settingsFeedback()
                model.resetDispPreferences()
            },
            move: { id, target in
                let current = model.preferences.dispOrder
                guard let source = current.firstIndex(where: { $0.rawValue == id }),
                    current.indices.contains(target), source != target
                else { return }
                model.moveDispOrder(
                    from: IndexSet(integer: source), to: source < target ? target + 1 : target)
            })
    }

    private func dispNumber(_ mode: DispMode) -> Int {
        (DispMode.allCases.firstIndex(of: mode) ?? 0) + 1
    }

    private func dispCaption(_ mode: DispMode) -> String {
        switch mode {
        case .live:
            "The full monitor. Set what it shows in Edit view, and which tools reach the tool bar."
        case .clean:
            "A stripped-back image. Same elements as DISP 1 — the rail, focus box and batteries start on, everything else off."
        case .command:
            "The data dashboard — no feed, so no image assists. Only the side rail is on screen."
        }
    }

    private func chromeToggles(for mode: DispMode, capture: CaptureLayoutMode)
        -> [MonitorDisplayToggle]
    {
        DisplayChromeVisibility.configurableSections(in: mode).map { section in
            MonitorDisplayToggle(
                id: section.rawValue, title: section.title,
                isOn: model.preferences.chrome(for: mode, capture: capture).isVisible(section)
            ) {
                model.toggleChrome(section, for: mode, capture: capture)
            }
        }
    }

    /// Marketing version + build number from the bundle, e.g. "0.2.0 (9)", matching what
    /// TestFlight shows for the installed build (CI stamps CFBundleVersion per upload).
    static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static let reliabilityReportsHelp =
        "Optional: send crash and error reports to OpenCapture through Sentry. Off by default. Turn off anytime without losing app features. Uploads wait until you leave camera Wi-Fi. No footage or GPS location. Sentry receives the connection IP; stored event IP and derived geography are removed. See Reporting Privacy below."
    static let reliabilityUnavailableHelp =
        "This build cannot send automatic reports. You can still share diagnostics stored on this phone."

    @ViewBuilder private var systemRows: some View {
        MonitorSupportSettings(
            automaticReports: Binding(
                get: { reliabilityOptIn },
                set: {
                    reliabilityOptIn = $0
                    ReliabilityDiagnostics.reporting.setConsent($0)
                }),
            available: ReliabilityDiagnostics.reporting.isAvailable,
            automaticHelp: Self.reliabilityReportsHelp,
            unavailableHelp: Self.reliabilityUnavailableHelp,
            reportTitle: "Report a Problem",
            reportActionTitle: "Report",
            actions: [
                MonitorSupportAction(
                    id: "support.open", title: "Support",
                    help:
                        "Connection guides, camera controls, media workflows, and troubleshooting.",
                    actionTitle: "Open", accessibilityLabel: "Open Support"
                ) {
                    requestInternetDestination(.support)
                },
                MonitorSupportAction(
                    id: "support.feature", title: "Request a Feature",
                    help: "Start an idea in the project’s feature-request discussion category.",
                    actionTitle: "Request", accessibilityLabel: "Request a Feature"
                ) {
                    requestInternetDestination(.featureRequest)
                },
                MonitorSupportAction(
                    id: "support.diagnostics", title: "Share Diagnostics",
                    help:
                        "Create a local report with recent app events and Apple diagnostics. Review it before sharing.",
                    actionTitle: isPreparingDiagnostics ? "Preparing…" : "Share",
                    accessibilityLabel: "Share Diagnostics", enabled: !isPreparingDiagnostics
                ) {
                    prepareDiagnosticsReport()
                },
                MonitorSupportAction(
                    id: "support.guide", title: "Live View Guide",
                    help:
                        "Show the short control guide now when live view is open, or again on the next live view.",
                    actionTitle: "Show Again", accessibilityLabel: "Show Live View Guide Again"
                ) {
                    model.replayLiveViewGuide()
                },
            ],
            report: { presentBugReport() },
            privacy: { requestInternetDestination(.privacyPolicy) }
        )

        MonitorProjectLegalSettings(
            sourceHelp: "View the OpenZCine project and contribute on GitHub.",
            termsHelp: "Read the OpenZCine terms of use.",
            source: { requestInternetDestination(.sourceCode) },
            privacy: { requestInternetDestination(.privacyPolicy) },
            terms: { requestInternetDestination(.termsOfUse) }
        )
        MonitorAppInformationSettings(
            theme: "Warm Dark", protocolName: "PTP / PTP-IP", version: Self.appVersionText,
            themeHelp: "Dark earth interface tuned for low reflection on set.",
            protocolHelp:
                "Camera control speaks standard PTP over USB and PTP-IP over Wi-Fi; no vendor SDK is bundled or required.",
            versionHelp: "Current OpenZCine build from the native project metadata."
        )
    }

    private func presentBugReport() {
        if model.isStandaloneSettingsPresented {
            model.isBugReportPresented = false
            standaloneBugReportPresented = true
        } else {
            model.isBugReportPresented = true
        }
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
            guard await model.prepareExternalInternetLinkHandoff() else {
                externalLinkErrorMessage =
                    "OpenZCine couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
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
        MonitorAccountSettings(
            title: "Frame.io",
            help:
                "Sign in once here and the share sheet's Frame.io option unlocks everywhere. On the camera's Wi‑Fi, signing in hops to home Wi‑Fi or cellular, signs in, then reconnects the camera. Logging out removes the stored sign-in and remembered project.",
            state: frameioAccountState,
            signIn: {
                if model.isOnCameraAccessPoint {
                    showFrameioHopConfirm = true
                } else {
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
                }
            },
            signOut: {
                model.disconnectFrameio()
                frameioAccountStamp += 1
            }
        )
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
        if let frameioSignInError {
            Text(frameioSignInError)
                .font(MonitorTheme.font(11.5))
                .foregroundStyle(MonitorTheme.recording)
                .fixedSize(horizontal: false, vertical: true)
        }

        MonitorCacheSettings(
            sizeLabel: cacheSizeLabel,
            scopeHelp:
                "Clips and thumbnails cached from the camera for offline playback and sharing, across all paired cameras.",
            clearHelp:
                "Removes cached clip files, thumbnails, and camera indexes for every camera. The on-device library is left intact. Connected, the gallery reloads from the camera; favorites of remote-only shots are rebuilt only if those shots are still on the card."
        ) {
            model.clearAllMediaCaches()
            cacheSizeBytes = model.totalMediaCacheByteCount()
        }
        .onAppear { cacheSizeBytes = model.totalMediaCacheByteCount() }
    }

    private var frameioAccountState: MonitorAccountState {
        if model.isFrameioConnected { return .signedIn }
        if !model.isFrameioConfigured { return .notConfigured }
        return frameioSigningIn ? .connecting : .signedOut
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
        case .sharing:
            sharingRows
        case .assist:
            NikonViewAssistSettings()
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

}

struct NikonViewAssistSettings: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        let menus = NikonAssistMenuAdapter(model: model, compact: true)
        MonitorViewAssistSettings(sections: [
            .falseColor(
                menus.falseColor,
                reset: {
                    resetFeedback()
                    resetFalseColor()
                }),
            .zebra(
                menus.zebra,
                reset: {
                    resetFeedback()
                    resetZebra()
                }),
            .waveform(
                menus.waveform,
                reset: {
                    resetFeedback()
                    resetWaveform()
                }),
            .parade(
                menus.parade,
                reset: {
                    resetFeedback()
                    resetParade()
                }),
            .histogram(
                menus.histogram,
                reset: {
                    resetFeedback()
                    resetHistogram()
                }),
            .vectorscope(
                menus.vectorscope,
                reset: {
                    resetFeedback()
                    resetVectorscope()
                }),
            .peaking(
                menus.peaking,
                reset: {
                    resetFeedback()
                    resetPeaking()
                }),
            .trafficLights(
                menus.trafficLights,
                reset: {
                    resetFeedback()
                    resetTrafficLights()
                }),
        ])
    }

    private func resetFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }

    private func resetFalseColor() {
        model.assist.resetOptions(.falseColor)
    }

    private func resetZebra() {
        model.assist.resetOptions(.zebra)
        model.assistConfiguration.zebra = AssistConfiguration.defaults.zebra
    }

    private func resetWaveform() {
        let store = model.scopePanels.waveform
        let base = MonitorWaveformOptions.default
        store.options.mode = base.mode
        store.options.guides = base.guides
        store.options.brightness = base.brightness
    }

    private func resetParade() {
        let store = model.scopePanels.parade
        let base = MonitorParadeOptions.default
        store.options.mode = base.mode
        store.options.guides = base.guides
        store.options.brightness = base.brightness
    }

    private func resetHistogram() {
        model.scopePanels.histogram.options.trafficLights =
            MonitorHistogramOptions.default.trafficLights
        model.assist.resetOptions(.histogram)
    }

    private func resetTrafficLights() {
        model.scopePanels.trafficLights.setScale(1)
        model.assist.resetOptions(.trafficLights)
    }

    private func resetPeaking() {
        model.assist.resetOptions(.peaking)
    }

    private func resetVectorscope() {
        let store = model.scopePanels.vectorscope
        let base = MonitorVectorscopeOptions.default
        store.options.zoom = base.zoom
        store.options.brightness = base.brightness
    }
}

/// The "Focus dial": a thin vertical drum on the live view beside the right system rail, shown
/// while an AF focus mode is active on a focus-by-wire lens. Drag up toward ∞, down toward NEAR;
/// the drum's ticks scroll with the drive so it reads like a physical focus ring, and — once a
/// full near↔∞ sweep calibrates the travel — a relative position (0 = near, 100 = ∞) is shown
/// (the camera exposes no absolute distance for AF lenses). Travel ends light their label with a
/// haptic. [verify-on-HW: pulses-per-point feel per lens]
struct MFDriveVerticalScrub: View {
    @Environment(NativeAppModel.self) private var model
    @State private var lastDragY: CGFloat?
    @State private var isDragging = false

    /// Drag-to-pulse gain at the slow end of the ramp.
    ///
    /// Was 4, which a real video pull found too coarse to trim focus with: at 4, and with the
    /// speed ramp reaching ×3 after only a 12pt/frame move, a careful nudge already moved the lens
    /// further than the operator wanted. 2 makes a slow drag genuinely fine and keeps the flick
    /// useful — see `speedRampDivisor`.
    ///
    /// ponytail: this is a calibration knob, not a derived constant. It is tuned against how a
    /// focus-by-wire lens actually travels, which no test can tell us — raise it if a full sweep
    /// cannot cross the range on a real body, lower it if trimming still overshoots.
    private static let pulsesPerPoint = 2
    /// Points of per-frame travel that buy one extra multiple of gain, up to `maxSpeedFactor`.
    /// Larger divisor = the ramp needs a more deliberate flick, so slow drags stay in the fine band.
    private static let speedRampDivisor: CGFloat = 14
    private static let maxSpeedFactor: CGFloat = 4
    /// Drum geometry: one tick every `pulsesPerTick` pulses, `tickSpacing` points apart.
    private static let tickSpacing: CGFloat = 11
    private static let pulsesPerTick: CGFloat = 220

    /// Pulses for one drag frame. Extracted so the gain curve is unit-testable — the sensitivity
    /// is the whole point of this control and a real pull found the old curve too coarse.
    static func pulses(forDelta delta: CGFloat) -> Int {
        let speedFactor = min(1 + abs(delta) / speedRampDivisor, maxSpeedFactor)
        return Int(delta * CGFloat(pulsesPerPoint) * speedFactor)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text("∞")
                .foregroundStyle(model.mfDriveAtEnd == 1 ? LiveDesign.accent : LiveDesign.muted)
            drum
                .frame(width: 30)
                .frame(maxHeight: .infinity)
            Text("NEAR")
                .foregroundStyle(model.mfDriveAtEnd == -1 ? LiveDesign.accent : LiveDesign.muted)
            if let fraction = model.mfDriveDialFraction {
                Text("\(Int((fraction * 100).rounded()))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text)
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .liquidGlass(in: Capsule())
        // AF-F re-focuses continuously, so a pull is overridden as fast as it lands. Drawn dimmed
        // and inert rather than hidden: the dial disappearing when the operator changes focus mode
        // reads as a bug, while a greyed one says "wrong mode for this", which is the truth.
        .opacity(model.mfDriveScrubIsInert ? 0.55 : 1)  // matches the Android strip
        .allowsHitTesting(!model.mfDriveScrubIsInert)
        .accessibilityHint(
            model.mfDriveScrubIsInert
                ? "Unavailable in AF-F. The camera refocuses continuously in this mode." : ""
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    isDragging = true
                    let delta = (lastDragY ?? value.startLocation.y) - value.location.y
                    lastDragY = value.location.y
                    // Upward drag drives toward infinity. Ring-like speed response: a slow drag
                    // steps finely, a deliberate flick multiplies travel.
                    model.driveManualFocus(
                        pulses: Self.pulses(forDelta: delta))
                }
                .onEnded { _ in
                    lastDragY = nil
                    isDragging = false
                }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: model.mfDriveAtEnd) { _, end in
            end != nil
        }
        // Re-arm the relative position each time the dial appears (new lens/mode/session).
        .onAppear { model.resetMFDriveDial() }
    }

    /// The scrolling tick drum with a fixed centre reference line marking the current position.
    private var drum: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(isDragging ? 0.14 : 0.06))
                    .overlay(
                        Capsule().strokeBorder(
                            isDragging ? LiveDesign.accent.opacity(0.7) : LiveDesign.hairline,
                            lineWidth: 1))
                Canvas { ctx, canvas in
                    let mid = canvas.height / 2
                    let current = CGFloat(model.mfDriveNetPulses) / Self.pulsesPerTick
                    let span = Int(mid / Self.tickSpacing) + 2
                    let base = Int(current.rounded())
                    for offset in -span...span {
                        let index = base + offset
                        let y = mid - (CGFloat(index) - current) * Self.tickSpacing
                        guard y >= 0, y <= canvas.height else { continue }
                        let major = index % 5 == 0
                        let w = (major ? 0.72 : 0.4) * canvas.width
                        let rect = CGRect(
                            x: (canvas.width - w) / 2, y: y, width: w, height: major ? 1.5 : 1)
                        ctx.fill(
                            Path(rect),
                            with: .color(.white.opacity(major ? 0.5 : 0.28)))
                    }
                }
                // Fixed centre line = the current focus position.
                Rectangle()
                    .fill(LiveDesign.accent.opacity(0.95))
                    .frame(width: isDragging ? 26 : 20, height: 2)
                    .position(x: size.width / 2, y: size.height / 2)
            }
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
    }
}

#if DEBUG
    /// Debug trigger for the focus-peaking frame corpus.
    ///
    /// Polls `DemoHarness` rather than being pushed to, so the capture path stays lock-only and
    /// never hops to the main actor once a second while the stream is running. Polling only ticks
    /// while this row is on screen.
    private struct LiveViewCaptureControl: View {
        @State private var status: String?

        var body: some View {
            HStack(spacing: 10) {
                if let status {
                    Text(status)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiveDesign.muted)
                        .lineLimit(1)
                }
                MonitorSettingsActionPill(title: status == nil ? "Start" : "Restart") {
                    DemoHarness.startLiveViewCapture()
                    status = DemoHarness.liveViewCaptureStatus()
                }
            }
            .task {
                while !Task.isCancelled {
                    status = DemoHarness.liveViewCaptureStatus()
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
    }
#endif
