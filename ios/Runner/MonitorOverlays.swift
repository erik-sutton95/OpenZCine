import CoreMotion
import SwiftUI

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
                            TrafficLightsMeterMini(
                                reading: model.scopeAssist.trafficLights)
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
    /// Metered playback audio (from the player item's processing tap); silent when the tool is off.
    var audioLevels: AudioMeterLevels = .silent

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
                        TrafficLightsMeterMini(reading: scopeAssist.trafficLights)
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
    /// Clean output mode (DISP 2) keeps the framing guides — which bound the de-squeeze — but drops
    /// the busier grid, crosshair and level.
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
                : model.preferences.liveViewVisibleAssistTools).subtracting(excludeTools)
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
                // The EV meter survives clean mode (DISP 2): exposure truth is exactly what
                // a stripped-down operator view still needs, like the framing guides.
                if visible.contains(.evMeter),
                    let sixths = model.cameraPropertySnapshot.evIndicatorSixths,
                    model.cameraPropertySnapshot.evIndicatorLit != false
                {
                    // Camera-fed exposure needle, seated bottom-centre of the feed. With the
                    // capture bar present it lifts above the band's lane; clean mode (DISP 2)
                    // has the bottom free, so it drops to the feed's edge.
                    EVMeterView(sixths: sixths)
                        .position(x: feed.midX, y: feed.maxY - (clean ? 28 : 92))
                        .allowsHitTesting(false)
                }
                if !clean {
                    if visible.contains(.grid) {
                        FeedGridView(grid: model.assistConfiguration.grid, feed: feed)
                    }
                    if visible.contains(.crosshair) {
                        FeedCrosshairView(feed: feed)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("False Color")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                Spacer()
                Text(
                    "\(scaleLabel) · \(mapping.curve == .redLog3G10 ? "L3G10" : "N-Log")"
                )
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
struct TrafficLightsMeterMini: View {
    let reading: TrafficLightsReading
    /// Portrait fit-mode stacks the scope full-width, so the 74:168 aspect-locked meter floats
    /// centred with dead horizontal space. When true, the three bars spread across the full width
    /// and grow wider to use it. Default false keeps the landscape floating panel (exact 74-box)
    /// pixel-identical.
    var fillsWidth: Bool = false

    private static let baseSize = CGSize(width: 74, height: 168)

    var body: some View {
        GeometryReader { proxy in
            let uiScale = min(
                proxy.size.width / Self.baseSize.width,
                proxy.size.height / Self.baseSize.height)
            // Fill mode: widen each bar off the available width (three bars sharing the row with a
            // gap each), capped so they don't get comically fat on very wide zones; else the
            // aspect-locked 11pt track.
            let columnWidth =
                fillsWidth
                ? min(44, max(11 * uiScale, (proxy.size.width - 16 * uiScale) / 6))
                : 11 * uiScale
            VStack(spacing: 6 * uiScale) {
                Text("TL")
                    .font(.system(size: 8.5 * uiScale, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.58))
                    .lineLimit(1)
                HStack(alignment: .bottom, spacing: 6 * uiScale) {
                    goalPost(
                        color: ScopePalette.rgba(255, 92, 82, 1), channel: reading.red,
                        uiScale: uiScale, columnWidth: columnWidth)
                    goalPost(
                        color: ScopePalette.rgba(86, 235, 132, 1), channel: reading.green,
                        uiScale: uiScale, columnWidth: columnWidth)
                    goalPost(
                        color: ScopePalette.rgba(96, 158, 255, 1), channel: reading.blue,
                        uiScale: uiScale, columnWidth: columnWidth)
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .padding(.horizontal, 8 * uiScale)
            .padding(.vertical, 8 * uiScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(red: 0.025, green: 0.036, blue: 0.03).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Traffic Lights")
        .accessibilityValue(trafficLightsAccessibilityValue)
    }

    private var trafficLightsAccessibilityValue: String {
        func channel(_ name: String, _ ch: TrafficLightsChannelReading) -> String {
            let display = TrafficLightsMeter.channelDisplay(for: ch)
            let lean =
                switch display.side {
                case .neutral: "balanced"
                case .over: "over"
                case .under: "under"
                }
            let flags = [ch.clip ? "clip" : nil, ch.crush ? "crush" : nil].compactMap { $0 }
            let flagSuffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            return "\(name) \(lean)\(flagSuffix)"
        }
        return [
            channel("red", reading.red), channel("green", reading.green),
            channel("blue", reading.blue),
        ]
        .joined(separator: ", ")
    }

    private func goalPost(
        color: Color, channel: TrafficLightsChannelReading, uiScale: CGFloat, columnWidth: CGFloat
    ) -> some View {
        let columnHeight = 108 * uiScale
        let indicatorSize = 8 * uiScale
        let display = TrafficLightsMeter.channelDisplay(for: channel)
        return VStack(spacing: 4 * uiScale) {
            trafficIndicator(
                color: color, active: channel.clip, size: indicatorSize, uiScale: uiScale)
            GeometryReader { proxy in
                let height = proxy.size.height
                let centerLineHeight = max(1, uiScale * 0.85)
                let halfHeight = (height - centerLineHeight) / 2
                let barHeight = halfHeight * CGFloat(display.barFill)
                let track = RoundedRectangle(cornerRadius: 2 * uiScale, style: .continuous)
                    .fill(LiveDesign.text.opacity(0.08))
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        track
                        if display.side == .over, barHeight > 0 {
                            goalPostFill(
                                color: color, height: max(1.5 * uiScale, barHeight),
                                uiScale: uiScale, towardClip: true)
                        }
                    }
                    .frame(height: halfHeight)
                    .clipped()
                    Rectangle()
                        .fill(LiveDesign.text.opacity(0.14))
                        .frame(height: centerLineHeight)
                    ZStack(alignment: .top) {
                        track
                        if display.side == .under, barHeight > 0 {
                            goalPostFill(
                                color: color, height: max(1.5 * uiScale, barHeight),
                                uiScale: uiScale, towardClip: false)
                        }
                    }
                    .frame(height: halfHeight)
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 2 * uiScale, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: display.barFill)
                .animation(.easeOut(duration: 0.12), value: display.side)
            }
            .frame(width: columnWidth, height: columnHeight)
            trafficIndicator(
                color: color, active: channel.crush, size: indicatorSize, uiScale: uiScale)
        }
        .frame(maxWidth: .infinity)
    }

    /// Single-sided level bar anchored at the centre line and growing toward clip or crush.
    private func goalPostFill(
        color: Color, height: CGFloat, uiScale: CGFloat, towardClip: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 2 * uiScale, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(0.35),
                        color.opacity(0.92),
                    ],
                    startPoint: towardClip ? .bottom : .top,
                    endPoint: towardClip ? .top : .bottom
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    private func trafficIndicator(color: Color, active: Bool, size: CGFloat, uiScale: CGFloat)
        -> some View
    {
        Circle()
            .fill(active ? color : Color.clear)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(
                        color.opacity(active ? 1 : 0.75), lineWidth: max(1, 1.5 * uiScale))
            )
            .shadow(color: active ? color.opacity(0.45) : .clear, radius: active ? 4 * uiScale : 0)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

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
            scopePlot
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
        .background(Color(red: 0.025, green: 0.036, blue: 0.03).opacity(0.72))
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

    @ViewBuilder private var scopePlot: some View {
        switch style {
        case .waveform:
            if ScopeTraceMetal.isAvailable {
                ZStack {
                    ScopeTraceMetalView(
                        samples: assist.samples, trail: assist.trailSamples,
                        mode: .waveform(scopes.waveformMode),
                        brightness: scopes.waveformBrightness, mapping: mapping)
                    ScopeGuideOverlay(guides: scopes.waveformGuides, mapping: mapping)
                }
            } else {
                WaveformScopePlot(
                    samples: assist.samples, trail: assist.trailSamples,
                    mode: scopes.waveformMode, guides: scopes.waveformGuides,
                    brightness: scopes.waveformBrightness, mapping: mapping
                )
                .equatable()
            }
        case .parade:
            if ScopeTraceMetal.isAvailable {
                ZStack {
                    ScopeTraceMetalView(
                        samples: assist.samples, trail: assist.trailSamples,
                        mode: .parade(scopes.paradeMode),
                        brightness: scopes.paradeBrightness, mapping: mapping)
                    ScopeGuideOverlay(guides: scopes.paradeGuides, mapping: mapping)
                }
            } else {
                ParadeScopePlot(
                    samples: assist.samples, trail: assist.trailSamples,
                    mode: scopes.paradeMode, guides: scopes.paradeGuides,
                    brightness: scopes.paradeBrightness, mapping: mapping
                )
                .equatable()
            }
        case .histogram:
            HistogramScopePlot(
                samples: assist.samples, trail: assist.trailSamples,
                trafficLights: scopes.histogramTrafficLights,
                crushClipCompensation: scopes.crushClipCompensation, mapping: mapping
            )
            // Skip the four-channel remap + smoothing redraw when the bins are unchanged —
            // the same guard the waveform/parade plots already carry.
            .equatable()
        case .vectorscope:
            if ScopeTraceMetal.isAvailable {
                ZStack {
                    Canvas { context, size in
                        let plot = scopePlotRect(size, top: 26)
                        let side = min(plot.width, plot.height)
                        let rect = CGRect(
                            x: plot.midX - side / 2, y: plot.midY - side / 2,
                            width: side, height: side)
                        drawVectorscopeGraticule(in: context, rect: rect)
                    }
                    VectorscopeMetalView(
                        points: assist.vectorscopePoints,
                        trailPoints: assist.trailVectorscopePoints,
                        zoom: scopes.vectorscopeZoom,
                        brightness: scopes.vectorscopeBrightness)
                }
            } else {
                VectorscopePlot(
                    points: assist.vectorscopePoints,
                    trailPoints: assist.trailVectorscopePoints,
                    zoom: scopes.vectorscopeZoom,
                    brightness: scopes.vectorscopeBrightness
                )
                .equatable()
            }
        }
    }
}

/// Additive data opacity (`brightness × dataOpacityBase`) and the waveform/parade trace colours.
/// Each colour bakes in its own alpha; the canvas multiplies by `dataOpacity(brightness:)` and
/// composites with `.plusLighter`. Trace cores are fully opaque (occupied signal reads at 100% at
/// default brightness); the low-alpha ghost keeps the soft scope-tube halo.
enum ScopePalette {
    static let dataOpacityBase = 1.0
    static func dataOpacity(brightness: Int) -> Double {
        dataOpacityBase
            * AssistConfiguration.Scopes.waveformParadeBrightnessMultiplier(brightness)
    }

    /// One trace colour consumed by BOTH renderers: the SwiftUI Canvas reference plots and the
    /// Metal rasterizer derive their output from the same component values, so the palettes can
    /// never drift apart. [pinned-look invariant]
    struct TraceColor {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        var color: Color {
            Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
        }

        /// Premultiplied RGBA for additive Metal blending — `plusLighter` over a transparent
        /// layer adds `rgb·alpha` per fill, so the fragment colour carries exactly that.
        func premultiplied(opacity: Double) -> SIMD4<Float> {
            let scale = Float(alpha * opacity)
            return SIMD4(
                Float(red / 255) * scale, Float(green / 255) * scale,
                Float(blue / 255) * scale, scale)
        }
    }

    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
    static func trace(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> TraceColor {
        TraceColor(red: r, green: g, blue: b, alpha: a)
    }
    // Waveform
    static let lumaGhost = trace(182, 190, 186, 0.08)
    static let luma = trace(222, 230, 224, 1.0)
    static let lumaHot = trace(255, 255, 255, 1.0)
    // Parade (separate lanes — no cross-channel overlap, so full opacity reads best)
    static let paradeRed = trace(255, 86, 78, 1.0)
    static let paradeGreen = trace(102, 232, 132, 1.0)
    static let paradeBlue = trace(92, 156, 255, 1.0)
    // RGB overlay waveform: the channels share one plot, so mid alpha keeps single-channel
    // excursions saturated while coincident (neutral) signal adds up toward white — full-alpha
    // channels would white-out everywhere on near-neutral log footage and read exactly like Luma.
    static let overlayRed = trace(255, 64, 54, 0.55)
    static let overlayGreen = trace(70, 240, 110, 0.55)
    static let overlayBlue = trace(72, 148, 255, 0.62)
    // Scope guides — boundary lines at 0/100 IRE; clip/crush safe borders inset from the edges.
    static let boundary = rgba(220, 235, 225, 0.8)
    static let clip = rgba(255, 150, 142, 0.8)
    static let middle = rgba(246, 241, 226, 0.8)
    // Histogram — lower fill alpha than the prototype so `.plusLighter` overlaps stay coloured.
    static let histogramRedFill = rgba(255, 48, 44, 0.17)
    static let histogramGreenFill = rgba(0, 238, 70, 0.15)
    static let histogramBlueFill = rgba(45, 76, 255, 0.19)
}

/// Reference-IRE level (0…1) to a y inside `rect`, with the prototype's 4% top/bottom buffer.
func scopeLevelY(_ level: Double, _ rect: CGRect) -> CGFloat {
    let buffered = 0.04 + level * (1 - 0.08)
    return rect.maxY - CGFloat(buffered) * rect.height
}

/// A signal code value (0…255) to its y in `rect` on the reference-IRE exposure axis.
func scopeValueY(
    _ value: Double, _ rect: CGRect, mapping: ExposureSignalMapping
) -> CGFloat {
    scopeLevelY(ScopeDisplayScale.waveformLevel(signalNative: value, mapping: mapping), rect)
}

func scopePlotRect(_ size: CGSize, top: CGFloat) -> CGRect {
    CGRect(x: 6, y: top, width: size.width - 12, height: size.height - top - 8)
}

/// Min/max native-code axis bounds (code 0 bottom, code 255 top) — always on for waveform/parade.
private func drawScopeBoundaryLines(in context: GraphicsContext, rect: CGRect) {
    let style = StrokeStyle(lineWidth: 1.25)
    for level in [0.0, 1.0] {
        let y = scopeLevelY(level, rect)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.stroke(path, with: .color(ScopePalette.boundary), style: style)
    }
}

/// Fixed safe-border lines — clip 5% from the top, crush 5% from the bottom (the signal is
/// stretched so its clip-warning and log-black codes land exactly on them) — plus the mid-grey
/// guide, which rides the same mapping as the trace.
private func drawScopeGuides(
    in context: GraphicsContext, rect: CGRect, guides: AssistConfiguration.Scopes.GuideLines,
    mapping: ExposureSignalMapping
) {
    let dashed = StrokeStyle(lineWidth: 1, dash: [4, 4])
    let solid = StrokeStyle(lineWidth: 1)

    func line(_ y: CGFloat, _ color: Color, _ style: StrokeStyle) {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.stroke(path, with: .color(color), style: style)
    }

    if guides.clip {
        line(scopeLevelY(ScopeDisplayScale.clipLineLevel, rect), ScopePalette.clip, dashed)
    }
    if guides.middle {
        line(
            scopeLevelY(ScopeDisplayScale.middleGrayLevel(mapping: mapping), rect),
            ScopePalette.middle, solid)
    }
    if guides.crush {
        line(scopeLevelY(ScopeDisplayScale.crushLineLevel, rect), ScopePalette.clip, dashed)
    }
}

/// Reference grid and safe-border guides composited above waveform/parade traces.
private struct ScopeGuideOverlay: View {
    var guides: AssistConfiguration.Scopes.GuideLines
    var mapping: ExposureSignalMapping

    var body: some View {
        Canvas { context, size in
            let rect = scopePlotRect(size, top: 26)
            drawScopeBoundaryLines(in: context, rect: rect)
            drawScopeGuides(in: context, rect: rect, guides: guides, mapping: mapping)
        }
        .allowsHitTesting(false)
    }
}

/// Luma waveform: one additive mark per sampled pixel — a 2px ghost, a 1px main dot, and a brighter
/// 1px highlight on every 4th sample — built up with `.plusLighter`, matching the prototype's
/// `drawTraditionalWaveformDensity`.
struct WaveformScopePlot: View, Equatable {
    let samples: ScopeSamples
    /// Previous tick, drawn first at decayed opacity — phosphor persistence between low-rate ticks.
    var trail: ScopeSamples = .empty
    var mode: AssistConfiguration.Scopes.WaveformMode = .luma
    var guides = AssistConfiguration.Scopes.GuideLines()
    var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
    var mapping = ExposureSignalMapping(curve: .redLog3G10)

    /// Opacity multiplier for the trail pass — low enough to read as decay, high enough to bridge.
    static let trailDecay = 0.35

    nonisolated static func == (lhs: WaveformScopePlot, rhs: WaveformScopePlot) -> Bool {
        lhs.samples == rhs.samples && lhs.trail == rhs.trail && lhs.mode == rhs.mode
            && lhs.guides == rhs.guides
            && lhs.brightness == rhs.brightness
            && lhs.mapping == rhs.mapping
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let rect = scopePlotRect(size, top: 26)
                let opacity = ScopePalette.dataOpacity(brightness: brightness)
                drawTrace(
                    trail.points, rect: rect, context: context, opacity: opacity * Self.trailDecay)
                drawTrace(samples.points, rect: rect, context: context, opacity: opacity)
            }
            ScopeGuideOverlay(guides: guides, mapping: mapping)
        }
    }

    private func drawTrace(
        _ points: [ScopePoint], rect: CGRect, context: GraphicsContext, opacity: Double
    ) {
        guard !points.isEmpty else { return }
        var ctx = context
        ctx.opacity = opacity
        ctx.blendMode = .plusLighter
        switch mode {
        case .luma:
            for (index, point) in points.enumerated() {
                let x = rect.minX + CGFloat(point.xRatio) * rect.width
                let y = scopeValueY(Double(point.luma), rect, mapping: mapping)
                ctx.fill(
                    Path(CGRect(x: x, y: y, width: 2, height: 2)),
                    with: .color(ScopePalette.lumaGhost.color)
                )
                ctx.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(ScopePalette.luma.color))
                if index % 4 == 0 {
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(ScopePalette.lumaHot.color))
                }
            }
        case .rgb:
            // Per-channel waveform: the three channels share the full-width plot (additive),
            // reading the same R/G/B the parade lanes use.
            let channels: [(Color, (ScopePoint) -> UInt8)] = [
                (ScopePalette.overlayRed.color, { $0.red }),
                (ScopePalette.overlayGreen.color, { $0.green }),
                (ScopePalette.overlayBlue.color, { $0.blue }),
            ]
            for point in points {
                let x = rect.minX + CGFloat(point.xRatio) * rect.width
                for channel in channels {
                    let y = scopeValueY(
                        Double(channel.1(point)), rect, mapping: mapping)
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(channel.0))
                }
            }
        }
    }
}

/// RGB parade: three additive lanes, each plotting one channel by reference-IRE level — the
/// prototype's `drawParadeDensity`.
struct ParadeScopePlot: View, Equatable {
    let samples: ScopeSamples
    /// Previous tick, drawn first at decayed opacity — phosphor persistence between low-rate ticks.
    var trail: ScopeSamples = .empty
    var mode: AssistConfiguration.Scopes.ParadeMode = .rgb
    var guides = AssistConfiguration.Scopes.GuideLines()
    var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
    var mapping = ExposureSignalMapping(curve: .redLog3G10)

    nonisolated static func == (lhs: ParadeScopePlot, rhs: ParadeScopePlot) -> Bool {
        lhs.samples == rhs.samples && lhs.trail == rhs.trail && lhs.mode == rhs.mode
            && lhs.guides == rhs.guides
            && lhs.brightness == rhs.brightness
            && lhs.mapping == rhs.mapping
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let rect = scopePlotRect(size, top: 26)
                let opacity = ScopePalette.dataOpacity(brightness: brightness)
                drawLanes(
                    trail.points, rect: rect, context: context,
                    opacity: opacity * WaveformScopePlot.trailDecay)
                drawLanes(samples.points, rect: rect, context: context, opacity: opacity)
            }
            ScopeGuideOverlay(guides: guides, mapping: mapping)
        }
    }

    private func drawLanes(
        _ points: [ScopePoint], rect: CGRect, context: GraphicsContext, opacity: Double
    ) {
        guard !points.isEmpty else { return }
        // YRGB prepends a luma lane to the three colour lanes; lane width follows the count.
        let lumaLane: [(Color, (ScopePoint) -> UInt8)] =
            mode == .yrgb ? [(ScopePalette.luma.color, { $0.luma })] : []
        let lanes: [(Color, (ScopePoint) -> UInt8)] =
            lumaLane + [
                (ScopePalette.paradeRed.color, { $0.red }),
                (ScopePalette.paradeGreen.color, { $0.green }),
                (ScopePalette.paradeBlue.color, { $0.blue }),
            ]
        let laneWidth = rect.width / CGFloat(lanes.count)
        var ctx = context
        ctx.opacity = opacity
        ctx.blendMode = .plusLighter
        for (index, lane) in lanes.enumerated() {
            let originX = rect.minX + CGFloat(index) * laneWidth
            for point in points {
                let x = originX + CGFloat(point.xRatio) * (laneWidth - 1)
                let y = scopeValueY(Double(lane.1(point)), rect, mapping: mapping)
                ctx.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(lane.0))
            }
        }
    }
}

/// Vectorscope: BT.709 CbCr chroma density plot with an industry-standard graticule — outer ring,
/// centre crosshair, the six 75% primary/secondary targets, and the I-phase skin-tone line at 123°.
/// `points` are monitor-domain (the clean samples through the operator's active look) — log codes
/// carry too little chroma spread to read; `zoom` magnifies only the trace, never the graticule.
/// The density image draws with a soft blur so the trace reads as smooth blobs, not pixels.
struct VectorscopePlot: View, Equatable {
    let points: [ScopePoint]
    /// Previous tick's monitor points — drawn at decayed opacity for phosphor persistence.
    var trailPoints: [ScopePoint] = []
    var zoom: AssistConfiguration.Scopes.VectorscopeZoom = .x1
    var brightness: Int = AssistConfiguration.Scopes.defaultBrightness

    nonisolated static func == (lhs: VectorscopePlot, rhs: VectorscopePlot) -> Bool {
        lhs.points == rhs.points && lhs.trailPoints == rhs.trailPoints && lhs.zoom == rhs.zoom
            && lhs.brightness == rhs.brightness
    }

    /// 128 bins per chroma axis — plenty for a ≤250pt panel (task-standard density resolution).
    private static let binCount = 128

    var body: some View {
        Canvas { context, size in
            let plot = scopePlotRect(size, top: 26)
            let side = min(plot.width, plot.height)
            let rect = CGRect(
                x: plot.midX - side / 2, y: plot.midY - side / 2, width: side, height: side)
            drawVectorscopeGraticule(in: context, rect: rect)
            if !trailPoints.isEmpty {
                let trailBins = VectorscopeSampler.accumulate(
                    points: trailPoints, binCount: Self.binCount, gain: zoom.gain)
                if let image = Self.densityImage(bins: trailBins, brightness: brightness) {
                    var ghost = context
                    ghost.blendMode = .plusLighter
                    ghost.opacity = WaveformScopePlot.trailDecay
                    ghost.addFilter(.blur(radius: side / CGFloat(Self.binCount) * 1.1))
                    ghost.draw(Image(decorative: image, scale: 1), in: rect)
                }
            }
            let bins = VectorscopeSampler.accumulate(
                points: points, binCount: Self.binCount, gain: zoom.gain)
            if let image = Self.densityImage(bins: bins, brightness: brightness) {
                // Soft blob rendering: a blur of roughly one bin width melts isolated pixels into
                // the smooth density clouds broadcast vectorscopes draw; a second unblurred pass
                // at low opacity keeps a crisp core so small saturated features stay locatable.
                var ctx = context
                ctx.blendMode = .plusLighter
                ctx.addFilter(.blur(radius: side / CGFloat(Self.binCount) * 1.1))
                ctx.draw(Image(decorative: image, scale: 1), in: rect)
                var crisp = context
                crisp.blendMode = .plusLighter
                crisp.opacity = 0.35
                crisp.draw(Image(decorative: image, scale: 1), in: rect)
            }
        }
    }

    /// Bins → a small premultiplied-RGBA `CGImage`; density drives alpha while each occupied bin
    /// retains the average sampled hue. 128×128 RGBA (64 KB) per scope tick — cheaper than
    /// per-point Canvas fills.
    private static func densityImage(bins: VectorscopeBins, brightness: Int) -> CGImage? {
        let n = bins.binCount
        guard
            let pixels = VectorscopeDensityRasterizer.premultipliedRGBA(
                bins: bins, brightness: brightness)
        else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Pure bins-to-pixels stage kept separate from SwiftUI/CGImage so channel order, premultiplication,
/// brightness, and the +Cr vertical flip can be tested directly.
enum VectorscopeDensityRasterizer {
    static func premultipliedRGBA(
        bins: VectorscopeBins, brightness: Int
    ) -> [UInt8]? {
        let n = bins.binCount
        guard n > 0, bins.peak > 0 else { return nil }
        let gain = AssistConfiguration.Scopes.brightnessMultiplier(brightness)
        let peak = Double(bins.peak)
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for index in 0..<bins.counts.count {
            let count = bins.counts[index]
            guard count > 0 else { continue }
            // Logarithmic density ramp (phosphor-style): a peak-relative sqrt lets one hot neutral
            // bin crush sparse chroma excursions to near-invisibility; log keeps single-pixel
            // chroma readable while dense regions still glow.
            let density = log(1 + Double(count)) / log(1 + peak)
            let alpha = min(1, max(0, (0.4 + 0.6 * density) * gain))
            let tint = bins.averageColor(at: index).traceTint
            // Flip rows so +Cr renders upward (bins store row 0 at the most negative Cr).
            let row = n - 1 - index / n
            let column = index % n
            let offset = (row * n + column) * 4
            pixels[offset] = UInt8(255 * tint.red * alpha)
            pixels[offset + 1] = UInt8(255 * tint.green * alpha)
            pixels[offset + 2] = UInt8(255 * tint.blue * alpha)
            pixels[offset + 3] = UInt8(255 * alpha)
        }
        return pixels
    }
}

/// Vectorscope graticule: outer ring at maximum chroma magnitude, centre crosshair, 75% colour-bar
/// targets, and the dashed skin-tone line. Target positions come from `VectorscopeSampler.chroma`
/// on the 75% bar code values, so trace and graticule can never disagree about the matrix.
func drawVectorscopeGraticule(in context: GraphicsContext, rect: CGRect) {
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width / 2
    let faint = ScopePalette.rgba(220, 235, 225, 0.30)

    context.stroke(
        Path(ellipseIn: rect), with: .color(ScopePalette.rgba(220, 235, 225, 0.55)),
        lineWidth: 1.25)

    var cross = Path()
    cross.move(to: CGPoint(x: centre.x - 8, y: centre.y))
    cross.addLine(to: CGPoint(x: centre.x + 8, y: centre.y))
    cross.move(to: CGPoint(x: centre.x, y: centre.y - 8))
    cross.addLine(to: CGPoint(x: centre.x, y: centre.y + 8))
    context.stroke(cross, with: .color(faint), lineWidth: 1)

    // Skin-tone (I-phase) line at 123° from the +Cb axis, toward the Yl–R sector.
    let skinAngle = 123.0 * Double.pi / 180
    var skin = Path()
    skin.move(to: centre)
    skin.addLine(
        to: CGPoint(
            x: centre.x + CGFloat(cos(skinAngle)) * radius * 0.92,
            y: centre.y - CGFloat(sin(skinAngle)) * radius * 0.92))
    context.stroke(
        skin, with: .color(ScopePalette.middle), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

    // 75% primary/secondary targets (191 = 0.75 × 255).
    let targets: [(label: String, red: UInt8, green: UInt8, blue: UInt8)] = [
        ("R", 191, 0, 0), ("Mg", 191, 0, 191), ("B", 0, 0, 191),
        ("Cy", 0, 191, 191), ("G", 0, 191, 0), ("Yl", 191, 191, 0),
    ]
    for target in targets {
        let (cb, cr) = VectorscopeSampler.chroma(
            red: target.red, green: target.green, blue: target.blue)
        let point = CGPoint(
            x: centre.x + CGFloat(cb) * rect.width,
            y: centre.y - CGFloat(cr) * rect.height)
        let boxSide: CGFloat = 7
        let box = CGRect(
            x: point.x - boxSide / 2, y: point.y - boxSide / 2, width: boxSide, height: boxSide)
        context.stroke(
            Path(box), with: .color(ScopePalette.rgba(220, 235, 225, 0.6)), lineWidth: 1)
        // Label pushed away from centre so it clears the box on any panel size.
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        context.draw(
            Text(target.label)
                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                .foregroundStyle(ScopePalette.rgba(220, 235, 225, 0.55)),
            at: CGPoint(x: point.x + dx / length * 10, y: point.y + dy / length * 10))
    }
}

/// RGB + luma histogram: smooth additive R/G/B fills on the reference-IRE axis, stroked channel
/// traces, then a dim luma outline only (no luma fill — that caused the mid-tone white slab).
struct HistogramScopePlot: View, Equatable {
    let samples: ScopeSamples
    /// Previous tick, blended into the display bins — temporal smoothing between low-rate ticks.
    var trail: ScopeSamples = .empty
    var trafficLights: Bool = true
    var crushClipCompensation: AssistConfiguration.CrushClipCompensation = .one
    var mapping = ExposureSignalMapping(curve: .redLog3G10)

    nonisolated static func == (lhs: HistogramScopePlot, rhs: HistogramScopePlot) -> Bool {
        lhs.samples == rhs.samples && lhs.trail == rhs.trail
            && lhs.trafficLights == rhs.trafficLights
            && lhs.crushClipCompensation == rhs.crushClipCompensation
            && lhs.mapping == rhs.mapping
    }

    /// `0.65·current + 0.35·previous` — one-tap temporal blend on the display bins.
    private func blended(_ current: [Double], _ previous: [Double]) -> [Double] {
        guard previous.count == current.count, !trail.histogramLuma.isEmpty else { return current }
        var out = current
        for index in out.indices {
            out[index] = out[index] * 0.65 + previous[index] * 0.35
        }
        return out
    }

    var body: some View {
        let threshold = crushClipCompensation.pixelFractionThreshold
        let lights: HistogramTrafficLights? =
            trafficLights
            ? ScopeSampler.trafficLights(
                red: samples.histogramRed, green: samples.histogramGreen,
                blue: samples.histogramBlue, mapping: mapping, threshold: threshold)
            : nil
        ZStack {
            Canvas { context, size in
                // Inset the curves so they clear the traffic-light columns on each side.
                let rect = CGRect(
                    x: 26, y: 22, width: size.width - 52, height: size.height - 30)
                let red = blended(
                    ScopeDisplayScale.remapHistogram(samples.histogramRed, mapping: mapping),
                    ScopeDisplayScale.remapHistogram(trail.histogramRed, mapping: mapping))
                let green = blended(
                    ScopeDisplayScale.remapHistogram(samples.histogramGreen, mapping: mapping),
                    ScopeDisplayScale.remapHistogram(trail.histogramGreen, mapping: mapping))
                let blue = blended(
                    ScopeDisplayScale.remapHistogram(samples.histogramBlue, mapping: mapping),
                    ScopeDisplayScale.remapHistogram(trail.histogramBlue, mapping: mapping))
                let luma = blended(
                    ScopeDisplayScale.remapHistogram(samples.histogramLuma, mapping: mapping),
                    ScopeDisplayScale.remapHistogram(trail.histogramLuma, mapping: mapping))
                let peak = max(
                    red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0, luma.max() ?? 0, 1)

                drawHistogramReferenceGrid(in: context, rect: rect)
                drawHistogramClipZone(in: context, rect: rect, lights: lights)
                drawHistogramBoundaries(in: context, rect: rect)

                let displayRed = smoothHistogramBinsForDisplay(red)
                let displayGreen = smoothHistogramBinsForDisplay(green)
                let displayBlue = smoothHistogramBinsForDisplay(blue)
                let displayLuma = smoothHistogramBinsForDisplay(luma)

                var additive = context
                additive.opacity = 0.92
                additive.blendMode = .plusLighter
                drawHistogramChannel(
                    in: additive, bins: displayRed, rect: rect, peak: peak,
                    fill: ScopePalette.histogramRedFill,
                    stroke: ScopePalette.rgba(255, 48, 44, 0.96))
                drawHistogramChannel(
                    in: additive, bins: displayGreen, rect: rect, peak: peak,
                    fill: ScopePalette.histogramGreenFill,
                    stroke: ScopePalette.rgba(0, 238, 70, 0.92))
                drawHistogramChannel(
                    in: additive, bins: displayBlue, rect: rect, peak: peak,
                    fill: ScopePalette.histogramBlueFill,
                    stroke: ScopePalette.rgba(45, 76, 255, 0.94))

                var lumaContext = context
                lumaContext.opacity = 0.58
                drawHistogramLumaStroke(
                    in: lumaContext, bins: displayLuma, rect: rect, peak: peak,
                    stroke: ScopePalette.rgba(245, 242, 232, 0.58))
            }
            // Traffic lights: crushed channels on the left, clipped channels on the right.
            if let lights {
                HStack {
                    trafficColumn(
                        red: lights.crushRed, green: lights.crushGreen, blue: lights.crushBlue)
                    Spacer()
                    trafficColumn(
                        red: lights.clipRed, green: lights.clipGreen, blue: lights.clipBlue)
                }
                .padding(.horizontal, 11)
                // Sit the columns just below the HISTO / RGBL title row (nudged up to hug it).
                .padding(.top, 12)
            }
        }
    }

    private func trafficColumn(red: Bool, green: Bool, blue: Bool) -> some View {
        VStack(spacing: 3) {
            trafficBlock(ScopePalette.rgba(255, 92, 82, 1), hot: red)
            trafficBlock(ScopePalette.rgba(86, 235, 132, 1), hot: green)
            trafficBlock(ScopePalette.rgba(96, 158, 255, 1), hot: blue)
        }
    }

    private func trafficBlock(_ color: Color, hot: Bool) -> some View {
        // Normal: a hollow outline in the channel colour. Clipped/crushed: the block fills in and
        // glows so a blown channel reads at a glance.
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(hot ? color : Color.clear)
            .frame(width: 7.5, height: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(color.opacity(hot ? 1 : 0.8), lineWidth: 1.5)
            )
            .shadow(color: hot ? color.opacity(0.45) : .clear, radius: hot ? 5 : 0)
            .animation(.easeOut(duration: 0.15), value: hot)
    }
}

/// Faint horizontal quarter-lines behind the histogram (prototype `drawHistogramReferenceGrid`).
private func drawHistogramReferenceGrid(in context: GraphicsContext, rect: CGRect) {
    for step in 1..<4 {
        let y = rect.minY + rect.height * CGFloat(step) / 4
        var line = Path()
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.stroke(line, with: .color(ScopePalette.rgba(220, 235, 225, 0.06)), lineWidth: 1)
    }
}

/// Reference IRE (0…100) to an x inside the histogram plot rect.
private func histogramReferenceX(_ referenceIRE: Double, _ rect: CGRect) -> CGFloat {
    let ire = min(100, max(0, referenceIRE))
    return rect.minX + CGFloat(ire / 100) * rect.width
}

/// Narrow clip band on the right only when a traffic light trips.
private func drawHistogramClipZone(
    in context: GraphicsContext, rect: CGRect, lights: HistogramTrafficLights?
) {
    guard let lights, lights.clipRed || lights.clipGreen || lights.clipBlue else { return }
    let clipStart = histogramReferenceX(95, rect)
    var clip = Path()
    clip.addRect(
        CGRect(x: clipStart, y: rect.minY, width: rect.maxX - clipStart, height: rect.height))
    context.fill(clip, with: .color(ScopePalette.clip.opacity(0.14)))
}

/// The histogram's min (left / 0 IRE) and max (right / 100 IRE) boundary lines.
private func drawHistogramBoundaries(in context: GraphicsContext, rect: CGRect) {
    let color = ScopePalette.rgba(220, 235, 225, 0.8)
    for x in [rect.minX, rect.maxX] {
        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY))
        line.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.stroke(line, with: .color(color), lineWidth: 1.25)
    }
}

/// Light 3-tap box blur so remapped bins read as a continuous curve instead of a comb.
private func smoothHistogramBinsForDisplay(_ bins: [Double], radius: Int = 2) -> [Double] {
    guard bins.count == 256, radius > 0 else { return bins }
    var smoothed = bins
    for index in 0..<256 {
        let lower = max(0, index - radius)
        let upper = min(255, index + radius)
        let span = upper - lower + 1
        var sum = 0.0
        for sample in lower...upper { sum += bins[sample] }
        smoothed[index] = sum / Double(span)
    }
    return smoothed
}

/// Closed fill and open stroke paths along a smoothed histogram contour (quadratic midpoints).
private func histogramPaths(bins: [Double], rect: CGRect, peak: Double) -> (
    fill: Path, stroke: Path
) {
    guard bins.count == 256, peak > 0 else { return (Path(), Path()) }

    func point(at index: Int) -> CGPoint {
        let x = rect.minX + CGFloat(index) / 255 * rect.width
        let height = CGFloat(bins[index] / peak) * rect.height
        return CGPoint(x: x, y: rect.maxY - height)
    }

    var fill = Path()
    fill.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    fill.addLine(to: point(at: 0))

    var stroke = Path()
    stroke.move(to: point(at: 0))

    for index in 1..<256 {
        let previous = point(at: index - 1)
        let current = point(at: index)
        let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
        fill.addQuadCurve(to: midpoint, control: previous)
        stroke.addQuadCurve(to: midpoint, control: previous)
    }

    let last = point(at: 255)
    let penultimate = point(at: 254)
    fill.addQuadCurve(to: last, control: penultimate)
    stroke.addQuadCurve(to: last, control: penultimate)

    fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    fill.closeSubpath()
    return (fill, stroke)
}

/// Fills and strokes one RGB histogram channel with a smooth Lightroom-style contour.
private func drawHistogramChannel(
    in context: GraphicsContext, bins: [Double], rect: CGRect, peak: Double, fill: Color,
    stroke: Color
) {
    let paths = histogramPaths(bins: bins, rect: rect, peak: peak)
    context.fill(paths.fill, with: .color(fill))
    context.stroke(
        paths.stroke, with: .color(stroke),
        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
}

/// Luma outline only — no area fill, which previously washed mid-tones to white.
private func drawHistogramLumaStroke(
    in context: GraphicsContext, bins: [Double], rect: CGRect, peak: Double, stroke: Color
) {
    let paths = histogramPaths(bins: bins, rect: rect, peak: peak)
    context.stroke(
        paths.stroke, with: .color(stroke),
        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
}

/// Compact broadcast-style stereo meters: two vertical bars with green→yellow→red zones (yellow
/// from −18 dBFS, red from −6), a peak-hold tick per channel, and the camera sensitivity beneath.
/// Playback feeds it from the player item's audio tap; live view from the camera's own sound
/// indicator in the LiveViewObject header (bytes 824–827, already peak-held by the body).
struct AudioMetersPanelMini: View {
    /// Slim on purpose: two readable tracks without competing with the picture or the
    /// camera-control rails in the ~400 pt landscape monitor.
    static let panelSize = CGSize(width: 28, height: 168)

    let levels: AudioMeterLevels
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
        func channel(_ name: String, _ ch: AudioMeterChannel) -> String {
            ch.levelDB <= AudioMeterBallistics.floorDB + 0.5
                ? "\(name) silent"
                : String(format: "%@ %.0f dB, peak %.0f", name, ch.levelDB, ch.peakDB)
        }
        return
            "\(channel("left", levels.left)), \(channel("right", levels.right)), sensitivity \(Self.displayedSensitivity(sensitivity))"
    }

    private func zoneColor(_ db: Double) -> Color {
        if db >= Self.redFromDB { return ScopePalette.rgba(255, 92, 82, 0.95) }
        if db >= Self.yellowFromDB { return ScopePalette.rgba(245, 208, 82, 0.95) }
        return ScopePalette.rgba(86, 235, 132, 0.9)
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
                line, with: .color(ScopePalette.rgba(220, 235, 225, 0.10)), lineWidth: 1)
        }

        let gap: CGFloat = 2
        let inset: CGFloat = 1
        let barWidth = (barsRect.width - gap - inset * 2) / 2
        for (index, pair) in [("L", levels.left), ("R", levels.right)].enumerated() {
            let x = barsRect.minX + inset + CGFloat(index) * (barWidth + gap)
            let track = CGRect(
                x: x, y: barsRect.minY, width: barWidth, height: barsRect.height)
            context.fill(
                Path(roundedRect: track, cornerRadius: 2),
                with: .color(LiveDesign.text.opacity(0.08)))

            // Zone-coloured fill clipped to the decaying bar level.
            let levelY = y(pair.1.levelDB)
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
            if pair.1.peakDB > floor + 0.5 {
                let peakY = y(pair.1.peakDB)
                var tick = Path()
                tick.move(to: CGPoint(x: track.minX, y: peakY))
                tick.addLine(to: CGPoint(x: track.maxX, y: peakY))
                context.stroke(tick, with: .color(zoneColor(pair.1.peakDB)), lineWidth: 1.5)
            }

            context.draw(
                Text(pair.0)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text.opacity(0.58)),
                at: CGPoint(x: track.midX, y: size.height - labelReserve / 2))
        }
    }
}
