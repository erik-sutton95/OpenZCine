import CoreMotion
import MonitorPresentation
import MonitorUI
import OpenCineMedia
import SwiftUI
import OpenZCineCore

struct FeedAssistOverlayModule: View {
    @Environment(NativeAppModel.self) private var model
    let safeArea: MonitorEdgeInsets
    let viewportWidth: Double
    let canvasOffsetX: Double
    var horizontalDirection: MonitorHorizontalLayoutDirection = .standard
    /// Suppresses the floating scope/false-colour `MovablePanel`s. Set by `MonitorShell`'s
    /// portrait branch: those panels bleed over the narrow portrait feed strip and are redundant
    /// there — `PortraitScopesStack` already shows scopes. Landscape never passes this.
    var suppressFloatingScopes: Bool = false

    var body: some View {
        // Photography filters the cinema-only panels (a flipped-over video scope must not
        // ride into the photo chrome); the persisted set itself is untouched.
        let visible = model.renderedLiveAssistTools
        GeometryReader { proxy in
            let feedFrame = MonitorFeedLayout.fullBleedFrame(
                viewportWidth: viewportWidth,
                viewportHeight: Double(proxy.size.height),
                safeArea: safeArea,
                horizontalDirection: horizontalDirection
            )
            let feedRect = CGRect(
                x: CGFloat(feedFrame.x),
                y: CGFloat(feedFrame.y),
                width: CGFloat(feedFrame.width),
                height: CGFloat(feedFrame.height)
            )
            let screenBounds = CGRect(
                x: 0, y: 0, width: CGFloat(viewportWidth), height: proxy.size.height)
            // Bands the inside-fallback anchors must clear: the status pill on top, the floating
            // assist/capture strips on the bottom (reserved in every mode — see
            // `landscapeBottomBarHeight` in MonitorUnified.swift).
            let chromeClearance = EdgeInsets(
                top: CGFloat(
                    MonitorChromeLayout.insets(feedSafeArea: safeArea).clearingWindowControls.top
                        + MonitorLiveViewModuleLayout.topInfoDeckHeight),
                leading: 0,
                bottom: CGFloat(MonitorLiveViewModuleLayout.bottomBarBottomInset)
                    + LiveDesign.controlHeight,
                trailing: 0)
            ZStack(alignment: .topLeading) {
                // Guides/grid/crosshair/level draw on the feed image itself (`FeedAlignedAssists`);
                // the scopes and false-colour reference float here, each draggable via
                // `MovablePanel` — skipped in portrait (see `suppressFloatingScopes`).
                if !suppressFloatingScopes {
                    let scopes = model.assistConfiguration.scopes
                    if visible.contains(.waveform) {
                        LiveWaveformScopePanel(
                            feedRect: feedRect,
                            screenBounds: screenBounds,
                            chromeClearance: chromeClearance,
                            scopes: scopes)
                    }
                    if visible.contains(.parade) {
                        LiveParadeScopePanel(
                            feedRect: feedRect,
                            screenBounds: screenBounds,
                            chromeClearance: chromeClearance,
                            scopes: scopes)
                    }
                    if visible.contains(.vectorscope) {
                        LiveVectorscopePanel(
                            feedRect: feedRect,
                            screenBounds: screenBounds,
                            chromeClearance: chromeClearance,
                            scopes: scopes)
                    }
                    if visible.contains(.histogram) {
                        let base = CGSize(width: 250, height: 77)
                        let size = scopeSize(base, scopes.histogramScale)
                        MovablePanel(
                            id: "histo", size: size,
                            defaultCenter: feedOutsideCenter(
                                feedRect, size, .bottomTrailing,
                                bounds: screenBounds, chromeClearance: chromeClearance),
                            bounds: screenBounds,
                            resize: .init(
                                scale: scopes.histogramScale,
                                range: AssistConfiguration.Scopes.scaleRange,
                                baseSize: base,
                                onChange: { model.assistConfiguration.scopes.histogramScale = $0 })
                        ) {
                            ScopeMini(
                                title: "Histo", systemImage: "chart.xyaxis.line", style: .histogram,
                                assist: model.scopeAssist, scopes: scopes,
                                mapping: model.exposureSignalMapping)
                        }
                    }
                    if visible.contains(.audioMeters) {
                        let size = AudioMetersPanelMini.panelSize
                        MovablePanel(
                            id: "audio", size: size,
                            defaultCenter: feedOutsideCenter(
                                feedRect, size, .bottomTrailing,
                                bounds: screenBounds, chromeClearance: chromeClearance),
                            bounds: screenBounds
                        ) {
                            AudioMetersPanelMini(
                                levels: model.liveAudioLevels,
                                sensitivity: model.commandMicrophoneSensLabel)
                        }
                    }
                    if visible.contains(.trafficLights) {
                        let lights = model.assistConfiguration.trafficLights
                        let base = CGSize(width: 74, height: 168)
                        let size = scopeSize(base, lights.scale)
                        MovablePanel(
                            id: "traffic-lights", size: size,
                            defaultCenter: feedOutsideCenter(
                                feedRect, size, .bottomLeading,
                                bounds: screenBounds, chromeClearance: chromeClearance),
                            bounds: screenBounds,
                            resize: .init(
                                scale: lights.scale,
                                range: AssistConfiguration.Scopes.scaleRange,
                                baseSize: base,
                                onChange: { model.assistConfiguration.trafficLights.scale = $0 })
                        ) {
                            MonitorTrafficLightsMeter(
                                reading: model.scopeAssist.traffic)
                        }
                    }
                    if visible.contains(.falseColor)
                        && model.assistConfiguration.falseColorReferenceEnabled
                    {
                        let size = FalseColorReference.panelSize
                        MovablePanel(
                            id: "fcref", size: size,
                            defaultCenter: feedOutsideCenter(
                                feedRect, size, .bottomLeading,
                                bounds: screenBounds, chromeClearance: chromeClearance),
                            bounds: screenBounds
                        ) {
                            FalseColorReference(
                                scale: model.assistConfiguration.falseColorScale,
                                mapping: model.exposureSignalMapping)
                        }
                    }
                }
            }
            .frame(
                width: CGFloat(viewportWidth),
                height: proxy.size.height,
                alignment: .topLeading
            )
            .offset(x: CGFloat(canvasOffsetX))
        }
    }

    /// A scope's base footprint scaled by its operator-set resize factor.
    private func scopeSize(_ base: CGSize, _ scale: Double) -> CGSize {
        CGSize(
            width: (base.width * scale).rounded(),
            height: (base.height * scale).rounded())
    }
}

/// Waveform scope panel — reads only scope sample / scatter-frame properties, not `liveFrameImage`.
private struct LiveWaveformScopePanel: View {
    @Environment(NativeAppModel.self) private var model
    let feedRect: CGRect
    let screenBounds: CGRect
    let chromeClearance: EdgeInsets
    let scopes: AssistConfiguration.Scopes

    var body: some View {
        let base = CGSize(width: 250, height: 153)
        let size = scopeSize(base, scopes.waveformScale)
        MovablePanel(
            id: "wave", size: size,
            defaultCenter: feedOutsideCenter(
                feedRect, size, .topLeading,
                bounds: screenBounds, chromeClearance: chromeClearance),
            bounds: screenBounds,
            resize: .init(
                scale: scopes.waveformScale,
                range: AssistConfiguration.Scopes.scaleRange,
                baseSize: base,
                onChange: { model.assistConfiguration.scopes.waveformScale = $0 })
        ) {
            // On the GPU-scopes path the scatter view draws from `frame` alone — reading
            // `scopeSamples` here would re-invalidate this panel on every histogram publish.
            ScopeMini(
                title: "Wave", systemImage: "waveform.path.ecg", style: .waveform,
                assist: model.scopeAssist, scopes: scopes,
                mapping: model.exposureSignalMapping)
        }
    }

    private func scopeSize(_ base: CGSize, _ scale: Double) -> CGSize {
        CGSize(
            width: (base.width * scale).rounded(),
            height: (base.height * scale).rounded())
    }
}

/// Parade scope panel — isolated from per-frame feed publishes like the waveform panel.
private struct LiveParadeScopePanel: View {
    @Environment(NativeAppModel.self) private var model
    let feedRect: CGRect
    let screenBounds: CGRect
    let chromeClearance: EdgeInsets
    let scopes: AssistConfiguration.Scopes

    var body: some View {
        let base = CGSize(width: 250, height: 153)
        let size = scopeSize(base, scopes.paradeScale)
        MovablePanel(
            id: "parade", size: size,
            defaultCenter: feedOutsideCenter(
                feedRect, size, .topTrailing,
                bounds: screenBounds, chromeClearance: chromeClearance),
            bounds: screenBounds,
            resize: .init(
                scale: scopes.paradeScale, range: AssistConfiguration.Scopes.scaleRange,
                baseSize: base,
                onChange: { model.assistConfiguration.scopes.paradeScale = $0 })
        ) {
            // Same isolation as the waveform panel: scatter draws from `frame`, not the bins.
            ScopeMini(
                title: "Parade", systemImage: "chart.bar.xaxis", style: .parade,
                assist: model.scopeAssist, scopes: scopes,
                mapping: model.exposureSignalMapping)
        }
    }

    private func scopeSize(_ base: CGSize, _ scale: Double) -> CGSize {
        CGSize(
            width: (base.width * scale).rounded(),
            height: (base.height * scale).rounded())
    }
}

/// Vectorscope panel — isolated from per-frame feed publishes like the waveform/parade panels.
/// Always reads `scopeSamples`: the CbCr bins accumulate from CPU point samples on every render
/// path (there is no GPU scatter equivalent for the chroma plot).
private struct LiveVectorscopePanel: View {
    @Environment(NativeAppModel.self) private var model
    let feedRect: CGRect
    let screenBounds: CGRect
    let chromeClearance: EdgeInsets
    let scopes: AssistConfiguration.Scopes

    var body: some View {
        let base = CGSize(width: 190, height: 190)
        let size = scopeSize(base, scopes.vectorscopeScale)
        MovablePanel(
            id: "vector", size: size,
            defaultCenter: feedOutsideCenter(
                feedRect, size, .topTrailing,
                bounds: screenBounds, chromeClearance: chromeClearance),
            bounds: screenBounds,
            resize: .init(
                scale: scopes.vectorscopeScale,
                range: AssistConfiguration.Scopes.scaleRange,
                baseSize: base,
                onChange: { model.assistConfiguration.scopes.vectorscopeScale = $0 })
        ) {
            ScopeMini(
                title: "Vector", systemImage: "circle.grid.cross", style: .vectorscope,
                assist: model.scopeAssist,
                scopes: scopes,
                mapping: model.exposureSignalMapping)
        }
    }

    private func scopeSize(_ base: CGSize, _ scale: Double) -> CGSize {
        CGSize(
            width: (base.width * scale).rounded(),
            height: (base.height * scale).rounded())
    }
}

/// Default centre for a floating scope panel anchored just outside the video feed edge. When the
/// outside position doesn't fit `bounds` — landscape's full-bleed feed spans the whole screen, so
/// "outside" is off-screen and `MovablePanel`'s clamp would park the panel behind the floating
/// chrome — the anchor mirrors to just inside the feed edge instead, pushed past `chromeClearance`
/// (top status pill band, bottom assist/capture strip band).
private func feedOutsideCenter(
    _ feedRect: CGRect, _ size: CGSize, _ anchor: Alignment,
    bounds: CGRect, chromeClearance: EdgeInsets = EdgeInsets(), gap: CGFloat = 10
) -> CGPoint {
    let halfWidth = size.width / 2
    let halfHeight = size.height / 2
    let x: CGFloat =
        anchor.horizontal == .leading
        ? feedRect.minX + halfWidth
        : (anchor.horizontal == .trailing ? feedRect.maxX - halfWidth : feedRect.midX)
    let y: CGFloat
    switch anchor.vertical {
    case .top:
        let outside = feedRect.minY - gap - halfHeight
        y =
            outside - halfHeight >= bounds.minY
            ? outside
            : max(feedRect.minY, bounds.minY + chromeClearance.top) + gap + halfHeight
    case .bottom:
        let outside = feedRect.maxY + gap + halfHeight
        y =
            outside + halfHeight <= bounds.maxY
            ? outside
            : min(feedRect.maxY, bounds.maxY - chromeClearance.bottom) - gap - halfHeight
    default:
        y = feedRect.midY
    }
    return CGPoint(x: x, y: y)
}

/// Floating scope panels for media playback — same layout as the live monitor but fed from sampled
/// `AVPlayer` frames instead of the live-view loop.
struct PlaybackAssistOverlayModule: View {
    @Environment(NativeAppModel.self) private var model
    let scopeAssist: ScopeAssistBundle
    /// Aspect-fit video rectangle in the overlay coordinate space.
    let videoRect: CGRect
    /// Metered playback audio; absent before a real sample or when the tool is off.
    var audioLevels: AudioMeterLevels?

    var body: some View {
        let visible = model.preferences.playbackVisibleAssistTools
        GeometryReader { proxy in
            let screenBounds = CGRect(origin: .zero, size: proxy.size)
            let feedRect = videoRect
            ZStack(alignment: .topLeading) {
                let scopes = model.assistConfiguration.scopes
                if visible.contains(.waveform) {
                    let base = CGSize(width: 250, height: 153)
                    let size = scopeSize(base, scopes.waveformScale)
                    MovablePanel(
                        id: "playback-wave", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .topLeading, bounds: screenBounds),
                        bounds: screenBounds,
                        resize: .init(
                            scale: scopes.waveformScale,
                            range: AssistConfiguration.Scopes.scaleRange,
                            baseSize: base,
                            onChange: { model.assistConfiguration.scopes.waveformScale = $0 })
                    ) {
                        ScopeMini(
                            title: "Wave", systemImage: "waveform.path.ecg", style: .waveform,
                            assist: scopeAssist, scopes: scopes,
                            mapping: model.playbackExposureSignalMapping)
                    }
                }
                if visible.contains(.parade) {
                    let base = CGSize(width: 250, height: 153)
                    let size = scopeSize(base, scopes.paradeScale)
                    MovablePanel(
                        id: "playback-parade", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .topTrailing, bounds: screenBounds),
                        bounds: screenBounds,
                        resize: .init(
                            scale: scopes.paradeScale, range: AssistConfiguration.Scopes.scaleRange,
                            baseSize: base,
                            onChange: { model.assistConfiguration.scopes.paradeScale = $0 })
                    ) {
                        ScopeMini(
                            title: "Parade", systemImage: "chart.bar.xaxis", style: .parade,
                            assist: scopeAssist, scopes: scopes,
                            mapping: model.playbackExposureSignalMapping)
                    }
                }
                if visible.contains(.vectorscope) {
                    let base = CGSize(width: 190, height: 190)
                    let size = scopeSize(base, scopes.vectorscopeScale)
                    MovablePanel(
                        id: "playback-vector", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .topTrailing, bounds: screenBounds),
                        bounds: screenBounds,
                        resize: .init(
                            scale: scopes.vectorscopeScale,
                            range: AssistConfiguration.Scopes.scaleRange,
                            baseSize: base,
                            onChange: { model.assistConfiguration.scopes.vectorscopeScale = $0 })
                    ) {
                        ScopeMini(
                            title: "Vector", systemImage: "circle.grid.cross", style: .vectorscope,
                            assist: scopeAssist,
                            scopes: scopes,
                            mapping: model.playbackExposureSignalMapping)
                    }
                }
                if visible.contains(.audioMeters) {
                    let size = AudioMetersPanelMini.panelSize
                    MovablePanel(
                        id: "playback-audio", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .bottomTrailing, bounds: screenBounds),
                        bounds: screenBounds
                    ) {
                        AudioMetersPanelMini(levels: audioLevels, sensitivity: nil)
                    }
                }
                if visible.contains(.histogram) {
                    let base = CGSize(width: 250, height: 77)
                    let size = scopeSize(base, scopes.histogramScale)
                    MovablePanel(
                        id: "playback-histo", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .bottomTrailing, bounds: screenBounds),
                        bounds: screenBounds,
                        resize: .init(
                            scale: scopes.histogramScale,
                            range: AssistConfiguration.Scopes.scaleRange,
                            baseSize: base,
                            onChange: { model.assistConfiguration.scopes.histogramScale = $0 })
                    ) {
                        ScopeMini(
                            title: "Histo", systemImage: "chart.xyaxis.line", style: .histogram,
                            assist: scopeAssist, scopes: scopes,
                            mapping: model.playbackExposureSignalMapping)
                    }
                }
                if visible.contains(.trafficLights) {
                    let lights = model.assistConfiguration.trafficLights
                    let base = CGSize(width: 74, height: 168)
                    let size = scopeSize(base, lights.scale)
                    MovablePanel(
                        id: "playback-traffic-lights", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .bottomLeading, bounds: screenBounds),
                        bounds: screenBounds,
                        resize: .init(
                            scale: lights.scale,
                            range: AssistConfiguration.Scopes.scaleRange,
                            baseSize: base,
                            onChange: { model.assistConfiguration.trafficLights.scale = $0 })
                    ) {
                        MonitorTrafficLightsMeter(reading: scopeAssist.traffic)
                    }
                }
                if visible.contains(.falseColor)
                    && model.assistConfiguration.falseColorReferenceEnabled
                {
                    let size = FalseColorReference.panelSize
                    MovablePanel(
                        id: "playback-fcref", size: size,
                        defaultCenter: feedOutsideCenter(
                            feedRect, size, .bottomLeading, bounds: screenBounds),
                        bounds: screenBounds
                    ) {
                        FalseColorReference(
                            scale: model.assistConfiguration.falseColorScale,
                            mapping: model.playbackExposureSignalMapping)
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }

    private func scopeSize(_ base: CGSize, _ scale: Double) -> CGSize {
        CGSize(
            width: (base.width * scale).rounded(),
            height: (base.height * scale).rounded())
    }
}

/// Two-stroke L-corner resize affordance for a bottom-trailing exterior grip. The vertex sits at the
/// rect's bottom-trailing corner (exterior); legs extend left and up back toward the panel corner.
struct CornerResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        let leg = min(rect.width, rect.height)
        let vertex = CGPoint(x: rect.maxX, y: rect.maxY)
        var path = Path()
        path.move(to: vertex)
        path.addLine(to: CGPoint(x: vertex.x - leg, y: vertex.y))
        path.move(to: vertex)
        path.addLine(to: CGPoint(x: vertex.x, y: vertex.y - leg))
        return path
    }
}

/// Long-press-and-drag wrapper for a floating panel (a scope or the false-colour reference). After a
/// brief hold the panel lifts and follows the finger, clamped inside `bounds` and snapped to a coarse
/// grid; a rigid tap fires on pick-up and a light tick on each snap, in keeping with the assist
/// haptics. Positions persist across launches via `model.movablePanelPositions`.
struct MovablePanel<Content: View>: View {
    /// Optional uniform-resize support: a corner handle whose long-press-drag scales the panel. The
    /// panel reads its current `size` from the caller (base × scale); the handle reports a new scale
    /// back through `onChange`, and `baseSize`/`range` drive the drag-to-scale maths and clamp.
    struct Resize {
        var scale: Double
        var range: ClosedRange<Double>
        var baseSize: CGSize
        var onChange: (Double) -> Void
    }

    @Environment(NativeAppModel.self) private var model
    let id: String
    let size: CGSize
    let defaultCenter: CGPoint
    let bounds: CGRect
    var resize: Resize? = nil
    @ViewBuilder var content: () -> Content

    @State private var dragOrigin: CGPoint?
    @State private var isDragging = false
    @State private var snapCell = 0
    @State private var isResizing = false
    @State private var resizeStartScale = 1.0

    // A fine position snap keeps the drag feeling smooth; the haptic ticks on a coarser interval so
    // it doesn't buzz continuously while moving.
    private let positionGrid: CGFloat = 4
    private let hapticGrid: CGFloat = 22
    /// Minimum touch target for the exterior resize grip (HIG + operator margin).
    private let gripHitSize: CGFloat = 56
    /// Visible L-bracket leg length.
    private let gripVisualSize: CGFloat = 14
    /// Invisible padding around the panel body for long-press drag pickup.
    private let dragHitPadding: CGFloat = 10
    /// Clearance from the panel's bottom-trailing corner to the grip vertex.
    private let gripExteriorGap: CGFloat = 2
    /// Pulls the grip toward the panel corner while keeping the vertex outside.
    private var gripCornerInset: CGFloat { gripVisualSize - gripExteriorGap }

    var body: some View {
        let center = clamp(resolvedCenter())
        let gripPad = resize != nil ? gripHitSize - gripCornerInset : 0
        // The panel's live frame in the canvas space, published so other floating chrome (the recenter
        // button) can dodge it.
        let frame = CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height)
        // Expand layout bounds so the exterior grip stays hit-testable; shift `.position` to keep the
        // scope panel itself anchored at `center`.
        ZStack(alignment: .topLeading) {
            content()
                // Anchor the grip to the panel chrome's bottom-trailing corner (intrinsic bounds),
                // not the outer layout frame — fixed-size scope innards otherwise drift from `size`.
                .overlay(alignment: .bottomTrailing) {
                    if let resize {
                        resizeHandle(resize)
                            .offset(x: gripExteriorGap, y: gripExteriorGap)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .padding(dragHitPadding)
                .contentShape(Rectangle())
                .padding(-dragHitPadding)
                .gesture(panelDragGesture(center: center))
        }
        .frame(
            width: size.width + gripPad,
            height: size.height + gripPad,
            alignment: .topLeading
        )
        .scaleEffect((isDragging || isResizing) ? 1.03 : 1)
        .shadow(color: .black.opacity((isDragging || isResizing) ? 0.5 : 0), radius: 18, y: 8)
        .position(x: center.x + gripPad / 2, y: center.y + gripPad / 2)
        .onAppear { model.movablePanelFrames[id] = frame }
        .onChange(of: frame) { _, newFrame in model.movablePanelFrames[id] = newFrame }
        .onDisappear { model.movablePanelFrames[id] = nil }
        .sensoryFeedback(trigger: isDragging) { _, dragging in
            dragging ? .impact(flexibility: .rigid, intensity: 1) : nil
        }
        .sensoryFeedback(.selection, trigger: snapCell)
        .sensoryFeedback(trigger: isResizing) { _, resizing in
            resizing ? .impact(flexibility: .rigid, intensity: 0.8) : nil
        }
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .animation(.easeOut(duration: 0.14), value: isResizing)
    }

    /// Long-press then drag on the panel body to reposition (not applied to the resize grip).
    private func panelDragGesture(center: CGPoint) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isDragging {
                    isDragging = true
                    dragOrigin = center
                }
                guard let drag, let origin = dragOrigin else { return }
                let proposed = CGPoint(
                    x: origin.x + drag.translation.width,
                    y: origin.y + drag.translation.height)
                let snapped = clamp(snap(proposed))
                let cell =
                    Int((snapped.x / hapticGrid).rounded()) &* 100_000
                    &+ Int((snapped.y / hapticGrid).rounded())
                if cell != snapCell { snapCell = cell }
                model.movablePanelCenters[id] = snapped
            }
            .onEnded { _ in
                if let final = model.movablePanelCenters[id] {
                    model.setMovablePanelCenter(id, final, bounds: bounds)
                }
                isDragging = false
                dragOrigin = nil
            }
    }

    /// L-corner grip outside the panel's bottom-trailing corner; long-press then drag to scale uniformly.
    private func resizeHandle(_ resize: Resize) -> some View {
        let gripColor = isResizing ? LiveDesign.accent : LiveDesign.muted
        return CornerResizeGrip()
            .stroke(
                gripColor,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .square)
            )
            // Vertex sits on the overlay anchor (panel bottom-trailing); legs extend inward.
            .frame(width: gripVisualSize, height: gripVisualSize, alignment: .bottomTrailing)
            // Touch target extends past the visible bracket along the exterior legs.
            .frame(width: gripHitSize, height: gripHitSize, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(resizeGesture(resize))
    }

    private func resizeGesture(_ resize: Resize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isResizing {
                    isResizing = true
                    resizeStartScale = resize.scale
                }
                guard let drag else { return }
                // Exterior bottom-trailing grip: drag down-right enlarges, up-left shrinks.
                // Normalise by the base footprint so the feel is consistent at any current scale.
                let reach = resize.baseSize.width + resize.baseSize.height
                let delta = (drag.translation.width + drag.translation.height) / reach
                let newScale = min(
                    max(resizeStartScale + delta, resize.range.lowerBound), resize.range.upperBound)
                resize.onChange(newScale)
            }
            .onEnded { _ in isResizing = false }
    }

    private func resolvedCenter() -> CGPoint {
        if let session = model.movablePanelCenters[id] { return session }
        if let stored = model.movablePanelPositions[id] { return stored.center(in: bounds) }
        return defaultCenter
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        return CGPoint(
            x: min(max(bounds.minX + halfWidth, point.x), bounds.maxX - halfWidth),
            y: min(max(bounds.minY + halfHeight, point.y), bounds.maxY - halfHeight))
    }

    private func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x / positionGrid).rounded() * positionGrid,
            y: (point.y / positionGrid).rounded() * positionGrid)
    }
}

/// The on-screen rectangle where video is drawn with `AVLayerVideoGravity.resizeAspect` (aspect fit):
/// letterbox when the container is wider than the clip, pillarbox when taller.
func aspectFitRect(videoSize: CGSize, in container: CGRect) -> CGRect {
    guard videoSize.width > 0, videoSize.height > 0, container.width > 0, container.height > 0
    else {
        return container
    }
    let videoAspect = videoSize.width / videoSize.height
    let containerAspect = container.width / container.height
    if containerAspect > videoAspect {
        let height = container.height
        let width = height * videoAspect
        return CGRect(
            x: container.minX + (container.width - width) / 2,
            y: container.minY,
            width: width,
            height: height)
    }
    let width = container.width
    let height = width / videoAspect
    return CGRect(
        x: container.minX,
        y: container.minY + (container.height - height) / 2,
        width: width,
        height: height)
}

/// Applies a video track's `preferredTransform` so width/height match the displayed frame.
func videoDisplaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
    let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
}

/// Fits aspect ratio `R` inside `feed`, centred — the prototype's `rectForRatio`: full width +
/// letterbox when the guide is wider than the feed, full height + pillarbox when narrower.
func rectForRatio(_ feed: CGRect, _ ratio: CGFloat) -> CGRect {
    let width: CGFloat
    let height: CGFloat
    if feed.width / feed.height > ratio {
        height = feed.height
        width = feed.height * ratio
    } else {
        width = feed.width
        height = feed.width / ratio
    }
    return CGRect(
        x: feed.minX + (feed.width - width) / 2,
        y: feed.minY + (feed.height - height) / 2,
        width: width, height: height)
}

/// The on-screen scale applied to the live image to de-squeeze anamorphic footage: shrink one axis
/// by the squeeze factor (vertical = letterbox, horizontal = pillarbox), matching the prototype.
func desqueezeScale(_ desqueeze: AssistConfiguration.Desqueeze) -> CGSize {
    guard desqueeze.enabled, desqueeze.factor > 1 else { return CGSize(width: 1, height: 1) }
    let factor = CGFloat(desqueeze.factor)
    return desqueeze.orientation == .horizontal
        ? CGSize(width: 1 / factor, height: 1)
        : CGSize(width: 1, height: 1 / factor)
}

/// A still's presented size once de-squeezed: the source with the chosen axis divided out.
///
/// Stills cannot use ``desqueezeScale`` the way the live feed does. The feed layer is scaled inside
/// a fixed rect, but a still is FITTED to its container first, so scaling afterwards would push the
/// image outside the frame it was just fitted into. De-squeezing the size before the fit keeps the
/// whole picture on screen and lets everything anchored to the fitted rect — the AF box on instant
/// review, the zoom transform in the viewer — follow without knowing about anamorphic at all.
///
/// Note `orientation` names the axis that is SCALED DOWN (matching ``desqueezeScale``), not the
/// lens's squeeze axis: vertical letterboxes, horizontal pillarboxes.
func desqueezedSize(_ size: CGSize, _ desqueeze: AssistConfiguration.Desqueeze) -> CGSize {
    guard desqueeze.enabled, desqueeze.factor > 1, size.width > 0, size.height > 0 else {
        return size
    }
    let factor = CGFloat(desqueeze.factor)
    return desqueeze.orientation == .horizontal
        ? CGSize(width: size.width / factor, height: size.height)
        : CGSize(width: size.width, height: size.height / factor)
}

/// ``desqueezedSize`` as an aspect ratio, for the SwiftUI fits that take one. `nil` when
/// de-squeeze is off, which `aspectRatio(_:contentMode:)` reads as "use the image's own".
func desqueezedAspectRatio(
    _ size: CGSize, _ desqueeze: AssistConfiguration.Desqueeze
) -> CGFloat? {
    guard desqueeze.enabled, desqueeze.factor > 1, size.width > 0, size.height > 0 else {
        return nil
    }
    let presented = desqueezedSize(size, desqueeze)
    return presented.width / presented.height
}

/// The visible (de-squeezed) image rectangle inside the full feed rect — the same centred sub-rect
/// the scale above produces, so framing overlays land on the de-squeezed image.
func desqueezedRect(_ full: CGRect, _ desqueeze: AssistConfiguration.Desqueeze) -> CGRect {
    guard desqueeze.enabled, desqueeze.factor > 1 else { return full }
    let factor = CGFloat(desqueeze.factor)
    if desqueeze.orientation == .horizontal {
        let width = full.width / factor
        return CGRect(x: full.midX - width / 2, y: full.minY, width: width, height: full.height)
    }
    let height = full.height / factor
    return CGRect(x: full.minX, y: full.midY - height / 2, width: full.width, height: height)
}

/// Framing aids that must register pixel-exact with the live image — guides, grid, crosshair, and
/// level. Drawn as an overlay *on the feed image itself* (like the AF boxes), so they share the feed
/// rectangle by construction instead of recomputing it. Positioned against the visible feed rect the
/// same way the index.html prototype does.
struct FeedAlignedAssists: View {
    @Environment(NativeAppModel.self) private var model
    /// Clean output mode (DISP 2). Which tools survive it is decided by `MonitorChromePolicy` via
    /// `renderedLiveAssistTools` — nothing unless the operator pinned it. This flag only carries
    /// the layout consequence (no bottom bars, so the EV needle drops to the feed edge).
    var clean: Bool = false
    /// When set (e.g. letterboxed media playback), framing overlays align to this rect instead of
    /// the full geometry.
    var feed: CGRect? = nil
    /// Tools omitted from this overlay (e.g. horizon level during clip playback).
    var excludeTools: Set<MonitorAssistTool> = []
    /// When true, reads playback assist visibility instead of the live monitor set.
    var usePlaybackContext: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let baseFeed = feed ?? CGRect(origin: .zero, size: proxy.size)
            let visible =
                (usePlaybackContext
                ? model.preferences.playbackVisibleAssistTools
                : model.renderedLiveAssistTools).subtracting(excludeTools)
            let overlayDesqueeze: AssistConfiguration.Desqueeze = {
                var config = model.assistConfiguration.desqueeze
                config.enabled = visible.contains(.desqueeze)
                return config
            }()
            let feed = desqueezedRect(baseFeed, overlayDesqueeze)
            ZStack {
                if visible.contains(.guides) {
                    AspectGuideFrameView(
                        configuration: model.assistConfiguration.guides, feed: feed)
                }
                if visible.contains(.evMeter),
                    // Photography-only: a persisted visibility set from an older build may
                    // still carry the tool, so the render guards the mode as well.
                    model.isPhotographyMode,
                    let sixths = model.cameraPropertySnapshot.evIndicatorSixths,
                    model.cameraPropertySnapshot.evIndicatorLit != false
                {
                    // Camera-fed exposure needle, seated bottom-centre of the feed. It lifts
                    // above the capture bar's lane only where a bar actually overlays the feed
                    // (landscape live, portrait fill); clean mode and portrait fit keep the
                    // feed bottom free, so it drops to the edge.
                    let feedBottomFree =
                        model.monitorIsPortrait
                        && (model.isPhotographyMode
                            || model.preferences.portraitFeedAspect != .fill)
                    EVMeterView(sixths: sixths)
                        .position(
                            x: feed.midX, y: feed.maxY - (clean || feedBottomFree ? 28 : 92)
                        )
                        .allowsHitTesting(false)
                }
                if visible.contains(.grid) {
                    FeedGridView(grid: model.assistConfiguration.grid, feed: feed)
                }
                if visible.contains(.crosshair) {
                    FeedCrosshairView(feed: feed)
                }
                // Drawn once over the whole feed like every other framing aid, from the same rect
                // — so the divider lands exactly on the boundary the grade was split at.
                if let split = LUTResolution.splitComparison(
                    visibleTools: visible, preferences: model.preferences,
                    muted: model.splitComparisonMuted)
                {
                    FeedSplitComparisonMarks(orientation: split, feed: feed)
                }
                if visible.contains(.level) && model.assistConfiguration.level.enabled {
                    FeedLevelView(
                        style: model.assistConfiguration.level.style, feed: feed,
                        visibleBounds: Self.visibleBounds(
                            contentGlobal: proxy.frame(in: .global), size: proxy.size,
                            screen: screenBounds))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The foreground scene's bounds — the on-screen area the over-widened feed content gets
    /// clipped to (the portrait fill crop frame spans the full viewport width, so the screen
    /// intersection and the clip intersection coincide).
    private var screenBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.coordinateSpace.bounds
    }

    /// The portion of this overlay that is actually on screen, in its own coordinate space.
    ///
    /// Framing aids register pixel-exact with the feed content — including content that portrait
    /// fill (and fill + de-squeeze) over-widens past the screen and clips. HUD instruments like the
    /// level gauge instead seat against what the operator can see; this recovers that rect by
    /// intersecting the content with the screen (`screen` and `contentGlobal` share the global
    /// space). Falls back to the full content bounds when the intersection degenerates (no scene
    /// yet, zero-size first layout).
    static func visibleBounds(contentGlobal: CGRect, size: CGSize, screen: CGRect?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard let screen else { return bounds }
        let screenLocal = screen.offsetBy(dx: -contentGlobal.minX, dy: -contentGlobal.minY)
        let visible = bounds.intersection(screenLocal)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }
}

/// Artificial horizon, two styles: a rolling horizon line and a two-axis bubble gauge; both go
/// green within ±0.8° of level.
///
/// Reads the **camera's** virtual horizon (PTP `AngleLevelYawing` 0xD07E roll /
/// `AngleLevelPitching` 0xD07D pitch) so the horizon reflects the shot's tilt, not the monitor's.
/// The value encoding is undocumented — decoded best-effort and logged for HW calibration
/// (category `camera-level`). Falls back to the monitor's CoreMotion until the body reports one.
struct FeedLevelView: View {
    @Environment(NativeAppModel.self) private var model
    let style: AssistConfiguration.Level.Style
    let feed: CGRect
    /// On-screen portion of the overlay in its coordinate space — what the gauge seats against.
    let visibleBounds: CGRect
    @State private var device = DeviceLevel()

    var body: some View {
        let usesDeviceFallback = model.cameraLevelRoll == nil
        let roll = model.cameraLevelRoll ?? device.roll
        let pitch = model.cameraLevelPitch ?? device.pitch
        // Portrait fill overlays a capture strip on the visible feed's bottom edge; the roll track
        // seats above it. Fit tiles its controls below the feed band, so nothing to clear there.
        let bottomChrome =
            model.monitorIsPortrait && model.preferences.portraitFeedAspect == .fill
            ? CGFloat(MonitorPortraitLayout.captureBarHeight) : 0
        Group {
            if style == .gauge {
                LevelGaugeView(
                    roll: roll, pitch: pitch, feed: feed, visibleBounds: visibleBounds,
                    isPortrait: model.monitorIsPortrait, bottomChrome: bottomChrome)
            } else {
                LevelHorizonView(roll: roll)
                    .position(x: feed.midX, y: feed.midY)
            }
        }
        // Only run device motion while it's actually the source — stop it once the camera supplies a
        // level so the monitor's own tilt can't leak into the readout.
        .onAppear { if usesDeviceFallback { device.start() } }
        .onChange(of: usesDeviceFallback) { _, fallback in
            fallback ? device.start() : device.stop()
        }
        // The gravity→roll mapping depends on which way the interface is rotated, so keep the
        // motion source told about the current shell orientation.
        .onChange(of: model.monitorIsPortrait, initial: true) { _, portrait in
            device.isPortrait = portrait
        }
        .onDisappear { device.stop() }
    }
}

/// Streams the device's gravity-derived roll/pitch (degrees) while the level overlay is on. Gravity
/// arrives in CoreMotion's fixed, portrait-referenced device frame (+x out the right edge, +y out
/// the top, +z out of the screen), so the screen-plane roll depends on which way the interface is
/// rotated — `isPortrait` selects the mapping for the two orientations the app supports (Portrait,
/// LandscapeRight). The simulator reports no motion, so the mapping is derived from CoreMotion's
/// documented axis conventions; on-hardware sign calibration may still want a one-line flip.
@Observable
final class DeviceLevel {
    var roll: Double = 0
    var pitch: Double = 0
    /// True while the monitor shell is laid out portrait; kept current by the hosting view.
    var isPortrait = false

    @ObservationIgnored private let manager = CMMotionManager()

    /// Screen-plane roll in degrees from the device-frame gravity vector: 0 = upright for the
    /// given interface orientation, positive = tilted clockwise from the viewer's perspective.
    ///
    /// Roll is the angle of gravity off screen-down, toward screen-right: `atan2(g·right, g·down)`.
    /// Portrait: screen right/down = device +x/−y. LandscapeRight (home side right, device +x
    /// pointing at the sky, so g.x = −1 when level): screen right/down = device −y/−x.
    static func displayRoll(gravityX: Double, gravityY: Double, isPortrait: Bool) -> Double {
        let radians =
            isPortrait
            ? atan2(gravityX, -gravityY)
            : atan2(-gravityY, -gravityX)
        return radians * 180 / .pi
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            let newRoll = Self.displayRoll(gravityX: g.x, gravityY: g.y, isPortrait: isPortrait)
            let newPitch = atan2(g.z, (g.x * g.x + g.y * g.y).squareRoot()) * 180 / .pi
            // Light low-pass so the readout settles instead of jittering on every sample.
            roll = roll * 0.75 + newRoll * 0.25
            pitch = pitch * 0.75 + newPitch * 0.25
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }
}

/// Rolling horizon: two accent wings around a centre ring, rotating with roll; green when level.
struct LevelHorizonView: View {
    let roll: Double

    var body: some View {
        let level = abs(roll) < 0.8
        let color = level ? LiveDesign.good : LiveDesign.accent
        HStack(spacing: 10) {
            Capsule().fill(color).frame(width: 64, height: 2)
            Circle().stroke(color, lineWidth: 1.6).frame(width: 10, height: 10)
            Capsule().fill(color).frame(width: 64, height: 2)
        }
        .rotationEffect(.degrees(roll))
        .animation(.easeOut(duration: 0.18), value: level)
    }
}

/// Two-axis level: a horizontal track (roll) near the bottom and a vertical track (pitch) on the
/// right. Each track carries 2° tick graduations so you can feel how far off you are, a correction
/// chevron pointing the way back to centre (more chevrons = further off), and a live degree readout.
/// A track snaps green within ±0.6° on its own axis.
/// The body's exposure indicator as a compact glass strip: a ±3 EV tick bar (taller ticks
/// on whole stops), the camera's 1/6-EV needle, and a signed numeric readout that keeps the
/// truth when the needle clamps at the rail. Read-only — the value comes straight from the
/// camera's own metering.
struct EVMeterView: View {
    let sixths: Int

    private var ev: Double { Double(sixths) / 6 }

    private var readout: String {
        String(format: "%+.1f", ev)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(readout)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(abs(ev) < 0.01 ? LiveDesign.text : LiveDesign.accent)
                .frame(width: 34, alignment: .trailing)
            Canvas { context, size in
                let midY = size.height / 2
                let usable = size.width
                let evSpan = 3.0
                func x(forEV value: Double) -> CGFloat {
                    let clamped = min(evSpan, max(-evSpan, value))
                    return CGFloat((clamped + evSpan) / (2 * evSpan)) * usable
                }
                // Baseline.
                var base = Path()
                base.move(to: CGPoint(x: 0, y: midY))
                base.addLine(to: CGPoint(x: usable, y: midY))
                context.stroke(base, with: .color(.white.opacity(0.25)), lineWidth: 1)
                // Ticks every 1/3 EV; whole stops taller.
                var third = -9
                while third <= 9 {
                    let value = Double(third) / 3
                    let tall = third % 3 == 0
                    let height: CGFloat = tall ? 8 : 4
                    var tick = Path()
                    let tickX = x(forEV: value)
                    tick.move(to: CGPoint(x: tickX, y: midY - height / 2))
                    tick.addLine(to: CGPoint(x: tickX, y: midY + height / 2))
                    context.stroke(
                        tick, with: .color(.white.opacity(tall ? 0.55 : 0.3)), lineWidth: 1)
                    third += 1
                }
                // The needle.
                var needle = Path()
                let needleX = x(forEV: ev)
                needle.move(to: CGPoint(x: needleX, y: 1))
                needle.addLine(to: CGPoint(x: needleX, y: size.height - 1))
                context.stroke(needle, with: .color(LiveDesign.accent), lineWidth: 2)
            }
            .frame(width: 132, height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule())
    }
}

struct LevelGaugeView: View {
    let roll: Double
    let pitch: Double
    let feed: CGRect
    /// On-screen portion of the overlay's coordinate space (see `FeedAlignedAssists.visibleBounds`).
    let visibleBounds: CGRect
    let isPortrait: Bool
    /// Height of chrome overlaying the visible feed's bottom edge (portrait fill capture strip).
    let bottomChrome: CGFloat

    /// Seats for the two tracks. The gauge is a HUD instrument, not a framing aid: unlike
    /// grid/crosshair/guides (which stay pixel-exact with the image content, even when portrait
    /// fill or de-squeeze widen it past the screen), the gauge seats against the VISIBLE feed —
    /// the content rect intersected with the on-screen bounds — so neither track can land in the
    /// clipped-away overhang.
    ///
    /// Roll (horizontal track): centred, lifted off the visible bottom edge — landscape by the
    /// bottom capture/assist bars that overlay the feed (chrome bottom inset 12 + control height
    /// 58, plus the gauge's readout half-height and a small gap), portrait by a bottom-edge hug
    /// plus `bottomChrome` for any strip overlaying the visible feed (fill's capture bar).
    /// Pitch (vertical track): hugs the visible trailing edge, readout on the feed side.
    static func seats(
        feed: CGRect, visibleBounds: CGRect, isPortrait: Bool, bottomChrome: CGFloat
    ) -> (roll: CGPoint, pitch: CGPoint) {
        var visible = feed.intersection(visibleBounds)
        if visible.isNull || visible.isEmpty { visible = feed }
        let rollLift = (isPortrait ? 30 : 104) + bottomChrome
        return (
            roll: CGPoint(x: visible.midX, y: visible.maxY - rollLift),
            pitch: CGPoint(x: visible.maxX - 44, y: visible.midY)
        )
    }

    var body: some View {
        let seats = Self.seats(
            feed: feed, visibleBounds: visibleBounds, isPortrait: isPortrait,
            bottomChrome: bottomChrome)
        ZStack {
            LevelAxisGauge(orientation: .horizontal, value: roll)
                .position(seats.roll)
            LevelAxisGauge(orientation: .vertical, value: pitch)
                .position(seats.pitch)
        }
        .allowsHitTesting(false)
    }
}

/// One axis of the level gauge — a graduated track with a bead, a correction chevron, and a degree
/// readout. `value` is signed degrees (0 = level); a positive value drives the bead toward the + end.
private struct LevelAxisGauge: View {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    let value: Double

    private let span = 84.0  // px from centre to the ±maxAngle end of the track
    private let maxAngle = 8.0  // degrees mapped to the end of the track
    private let tickStep = 2.0  // graduation spacing in degrees
    private let threshold = 0.6  // |value| below this reads "level"

    private var isHorizontal: Bool { orientation == .horizontal }
    private var isLevel: Bool { abs(value) < threshold }
    private var tint: Color { isLevel ? LiveDesign.good : LiveDesign.accent }
    private var beadOffset: CGFloat { CGFloat(max(-1, min(1, value / maxAngle)) * span) }

    /// 1–3, larger the further off level — drives how many correction chevrons show.
    private var urgency: Int {
        switch abs(value) {
        case ..<(maxAngle / 3): return 1
        case ..<(2 * maxAngle / 3): return 2
        default: return 3
        }
    }

    var body: some View {
        let trackLen = CGFloat(span * 2 + 28)
        ZStack {
            graduations
                .frame(
                    width: isHorizontal ? trackLen : 26,
                    height: isHorizontal ? 26 : trackLen)
            if !isLevel { chevrons }
            bead
            readout
        }
        .animation(.easeOut(duration: 0.12), value: isLevel)
        .animation(.easeOut(duration: 0.09), value: value)
    }

    /// Baseline + 2° tick graduations, the centre tick emphasised.
    private var graduations: some View {
        Canvas { ctx, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            var base = Path()
            if isHorizontal {
                base.move(to: CGPoint(x: mid.x - CGFloat(span), y: mid.y))
                base.addLine(to: CGPoint(x: mid.x + CGFloat(span), y: mid.y))
            } else {
                base.move(to: CGPoint(x: mid.x, y: mid.y - CGFloat(span)))
                base.addLine(to: CGPoint(x: mid.x, y: mid.y + CGFloat(span)))
            }
            ctx.stroke(base, with: .color(.white.opacity(0.22)), lineWidth: 2)

            var deg = -maxAngle
            while deg <= maxAngle + 0.001 {
                let t = CGFloat(deg / maxAngle * span)
                let centre = abs(deg) < 0.001
                let half: CGFloat = centre ? 9 : 5
                var tick = Path()
                if isHorizontal {
                    tick.move(to: CGPoint(x: mid.x + t, y: mid.y - half))
                    tick.addLine(to: CGPoint(x: mid.x + t, y: mid.y + half))
                } else {
                    tick.move(to: CGPoint(x: mid.x - half, y: mid.y - t))
                    tick.addLine(to: CGPoint(x: mid.x + half, y: mid.y - t))
                }
                ctx.stroke(
                    tick, with: .color(.white.opacity(centre ? 0.75 : 0.34)),
                    lineWidth: centre ? 2 : 1)
                deg += tickStep
            }
        }
    }

    private var bead: some View {
        Circle()
            .fill(tint)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .offset(
                x: isHorizontal ? beadOffset : 0,
                y: isHorizontal ? 0 : -beadOffset)
    }

    /// Chevrons just centre-ward of the bead, pointing toward centre — the way to re-level.
    private var chevrons: some View {
        let toNegative = value > 0  // need to move toward the − end to re-centre
        let symbol =
            isHorizontal
            ? (toNegative ? "chevron.left" : "chevron.right")
            : (toNegative ? "chevron.down" : "chevron.up")
        let gap: CGFloat = 16
        let sign = CGFloat(value > 0 ? 1 : -1)
        return Group {
            if isHorizontal {
                HStack(spacing: -2) {
                    ForEach(Array(0..<urgency), id: \.self) { i in chevronGlyph(symbol, index: i) }
                }
            } else {
                VStack(spacing: -2) {
                    ForEach(Array(0..<urgency), id: \.self) { i in chevronGlyph(symbol, index: i) }
                }
            }
        }
        .offset(
            x: isHorizontal ? beadOffset - sign * gap : 0,
            y: isHorizontal ? 0 : -beadOffset + sign * gap)
    }

    private func chevronGlyph(_ symbol: String, index: Int) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(LiveDesign.accent)
            .opacity(1.0 - Double(index) * 0.22)
    }

    private var readout: some View {
        let shown = abs(value) < 0.05 ? 0 : value
        return Text(String(format: "%+.1f°", shown))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isLevel ? LiveDesign.good : LiveDesign.text.opacity(0.85))
            .fixedSize()
            .offset(
                x: isHorizontal ? 0 : -42,
                y: isHorizontal ? -24 : 0)
    }
}

/// One selected aspect ratio resolved to its centred frame within the feed rect.
private struct GuideFrame: Identifiable {
    let ratio: AssistConfiguration.Guides.AspectRatio
    let rect: CGRect
    var id: String { ratio.rawValue }
}

/// Aspect guide drawn against the real feed rect via `rectForRatio`, with an optional darkening
/// mask and the corner ratio tag — the prototype's `.guide-frame`.
struct AspectGuideFrameView: View {
    let configuration: AssistConfiguration.Guides
    let feed: CGRect

    var body: some View {
        // Every selected ratio, narrow→wide for a stable draw order.
        let frames =
            configuration.selectedRatios
            .sorted { $0.value < $1.value }
            .map { GuideFrame(ratio: $0, rect: rectForRatio(feed, CGFloat($0.value))) }
        ZStack {
            // Mask = darken the inverse of the UNION of every selected frame. Fill the feed dark, then
            // punch each frame out with `.destinationOut` so overlaps clear idempotently — an even-odd
            // fill would wrongly re-darken regions where two centred frames overlap.
            if configuration.maskEnabled, !frames.isEmpty {
                Canvas { context, _ in
                    context.fill(Path(feed), with: .color(.black.opacity(0.6)))
                    context.blendMode = .destinationOut
                    for frame in frames {
                        context.fill(Path(frame.rect), with: .color(.black))
                    }
                }
            }
            ForEach(frames) { frame in
                Rectangle()
                    .stroke(LiveDesign.accent.opacity(0.85), lineWidth: 1)
                    .frame(width: frame.rect.width, height: frame.rect.height)
                    .position(x: frame.rect.midX, y: frame.rect.midY)
                Text(frame.ratio.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(LiveDesign.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
                    .position(x: frame.rect.minX, y: frame.rect.minY)
                    .offset(x: 34, y: 13)
            }
        }
    }
}

/// Thirds / phi / diagonal grid lines drawn across the feed rect (prototype stroke
/// `rgba(255,255,255,.22)`, 1px).
struct FeedGridView: View {
    let grid: AssistConfiguration.Grid
    let feed: CGRect

    var body: some View {
        Path { path in
            if grid.thirds { fractions(&path, [1.0 / 3, 2.0 / 3]) }
            if grid.phi { fractions(&path, [0.382, 0.618]) }
            if grid.diagonal {
                path.move(to: CGPoint(x: feed.minX, y: feed.minY))
                path.addLine(to: CGPoint(x: feed.maxX, y: feed.maxY))
                path.move(to: CGPoint(x: feed.maxX, y: feed.minY))
                path.addLine(to: CGPoint(x: feed.minX, y: feed.maxY))
            }
        }
        .stroke(Color.white.opacity(0.22), lineWidth: 1)
    }

    private func fractions(_ path: inout Path, _ fractions: [CGFloat]) {
        for fraction in fractions {
            let x = feed.minX + feed.width * fraction
            let y = feed.minY + feed.height * fraction
            path.move(to: CGPoint(x: x, y: feed.minY))
            path.addLine(to: CGPoint(x: x, y: feed.maxY))
            path.move(to: CGPoint(x: feed.minX, y: y))
            path.addLine(to: CGPoint(x: feed.maxX, y: y))
        }
    }
}

/// Centre crosshair: a 46pt ring plus a 34pt cross, centred on the feed (prototype `.cross`).
struct FeedCrosshairView: View {
    let feed: CGRect

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.65)).frame(width: 1.4, height: 40)
            Rectangle().fill(Color.white.opacity(0.65)).frame(width: 40, height: 1.4)
        }
        .position(x: feed.midX, y: feed.midY)
    }
}

/// The 50/50 Log-vs-LUT comparison's divider and its two half labels.
///
/// Presentation only — the grade itself is split in the feed pipeline (`LiveFrameProcessor` /
/// `ImageEffectsCompositor.splitting`). Both draw at the centre of the same feed rect, so the
/// hairline sits on the real boundary rather than near it.
///
/// The labels hug the divider at one edge instead of sitting in the middle of each half: the
/// operator is judging the image, and a caption over the subject is exactly what "without
/// permanently obscuring the image" rules out. They ride the LUT tool's own visibility (see
/// `LUTResolution.splitComparison`), so clean view carries them only where the operator pinned the
/// tool in.
struct FeedSplitComparisonMarks: View {
    let orientation: SplitComparisonOrientation
    let feed: CGRect

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(
                    width: orientation == .vertical ? 1 : feed.width,
                    height: orientation == .vertical ? feed.height : 1
                )
                .position(x: feed.midX, y: feed.midY)
            label(SplitComparison.logLabel)
                .position(logPosition)
            label(SplitComparison.lutLabel)
                .position(lutPosition)
        }
        .allowsHitTesting(false)
    }

    /// Deliberately tiny and unfilled: the split itself already says which half is which, so these
    /// only confirm it. A drop shadow rather than a capsule fill — the graded half can be far
    /// darker or far brighter than the log half depending on the look, and a shadow reads over
    /// both where one fixed fill colour reads over neither.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .kerning(0.5)
            .foregroundStyle(Color.white.opacity(0.85))
            .shadow(color: .black.opacity(0.8), radius: 1.5, y: 0.5)
    }

    /// Where the pair sits along the divider, as a fraction of the feed rather than a constant:
    /// the same number then clears the status deck in landscape (~400pt tall) and in portrait, and
    /// on a tablet, without knowing which chrome is mounted.
    private var alongDivider: CGFloat { 0.16 }

    /// Log side: left of a vertical divider, above a horizontal one.
    private var logPosition: CGPoint {
        switch orientation {
        case .vertical:
            CGPoint(x: feed.midX - 16, y: feed.minY + feed.height * alongDivider)
        case .horizontal:
            CGPoint(x: feed.minX + feed.width * alongDivider, y: feed.midY - 10)
        }
    }

    /// LUT side: right of a vertical divider, below a horizontal one.
    private var lutPosition: CGPoint {
        switch orientation {
        case .vertical:
            CGPoint(x: feed.midX + 16, y: feed.minY + feed.height * alongDivider)
        case .horizontal:
            CGPoint(x: feed.minX + feed.width * alongDivider, y: feed.midY + 10)
        }
    }
}

struct FalseColorReference: View {
    struct Segment: Equatable, Identifiable {
        let id: Int
        let lowerFraction: Double
        let upperFraction: Double
        let band: FalseColorBand
    }

    struct AxisMarker: Equatable, Identifiable {
        let id: Int
        let label: String
        let fraction: Double
    }

    static let panelSize = CGSize(width: 264, height: 52)

    let scale: FalseColorScale
    let mapping: ExposureSignalMapping

    /// The measured curve's compact key label — the photo previews are display-referred.
    private var curveKeyLabel: String {
        switch mapping.curve {
        case .redLog3G10: "L3G10"
        case .nikonNLog: "N-Log"
        case .srgb: "sRGB"
        case .hlg: "HLG"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("False Color")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                Spacer()
                Text("\(scaleLabel) · \(curveKeyLabel)")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: neutralGradientColors,
                        startPoint: .leading,
                        endPoint: .trailing)
                    ForEach(Self.segments(scale: scale, mapping: mapping)) { segment in
                        Rectangle()
                            .fill(
                                Color(
                                    red: segment.band.red,
                                    green: segment.band.green,
                                    blue: segment.band.blue)
                            )
                            .frame(
                                width: max(
                                    1,
                                    geometry.size.width
                                        * (segment.upperFraction - segment.lowerFraction))
                            )
                            .offset(x: geometry.size.width * segment.lowerFraction)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            .frame(height: 8)
            axisView
        }
        .padding(7)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }

    static func segments(
        scale: FalseColorScale, mapping: ExposureSignalMapping
    ) -> [Segment] {
        let bands = scale.bands(mapping: mapping)
        switch scale {
        case .stops:
            let domain = stopReferenceDomain(mapping: mapping)
            return bands.enumerated().map { index, band in
                Segment(
                    id: index,
                    lowerFraction: stopFraction(
                        band.lowerBound, in: domain, infiniteFallback: 0),
                    upperFraction: stopFraction(
                        band.upperBound, in: domain, infiniteFallback: 1),
                    band: band)
            }
        case .ire, .limits:
            return bands.enumerated().map { index, band in
                Segment(
                    id: index,
                    lowerFraction: min(1, max(0, band.lowerBound / 100)),
                    upperFraction: band.upperBound.isFinite
                        ? min(1, max(0, band.upperBound / 100)) : 1,
                    band: band)
            }
        }
    }

    static func stopAxisMarkers(mapping: ExposureSignalMapping) -> [AxisMarker] {
        let domain = stopReferenceDomain(mapping: mapping)
        let maximum = FalseColorMap.maximumSceneStop(mapping: mapping)
        let markers: [(String, Double)] = [
            ("Min", FalseColorMap.minimumSceneStop),
            ("−3", -3),
            ("18%", 0),
            ("Skin", 1),
            ("+2", 2),
            ("Max", maximum),
        ]
        return markers.enumerated().map { index, marker in
            AxisMarker(
                id: index, label: marker.0,
                fraction: stopFraction(marker.1, in: domain, infiniteFallback: 0))
        }
    }

    private static func stopReferenceDomain(
        mapping: ExposureSignalMapping
    ) -> ClosedRange<Double> {
        let lower = FalseColorMap.minimumSceneStop - 1.0 / 6
        let upper = max(6, FalseColorMap.maximumSceneStop(mapping: mapping) + 1.0 / 6)
        return lower...upper
    }

    private static func stopFraction(
        _ value: Double, in domain: ClosedRange<Double>, infiniteFallback: Double
    ) -> Double {
        guard value.isFinite else { return infiniteFallback }
        return min(1, max(0, (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
    }

    @ViewBuilder private var axisView: some View {
        if scale == .stops {
            GeometryReader { geometry in
                ForEach(Self.stopAxisMarkers(mapping: mapping)) { marker in
                    Text(marker.label)
                        .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(
                            x: min(
                                geometry.size.width - 8,
                                max(8, geometry.size.width * marker.fraction)),
                            y: 3.5)
                }
            }
            .frame(height: 7)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(axisLabels.enumerated()), id: \.offset) { index, label in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(label)
                        .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    private var neutralGradientColors: [Color] {
        switch scale {
        case .stops: [Color(white: 0.04), Color(white: 0.86)]
        case .ire, .limits: [Color(white: 0.54), Color(white: 0.75)]
        }
    }

    private var axisLabels: [String] {
        switch scale {
        case .stops: []
        case .ire: ["clip / shadows", "18%", "skin hi", "highlights → clip"]
        case .limits: ["crushed", "midtones untouched", "clipped"]
        }
    }

    private var scaleLabel: String {
        switch scale {
        case .stops: "ZC Stops"
        case .ire: "IRE"
        case .limits: "Limits"
        }
    }
}

/// RED-style RGB goal-post meter — slim vertical columns, centre-anchored single-sided level fill,
/// clip/crush dots at the highlight and shadow edges.
/// Floating scope chrome around the shared MonitorUI plots, drawn on this camera's exposure axis.
struct ScopeMini: View {
    enum Style {
        case waveform
        case parade
        case histogram
        case vectorscope
    }

    let title: String
    let systemImage: String
    let style: Style
    /// Samples, monitor-domain vectorscope points, and the phosphor trail — one bundle per tick.
    let assist: ScopeAssistBundle
    var scopes: AssistConfiguration.Scopes = AssistConfiguration.Scopes()
    var mapping = ExposureSignalMapping(curve: .redLog3G10)

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in scopePlot(size: proxy.size) }
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 2)
                Text(chip)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .background(MonitorScopePalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 12)
    }

    private var chip: String {
        switch style {
        case .waveform: scopes.waveformMode.rawValue.uppercased()
        case .parade: scopes.paradeMode.rawValue.uppercased()
        case .histogram: "RGBL"
        case .vectorscope:
            "MON · \(scopes.vectorscopeZoom.rawValue.uppercased())"
        }
    }

    @ViewBuilder private func scopePlot(size: CGSize) -> some View {
        switch style {
        case .waveform:
            MonitorWaveformScopePlot(
                samples: assist.samples, trail: assist.trailSamples,
                mode: .waveform(MonitorWaveformMode(rawValue: scopes.waveformMode.rawValue) ?? .luma),
                axis: mapping.scopeLevelAxis, revision: assist.revision,
                intensity: AssistConfiguration.Scopes.waveformParadeBrightnessMultiplier(
                    scopes.waveformBrightness),
                guides: Self.guides(scopes.waveformGuides), size: size)
        case .parade:
            MonitorWaveformScopePlot(
                samples: assist.samples, trail: assist.trailSamples,
                mode: .parade(MonitorParadeMode(rawValue: scopes.paradeMode.rawValue) ?? .rgb),
                axis: mapping.scopeLevelAxis, revision: assist.revision,
                intensity: AssistConfiguration.Scopes.waveformParadeBrightnessMultiplier(
                    scopes.paradeBrightness),
                guides: Self.guides(scopes.paradeGuides), size: size)
        case .histogram:
            MonitorHistogramScopePlot(
                display: assist.histogramDisplay, traffic: assist.traffic,
                showTrafficLights: scopes.histogramTrafficLights)
        case .vectorscope:
            MonitorVectorscopeScopePlot(
                points: assist.vectorscopePoints, trail: assist.trailVectorscopePoints,
                zoom: MonitorVectorscopeZoom(rawValue: scopes.vectorscopeZoom.rawValue) ?? .x1,
                brightness: scopes.vectorscopeBrightness, revision: assist.revision)
        }
    }

    private static func guides(_ lines: AssistConfiguration.Scopes.GuideLines) -> MonitorScopeGuides {
        MonitorScopeGuides(clip: lines.clip, crush: lines.crush, middle: lines.middle)
    }
}

struct AudioMetersPanelMini: View {
    /// Slim on purpose: two readable tracks without competing with the picture or the
    /// camera-control rails in the ~400 pt landscape monitor.
    static let panelSize = CGSize(width: 28, height: 168)

    let levels: AudioMeterLevels?
    let sensitivity: String?

    private static let yellowFromDB = -18.0
    private static let redFromDB = -6.0
    private static let guideMarks: [Double] = [0, -6, -18, -36]

    static func displayedSensitivity(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed.uppercased()
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("AUDIO")
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundStyle(LiveDesign.text.opacity(0.58))
            Canvas { context, size in
                drawMeters(in: context, size: size)
            }
            VStack(spacing: 0) {
                Text("SENS")
                    .font(.system(size: 5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.42))
                Text(Self.displayedSensitivity(sensitivity))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 7)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(Color(red: 0.025, green: 0.036, blue: 0.03).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio Levels")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let levels else {
            return "Audio levels unavailable, sensitivity \(Self.displayedSensitivity(sensitivity))"
        }
        func channel(_ name: String, _ ch: AudioMeterChannel) -> String {
            ch.levelDB <= AudioMeterBallistics.floorDB + 0.5
                ? "\(name) silent"
                : String(format: "%@ %.0f dB, peak %.0f", name, ch.levelDB, ch.peakDB)
        }
        return
            "\(channel("left", levels.left)), \(channel("right", levels.right)), sensitivity \(Self.displayedSensitivity(sensitivity))"
    }

    private func zoneColor(_ db: Double) -> Color {
        if db >= Self.redFromDB { return MonitorScopePalette.rgba(255, 92, 82, 0.95) }
        if db >= Self.yellowFromDB { return MonitorScopePalette.rgba(245, 208, 82, 0.95) }
        return MonitorScopePalette.rgba(86, 235, 132, 0.9)
    }

    private func drawMeters(in context: GraphicsContext, size: CGSize) {
        let floor = AudioMeterBallistics.floorDB
        let labelReserve: CGFloat = 10
        let barsRect = CGRect(
            x: 0, y: 2, width: size.width,
            height: size.height - labelReserve - 2)
        func y(_ db: Double) -> CGFloat {
            let fraction = max(0, min(1, (db - floor) / -floor))
            return barsRect.maxY - CGFloat(fraction) * barsRect.height
        }

        // Keep a few hairline references for visual rhythm, without the dB-number column that made
        // the meter unnecessarily wide.
        for mark in Self.guideMarks {
            let tickY = y(mark)
            var line = Path()
            line.move(to: CGPoint(x: barsRect.minX, y: tickY))
            line.addLine(to: CGPoint(x: barsRect.maxX, y: tickY))
            context.stroke(
                line, with: .color(MonitorScopePalette.rgba(220, 235, 225, 0.10)), lineWidth: 1)
        }

        let gap: CGFloat = 2
        let inset: CGFloat = 1
        let barWidth = (barsRect.width - gap - inset * 2) / 2
        for (index, pair) in [("L", levels?.left), ("R", levels?.right)].enumerated() {
            let x = barsRect.minX + inset + CGFloat(index) * (barWidth + gap)
            let track = CGRect(
                x: x, y: barsRect.minY, width: barWidth, height: barsRect.height)
            context.fill(
                Path(roundedRect: track, cornerRadius: 2),
                with: .color(LiveDesign.text.opacity(0.08)))

            context.draw(
                Text(pair.0)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.58)),
                at: CGPoint(x: track.midX, y: size.height - labelReserve / 2))

            // An unmeasured source draws the track without a fabricated silent readout.
            guard let channel = pair.1 else { continue }
            // Zone-coloured fill clipped to the decaying bar level.
            let levelY = y(channel.levelDB)
            if levelY < track.maxY - 0.5 {
                var zones = context
                zones.clip(
                    to: Path(
                        roundedRect: CGRect(
                            x: track.minX, y: levelY, width: track.width,
                            height: track.maxY - levelY),
                        cornerRadius: 2))
                let bands: [(from: Double, to: Double)] = [
                    (floor, Self.yellowFromDB), (Self.yellowFromDB, Self.redFromDB),
                    (Self.redFromDB, 0),
                ]
                for band in bands {
                    let top = y(band.to)
                    let bottom = y(band.from)
                    zones.fill(
                        Path(
                            CGRect(
                                x: track.minX, y: top, width: track.width,
                                height: bottom - top)),
                        with: .color(zoneColor(band.from)))
                }
            }

            // Peak-hold tick in the colour of the zone it sits in.
            if channel.peakDB > floor + 0.5 {
                let peakY = y(channel.peakDB)
                var tick = Path()
                tick.move(to: CGPoint(x: track.minX, y: peakY))
                tick.addLine(to: CGPoint(x: track.maxX, y: peakY))
                context.stroke(tick, with: .color(zoneColor(channel.peakDB)), lineWidth: 1.5)
            }

        }
    }
}
