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
        push(into: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if push(into: context.coordinator) {
            uiView.setNeedsDisplay()
        }
    }

    @discardableResult
    private func push(into renderer: ScopeTraceRenderer) -> Bool {
        renderer.update(
            samples: samples, trail: trail, mode: mode, brightness: brightness, mapping: mapping)
    }
}

/// MTKView delegate: builds the dot list on demand and draws it in one additive pass.
final class ScopeTraceRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    private var samples: ScopeSamples = .empty
    private var trail: ScopeSamples = .empty
    private var mode: ScopeTraceMetal.Mode = .waveform(.luma)
    private var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
    private var mapping = ExposureSignalMapping(curve: .redLog3G10)
    private var vertices: [ScopeTraceMetal.Vertex] = []
    private var verticesDirty = true
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

    /// Stores the latest trace inputs; returns whether anything changed (drives `setNeedsDisplay`).
    func update(
        samples: ScopeSamples, trail: ScopeSamples, mode: ScopeTraceMetal.Mode,
        brightness: Int, mapping: ExposureSignalMapping
    ) -> Bool {
        let changed =
            self.samples != samples || self.trail != trail || self.mode != mode
            || self.brightness != brightness || self.mapping != mapping
        guard changed else { return false }
        self.samples = samples
        self.trail = trail
        self.mode = mode
        self.brightness = brightness
        self.mapping = mapping
        verticesDirty = true
        return true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        verticesDirty = true
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pipeline, let queue,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let command = queue.makeCommandBuffer()
        else { return }
        // Positions are computed in panel POINTS with the same axis math as the Canvas plots;
        // the shader scales by the drawable's screen scale.
        if verticesDirty {
            verticesDirty = false
            vertices.removeAll(keepingCapacity: true)
            let bounds = view.bounds.size
            if bounds.width > 1, bounds.height > 1 {
                let rect = scopePlotRect(bounds, top: 26)
                let opacity = ScopePalette.dataOpacity(brightness: brightness)
                ScopeTraceMetal.vertices(
                    into: &vertices, points: trail.points, mode: mode, rect: rect,
                    mapping: mapping, opacity: opacity * WaveformScopePlot.trailDecay)
                ScopeTraceMetal.vertices(
                    into: &vertices, points: samples.points, mode: mode, rect: rect,
                    mapping: mapping, opacity: opacity)
            }
        }
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
    static let sharedPipeline: MTLRenderPipelineState? = {
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
        push(into: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if push(into: context.coordinator) {
            uiView.setNeedsDisplay()
        }
    }

    @discardableResult
    private func push(into renderer: VectorscopeMetalRenderer) -> Bool {
        renderer.update(
            points: points, trailPoints: trailPoints, zoom: zoom, brightness: brightness)
    }
}

final class VectorscopeMetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    private var points: [ScopePoint] = []
    private var trailPoints: [ScopePoint] = []
    private var zoom: AssistConfiguration.Scopes.VectorscopeZoom = .x1
    private var brightness: Int = AssistConfiguration.Scopes.defaultBrightness
    private var texturesDirty = true
    private var mainTexture: MTLTexture?
    private var trailTexture: MTLTexture?
    private var blurredMain: MTLTexture?
    private var blurredTrail: MTLTexture?

    private static let binCount = 128

    override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        pipeline = Self.quadPipeline
        super.init()
    }

    func update(
        points: [ScopePoint], trailPoints: [ScopePoint],
        zoom: AssistConfiguration.Scopes.VectorscopeZoom, brightness: Int
    ) -> Bool {
        let changed =
            self.points != points || self.trailPoints != trailPoints || self.zoom != zoom
            || self.brightness != brightness
        guard changed else { return false }
        self.points = points
        self.trailPoints = trailPoints
        self.zoom = zoom
        self.brightness = brightness
        texturesDirty = true
        return true
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

        if texturesDirty {
            texturesDirty = false
            mainTexture = Self.densityTexture(
                device: device, points: points, zoom: zoom, brightness: brightness)
            trailTexture = Self.densityTexture(
                device: device, points: trailPoints, zoom: zoom, brightness: brightness)
            blurredMain = nil
            blurredTrail = nil
        }

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
    private static func densityTexture(
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

    private static func blurred(
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
    static let quadPipeline: MTLRenderPipelineState? = {
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
