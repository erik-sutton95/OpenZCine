import MetalKit
import MetalPerformanceShaders
import SwiftUI
import UIKit

/// GPU rasterizer for the waveform and parade point traces — the pinned-look replacement for the
/// Canvas point-fill loops, which issued tens of thousands of individual `Path` fills per redraw
/// and dominated scope CPU cost (and device heat).
///
/// **Pinned-look invariant:** this renderer changes *where* the pixels are computed, never *what*
/// they are. It consumes the SAME shared sampled points and trail, computes each dot's position
/// with the SAME `scopePlotRect`/`scopeValueY` axis math on the CPU, colours it from the SAME
/// `ScopePalette.TraceColor` components, at the SAME point sizes (2pt ghost, 1pt core), and blends
/// additively exactly like `.plusLighter` over a transparent layer (premultiplied one/one). Both
/// live view and playback use it unconditionally; the Canvas plots remain as the reference
/// implementation, selected only if the Metal pipeline cannot be built, and as the baseline for
/// pixel-diff regression checks (`ZC_DEMO_CANVAS_SCOPES=1`).
enum ScopeTraceMetal {
    /// The trace kind to rasterize — mirrors the Canvas plots' modes.
    enum Mode: Equatable {
        case waveform(AssistConfiguration.Scopes.WaveformMode)
        case parade(AssistConfiguration.Scopes.ParadeMode)
    }

    /// One additive dot: origin-anchored position in panel points (matching `CGRect(x:y:w:h:)`
    /// fills), square side in points, premultiplied colour.
    struct Vertex {
        var position: SIMD2<Float>
        var size: Float
        var color: SIMD4<Float>
    }

    /// Renderer availability — when false (no Metal device / pipeline build failure), panels fall
    /// back to the Canvas reference plots, which produce the same pixels by construction.
    static let isAvailable: Bool =
        !DemoHarness.canvasScopes && ScopeTraceRenderer.sharedPipeline != nil

    /// Builds the dot list for one trace pass. `opacity` folds the brightness multiplier and the
    /// phosphor-trail decay into the premultiplied colours, exactly like `ctx.opacity` did.
    static func vertices(
        into out: inout [Vertex],
        points: [ScopePoint], mode: Mode, rect: CGRect,
        mapping: ExposureSignalMapping, opacity: Double
    ) {
        guard !points.isEmpty, opacity > 0 else { return }

        func level(_ native: UInt8) -> CGFloat {
            scopeValueY(Double(native), rect, mapping: mapping)
        }

        switch mode {
        case .waveform(let waveformMode):
            switch waveformMode {
            case .luma:
                let ghost = ScopePalette.lumaGhost.premultiplied(opacity: opacity)
                let core = ScopePalette.luma.premultiplied(opacity: opacity)
                let hot = ScopePalette.lumaHot.premultiplied(opacity: opacity)
                for (index, point) in points.enumerated() {
                    let x = Float(rect.minX + CGFloat(point.xRatio) * rect.width)
                    let y = Float(level(point.luma))
                    out.append(Vertex(position: SIMD2(x, y), size: 2, color: ghost))
                    out.append(Vertex(position: SIMD2(x, y), size: 1, color: core))
                    if index % 4 == 0 {
                        out.append(Vertex(position: SIMD2(x, y), size: 1, color: hot))
                    }
                }
            case .rgb:
                let channels: [(SIMD4<Float>, (ScopePoint) -> UInt8)] = [
                    (ScopePalette.overlayRed.premultiplied(opacity: opacity), { $0.red }),
                    (ScopePalette.overlayGreen.premultiplied(opacity: opacity), { $0.green }),
                    (ScopePalette.overlayBlue.premultiplied(opacity: opacity), { $0.blue }),
                ]
                for point in points {
                    let x = Float(rect.minX + CGFloat(point.xRatio) * rect.width)
                    for channel in channels {
                        out.append(
                            Vertex(
                                position: SIMD2(x, Float(level(channel.1(point)))),
                                size: 1, color: channel.0))
                    }
                }
            }
        case .parade(let paradeMode):
            let lumaLane: [(SIMD4<Float>, (ScopePoint) -> UInt8)] =
                paradeMode == .yrgb
                ? [(ScopePalette.luma.premultiplied(opacity: opacity), { $0.luma })] : []
            let lanes: [(SIMD4<Float>, (ScopePoint) -> UInt8)] =
                lumaLane + [
                    (ScopePalette.paradeRed.premultiplied(opacity: opacity), { $0.red }),
                    (ScopePalette.paradeGreen.premultiplied(opacity: opacity), { $0.green }),
                    (ScopePalette.paradeBlue.premultiplied(opacity: opacity), { $0.blue }),
                ]
            let laneWidth = rect.width / CGFloat(lanes.count)
            for (index, lane) in lanes.enumerated() {
                let originX = rect.minX + CGFloat(index) * laneWidth
                for point in points {
                    let x = Float(originX + CGFloat(point.xRatio) * (laneWidth - 1))
                    out.append(
                        Vertex(
                            position: SIMD2(x, Float(level(lane.1(point)))),
                            size: 1, color: lane.0))
                }
            }
        }
    }
}

/// The SwiftUI face of the Metal trace rasterizer. Sits inside the same `ZStack` slot the Canvas
/// plot occupied; `ScopeGuideOverlay` still draws the guides above it, unchanged.
struct ScopeTraceMetalView: UIViewRepresentable {
    let samples: ScopeSamples
    var trail: ScopeSamples = .empty
    let mode: ScopeTraceMetal.Mode
    var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
    var mapping = ExposureSignalMapping(curve: .redLog3G10)

    func makeCoordinator() -> ScopeTraceRenderer { ScopeTraceRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        // Push model: redraw only when a new bundle arrives (~10 Hz), never on a display timer.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        push(into: context.coordinator, view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        push(into: context.coordinator, view: uiView)
    }

    /// The renderer needs the panel bounds to place points, and only the main thread may read them
    /// off the view — so they are captured here and handed over with the data.
    private func push(into renderer: ScopeTraceRenderer, view: MTKView) {
        renderer.update(
            samples: samples, trail: trail, mode: mode, brightness: brightness, mapping: mapping,
            bounds: view.bounds.size, view: view)
    }
}

/// MTKView delegate: draws a prebuilt dot list in one additive pass.
///
/// The dot list is built OFF the main thread. Generating it was measured at 23% of the main thread
/// on an iPhone 16 Pro Max — thirteen times the cost of rendering the camera feed itself, and the
/// reason enabling a waveform took the app from 60 fps to 5. It is pure arithmetic over value
/// types, so it has no business being there: `update` captures the inputs, a serial queue turns
/// them into vertices, and `draw(in:)` is left with an upload and a draw call.
///
/// The overlay can therefore be one bundle behind for a few milliseconds. At the ~10 Hz the scopes
/// publish, against a feed that now runs at 60, that is not observable — and the alternative was a
/// feed that ran at 5.
/// `@MainActor` because `MTKViewDelegate`'s methods are `NS_SWIFT_UI_ACTOR` and every stored
/// property here is touched only from them or from `updateUIView`. It is also what makes the class
/// `Sendable`, so the build hop below may capture `self` at all — without it, Swift 6 rejects the
/// capture as sending a non-`Sendable` value across a concurrency boundary. The work that must NOT
/// be main-actor bound is marked `nonisolated`.
@MainActor
final class ScopeTraceRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    /// Everything one build depends on. Equatable so a rebuild is only scheduled on a real change.
    private struct BuildInputs: Equatable {
        var samples: ScopeSamples = .empty
        var trail: ScopeSamples = .empty
        var mode: ScopeTraceMetal.Mode = .waveform(.luma)
        var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
        var mapping = ExposureSignalMapping(curve: .redLog3G10)
        var bounds: CGSize = .zero
    }

    private var inputs = BuildInputs()
    /// Written on the build queue's completion hop, read in `draw(in:)` — both on the main thread.
    private var vertices: [ScopeTraceMetal.Vertex] = []
    private var buildGeneration = 0
    private let buildQueue = DispatchQueue(
        label: "OpenZCine.scope-trace-vertices", qos: .userInitiated)
    /// Triple-buffered vertex storage — `setVertexBytes` caps at 4 KB, and a single buffer could
    /// still be read by the GPU while the CPU writes the next tick.
    private var vertexBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var vertexBufferIndex = 0

    override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        pipeline = Self.sharedPipeline
        super.init()
    }

    /// Stores the latest trace inputs and schedules an off-main rebuild if anything changed.
    func update(
        samples: ScopeSamples, trail: ScopeSamples, mode: ScopeTraceMetal.Mode,
        brightness: Int, mapping: ExposureSignalMapping, bounds: CGSize, view: MTKView
    ) {
        let next = BuildInputs(
            samples: samples, trail: trail, mode: mode, brightness: brightness, mapping: mapping,
            bounds: bounds)
        guard next != inputs else { return }
        inputs = next
        scheduleBuild(view: view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Positions are in panel points, so a resize invalidates the geometry even though the data
        // is unchanged. `bounds` is not settled yet here; the follow-up `updateUIView` supplies it.
        scheduleBuild(view: view)
    }

    private func scheduleBuild(view: MTKView) {
        buildGeneration += 1
        let generation = buildGeneration
        let inputs = inputs
        buildQueue.async { [weak self, weak view] in
            let built = Self.build(inputs)
            DispatchQueue.main.async {
                // `DispatchQueue.main` IS the main actor; `assumeIsolated` states that rather than
                // paying for a `Task` hop, which would also lose the serial queue's ordering.
                MainActor.assumeIsolated {
                    guard let self, self.buildGeneration == generation else { return }
                    self.vertices = built
                    view?.setNeedsDisplay()
                }
            }
        }
    }

    /// Pure: inputs in, dot list out. Returns a fresh array rather than filling one in place —
    /// appending into a stored property through `inout` is a read-modify-write on a multi-megabyte
    /// buffer, which can copy the whole thing on every call.
    nonisolated private static func build(_ inputs: BuildInputs) -> [ScopeTraceMetal.Vertex] {
        let bounds = inputs.bounds
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        var out: [ScopeTraceMetal.Vertex] = []
        out.reserveCapacity((inputs.samples.points.count + inputs.trail.points.count) * 3)
        // Positions are computed in panel POINTS with the same axis math as the Canvas plots;
        // the shader scales by the drawable's screen scale.
        let rect = scopePlotRect(bounds, top: 26)
        let opacity = ScopePalette.dataOpacity(brightness: inputs.brightness)
        ScopeTraceMetal.vertices(
            into: &out, points: inputs.trail.points, mode: inputs.mode, rect: rect,
            mapping: inputs.mapping, opacity: opacity * WaveformScopePlot.trailDecay)
        ScopeTraceMetal.vertices(
            into: &out, points: inputs.samples.points, mode: inputs.mode, rect: rect,
            mapping: inputs.mapping, opacity: opacity)
        return out
    }

    func draw(in view: MTKView) {
        guard let pipeline, let queue,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let command = queue.makeCommandBuffer()
        else { return }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        if !vertices.isEmpty, let device,
            let vertexBuffer = nextVertexBuffer(device: device)
        {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            var viewSize = SIMD2<Float>(
                Float(view.drawableSize.width), Float(view.drawableSize.height))
            encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            var scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
            encoder.setVertexBytes(&scale, length: MemoryLayout<Float>.size, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// Copies the current vertex list into the next ring slot, growing it as needed.
    private func nextVertexBuffer(device: MTLDevice) -> MTLBuffer? {
        let length = vertices.count * MemoryLayout<ScopeTraceMetal.Vertex>.stride
        vertexBufferIndex = (vertexBufferIndex + 1) % vertexBuffers.count
        if vertexBuffers[vertexBufferIndex]?.length ?? 0 < length {
            vertexBuffers[vertexBufferIndex] = device.makeBuffer(
                length: max(length, 64 * 1024), options: .storageModeShared)
        }
        guard let buffer = vertexBuffers[vertexBufferIndex] else { return nil }
        vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                buffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
        return buffer
    }

    /// One pipeline for every panel — compiled once from source (no `.metal` file to register).
    /// Additive one/one blending reproduces `.plusLighter` over the transparent layer.
    nonisolated static let sharedPipeline: MTLRenderPipelineState? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct TraceVertex { float2 position; float size; float4 color; };
            struct VOut { float4 position [[position]]; float size [[point_size]]; float4 color; };
            vertex VOut trace_v(uint vid [[vertex_id]],
                                const device TraceVertex *vertices [[buffer(0)]],
                                constant float2 &viewSize [[buffer(1)]],
                                constant float &scale [[buffer(2)]]) {
                TraceVertex v = vertices[vid];
                // Origin-anchored rect -> centre, matching CGRect(x:y:width:height) fills.
                float2 centerPx = (v.position + v.size * 0.5) * scale;
                VOut o;
                o.position = float4(
                    centerPx.x / viewSize.x * 2.0 - 1.0,
                    1.0 - centerPx.y / viewSize.y * 2.0, 0.0, 1.0);
                o.size = v.size * scale;
                o.color = v.color;
                return o;
            }
            fragment float4 trace_f(VOut in [[stage_in]]) { return in.color; }
            """
        guard let library = try? device.makeLibrary(source: source, options: nil),
            let vertexFunction = library.makeFunction(name: "trace_v"),
            let fragmentFunction = library.makeFunction(name: "trace_f")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .bgra8Unorm
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()
}

// MARK: - Vectorscope density on the GPU

/// GPU compositor for the vectorscope density trace. The pixel TRUTH stays on the CPU —
/// `VectorscopeSampler.accumulate` bins and `VectorscopeDensityRasterizer` builds the exact same
/// 128×128 premultiplied density image the Canvas plot drew — but the per-tick `CGImage` creation,
/// the upscale, the soft-blob Gaussian blur, and the additive ghost/main/crisp compositing all
/// move to Metal. The graticule stays as the Canvas overlay above. [pinned-look invariant]
struct VectorscopeMetalView: UIViewRepresentable {
    let points: [ScopePoint]
    var trailPoints: [ScopePoint] = []
    var zoom: AssistConfiguration.Scopes.VectorscopeZoom = .x1
    var brightness: Int = AssistConfiguration.Scopes.defaultBrightness

    func makeCoordinator() -> VectorscopeMetalRenderer { VectorscopeMetalRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = false  // MPS blur writes into an intermediate; drawable stays FBO.
        push(into: context.coordinator, view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        push(into: context.coordinator, view: uiView)
    }

    private func push(into renderer: VectorscopeMetalRenderer, view: MTKView) {
        renderer.update(
            points: points, trailPoints: trailPoints, zoom: zoom, brightness: brightness,
            view: view)
    }
}

/// MTKView delegate for the vectorscope: composites prebuilt density textures on the GPU.
/// Same isolation as `ScopeTraceRenderer`, and for the same reasons.
@MainActor
final class VectorscopeMetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    /// Everything one density build depends on. Equatable so a rebuild only happens on real change.
    private struct BuildInputs: Equatable {
        var points: [ScopePoint] = []
        var trailPoints: [ScopePoint] = []
        var zoom: AssistConfiguration.Scopes.VectorscopeZoom = .x1
        var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
    }

    private var inputs = BuildInputs()
    private var buildGeneration = 0
    private let buildQueue = DispatchQueue(
        label: "OpenZCine.vectorscope-density", qos: .userInitiated)
    private var mainTexture: MTLTexture?
    private var trailTexture: MTLTexture?
    private var blurredMain: MTLTexture?
    private var blurredTrail: MTLTexture?

    nonisolated private static let binCount = 128

    override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        pipeline = Self.quadPipeline
        super.init()
    }

    /// Stores the latest inputs and schedules an off-main density rebuild if anything changed.
    ///
    /// Binning the points and rasterising the 128×128 density image is CPU work, and measured on an
    /// iPhone 16 Pro Max it was 20% of the MAIN THREAD from inside `draw(in:)` — four times the cost
    /// of rendering the camera feed. It depends only on value types, so it belongs on a queue; the
    /// completion publishes the finished textures and asks for a redraw. Same treatment, and the
    /// same reason, as `ScopeTraceRenderer`.
    func update(
        points: [ScopePoint], trailPoints: [ScopePoint],
        zoom: AssistConfiguration.Scopes.VectorscopeZoom, brightness: Int, view: MTKView
    ) {
        let next = BuildInputs(
            points: points, trailPoints: trailPoints, zoom: zoom, brightness: brightness)
        guard next != inputs else { return }
        inputs = next
        buildGeneration += 1
        let generation = buildGeneration
        guard let device else { return }
        buildQueue.async { [weak self, weak view] in
            // `MTLDevice` is thread-safe for texture creation, so the upload rides along here
            // rather than hopping back to the main thread with a pixel buffer in hand.
            let main = Self.densityTexture(
                device: device, points: next.points, zoom: next.zoom,
                brightness: next.brightness)
            let trail = Self.densityTexture(
                device: device, points: next.trailPoints, zoom: next.zoom,
                brightness: next.brightness)
            DispatchQueue.main.async {
                // See `ScopeTraceRenderer.scheduleBuild` for why `assumeIsolated` and not a `Task`.
                MainActor.assumeIsolated {
                    guard let self, self.buildGeneration == generation else { return }
                    self.mainTexture = main
                    self.trailTexture = trail
                    // The blurs are GPU passes encoded per draw; drop them so they re-encode
                    // against the new densities.
                    self.blurredMain = nil
                    self.blurredTrail = nil
                    view?.setNeedsDisplay()
                }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let device, let queue, let pipeline,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let command = queue.makeCommandBuffer()
        else { return }

        // The blur radius tracks the plot side exactly like the Canvas filter did:
        // `side / binCount * 1.1` points, converted to pixels.
        let bounds = view.bounds.size
        let plot = scopePlotRect(bounds, top: 26)
        let sidePt = min(plot.width, plot.height)
        if blurredMain == nil, let mainTexture {
            blurredMain = Self.blurred(mainTexture, device: device, command: command)
        }
        if blurredTrail == nil, let trailTexture {
            blurredTrail = Self.blurred(trailTexture, device: device, command: command)
        }

        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        // Quad destination: the square trace rect centred in the plot, in normalized view space.
        let rect = CGRect(
            x: plot.midX - sidePt / 2, y: plot.midY - sidePt / 2, width: sidePt, height: sidePt)
        var quad = SIMD4<Float>(
            Float(rect.minX / bounds.width), Float(rect.minY / bounds.height),
            Float(rect.width / bounds.width), Float(rect.height / bounds.height))
        encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

        // Same pass order and opacities as the Canvas plot: blurred ghost (trail ×0.35),
        // blurred main, then the crisp core at 0.35.
        func drawQuad(_ texture: MTLTexture?, opacity: Float) {
            guard let texture else { return }
            var opacity = opacity
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        drawQuad(blurredTrail, opacity: Float(WaveformScopePlot.trailDecay))
        drawQuad(blurredMain, opacity: 1)
        drawQuad(mainTexture, opacity: 0.35)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// CPU bins + the tested density rasterizer → a premultiplied RGBA texture. Returns nil for an
    /// empty trace, matching the Canvas plot drawing nothing.
    nonisolated private static func densityTexture(
        device: MTLDevice, points: [ScopePoint],
        zoom: AssistConfiguration.Scopes.VectorscopeZoom, brightness: Int
    ) -> MTLTexture? {
        guard !points.isEmpty else { return nil }
        let bins = VectorscopeSampler.accumulate(
            points: points, binCount: binCount, gain: zoom.gain)
        guard
            let pixels = VectorscopeDensityRasterizer.premultipliedRGBA(
                bins: bins, brightness: brightness)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: binCount, height: binCount, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, binCount, binCount), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: binCount * 4)
            }
        }
        return texture
    }

    nonisolated private static func blurred(
        _ texture: MTLTexture, device: MTLDevice, command: MTLCommandBuffer
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height,
            mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: descriptor) else { return nil }
        // The Canvas plot blurred the upscaled draw by `side/binCount × 1.1` display points —
        // equivalent to a constant ≈1.1-bin Gaussian at texture resolution before the linear
        // upscale spreads it, independent of panel size.
        let blur = MPSImageGaussianBlur(device: device, sigma: 1.1)
        blur.encode(commandBuffer: command, sourceTexture: texture, destinationTexture: output)
        return output
    }

    /// Textured-quad pipeline with the same additive one/one blend as the trace rasterizer.
    nonisolated static let quadPipeline: MTLRenderPipelineState? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct VOut { float4 position [[position]]; float2 uv; };
            vertex VOut vector_v(uint vid [[vertex_id]],
                                 constant float4 &quad [[buffer(0)]]) {
                float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
                float2 c = corners[vid];
                float2 pos01 = float2(quad.x + c.x * quad.z, quad.y + c.y * quad.w);
                VOut o;
                o.position = float4(pos01.x * 2.0 - 1.0, 1.0 - pos01.y * 2.0, 0.0, 1.0);
                o.uv = c;
                return o;
            }
            fragment float4 vector_f(VOut in [[stage_in]],
                                     texture2d<float> density [[texture(0)]],
                                     constant float &opacity [[buffer(0)]]) {
                constexpr sampler linearSampler(filter::linear, address::clamp_to_zero);
                return density.sample(linearSampler, in.uv) * opacity;
            }
            """
        guard let library = try? device.makeLibrary(source: source, options: nil),
            let vertexFunction = library.makeFunction(name: "vector_v"),
            let fragmentFunction = library.makeFunction(name: "vector_f")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .bgra8Unorm
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()
}
