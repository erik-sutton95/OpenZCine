import CoreImage
import UIKit
import os

/// Process-wide memo of generated/parsed LUT cubes, keyed by `LUTSelection.cacheKey` (or a
/// false-colour scale key). The log-look cubes run ~10⁵ `pow`/`exp` calls to build, so generating
/// each only once — and ideally off the main thread via `prewarmBuiltIns()` — keeps switching and
/// scrolling the LUT drum smooth.
enum LUTCubeCache {
    private struct State {
        var cache: [String: CubeLUT] = [:]
        var revisions: [String: UInt] = [:]
        /// Access order, least-recent first — drives the LRU eviction.
        var order: [String] = []

        mutating func markUsed(_ key: String) {
            if order.last == key { return }
            if let index = order.firstIndex(of: key) { order.remove(at: index) }
            order.append(key)
        }
    }

    /// Bounded so an operator auditioning many stored `.cube` files can't grow the memo without
    /// limit (a 33³ float cube is ~0.5 MB). Far above the built-in look count, so prewarmed cubes
    /// only ever evict under real pressure.
    private static let maxEntries = 24
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Adds the current revision to a stable selection key so long-lived renderers cannot reuse a
    /// stale filter after a stored LUT is deleted and later re-imported under the same file name.
    static func versionedKey(forKey key: String) -> String {
        state.withLock { "\(key)#\($0.revisions[key, default: 0])" }
    }

    /// Invalidates a stored selection across the process. Existing renderer-local filters become
    /// unreachable because their revision suffix no longer matches.
    static func invalidate(forKey key: String) {
        state.withLock { state in
            let oldKey = "\(key)#\(state.revisions[key, default: 0])"
            state.cache.removeValue(forKey: oldKey)
            state.order.removeAll { $0 == oldKey }
            state.revisions[key, default: 0] &+= 1
        }
    }

    static func cube(forKey key: String, _ make: () -> CubeLUT?) -> CubeLUT? {
        let key = versionedKey(forKey: key)
        let cached = state.withLock { state -> CubeLUT? in
            guard let cube = state.cache[key] else { return nil }
            state.markUsed(key)
            return cube
        }
        if let cached { return cached }
        guard let cube = make() else { return nil }
        state.withLock { state in
            state.cache[key] = cube
            state.markUsed(key)
            while state.order.count > maxEntries {
                state.cache.removeValue(forKey: state.order.removeFirst())
            }
        }
        return cube
    }

    /// Builds every built-in look's cube into the cache. Safe to call off the main actor (the cube
    /// math is pure) so the first scroll onto a log look doesn't hitch.
    static func prewarmBuiltIns() {
        for look in MonitorLUT.allCases {
            _ = cube(forKey: LUTSelection.builtIn(look).cacheKey) { look.cube() }
        }
    }
}

/// Per-frame monitor settings for the analysis tools that modify the displayed image: the creative
/// LUT, plus false colour, focus peaking, and zebra. Derived from the active assist tools each
/// frame; `isIdentity` lets the renderer skip Core Image entirely when nothing is on.
struct LiveImageEffects: Equatable, Sendable {
    var lut: LUTSelection?
    var falseColor: FalseColorSettings?
    var peaking: PeakingSettings?
    var zebra: ZebraSettings?

    var isIdentity: Bool {
        lut == nil && falseColor == nil && peaking == nil && zebra == nil
    }
}

/// False colour replaces the creative look with flat exposure-zone colours, so it carries which
/// ramp and signal curve to read against.
struct FalseColorSettings: Equatable, Sendable {
    var scale: FalseColorScale = .stops
    var curve: ExposureToneCurve = .redLog3G10
    var clipNative: Double? = nil

    init(scale: FalseColorScale, curve: ExposureToneCurve) {
        self.init(scale: scale, curve: curve, clipNative: nil)
    }

    init(scale: FalseColorScale, curve: ExposureToneCurve, clipNative: Double?) {
        self.scale = scale
        self.curve = curve
        self.clipNative = clipNative
    }

    var mapping: ExposureSignalMapping {
        ExposureSignalMapping(curve: curve, clipNative: clipNative ?? curve.defaultClipNative)
    }
}

struct PeakingSettings: Equatable, Sendable {
    var color: Peaking.Color = .red  // reads clearly over almost any scene
    /// Sharpness threshold on the de-logged peaking mask — lower flags finer (noisier) edges.
    /// 0.035 is the stored default (Sensitivity = Med); the renderer rescales it onto the
    /// gradient-edge response.
    var threshold: Double = 0.035
}

extension Peaking.Sensitivity {
    /// The operator-facing level mapped to the renderer's band-response threshold. Med keeps the
    /// prior hardcoded 0.035; Low raises it (stricter, fewer edges), High lowers it (finer, noisier).
    var peakingThreshold: Double {
        switch self {
        case .low: 0.05
        case .medium: 0.035
        case .high: 0.022
        }
    }
}

struct ZebraSettings: Equatable, Sendable {
    var unit: AssistConfiguration.Zebra.Unit = .ire
    var highlightEnabled: Bool = true
    /// Clip point as *reference* IRE — converted to native luma through the signal `curve`.
    var highlightIRE: Double = 100
    var highlightColor: AssistConfiguration.Zebra.StripeColor = .white
    var midtoneEnabled: Bool = true
    var midtoneIRE: Double = 55
    var midtoneColor: AssistConfiguration.Zebra.StripeColor = .amber
    var curve: ExposureToneCurve = .redLog3G10
    var clipNative: Double? = nil

    var mapping: ExposureSignalMapping {
        ExposureSignalMapping(curve: curve, clipNative: clipNative ?? curve.defaultClipNative)
    }
}

/// Downsamples a live frame to a small tightly-packed RGBA8 buffer for the scopes. The scopes only
/// need a coarse read of the distribution, so shrinking to a couple hundred pixels wide keeps the
/// per-frame sampling cheap; `ScopeSampler` then strides over what's left.
enum FrameSampling {
    /// One device-RGB color space for every downsample — per-sample creation (~8–12 Hz) is
    /// allocator churn on the scope path.
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    /// The transfer space camera files carry (BT.709 tags on the ZR's MP4/MOV containers). Scope
    /// taps render into this space to recover the file's raw code values — undoing the
    /// 709→sRGB conversion AVFoundation applies into the composition working space — so playback
    /// scopes read the same numbers live view samples straight off the feed JPEG.
    static let cameraFileColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    /// One shared context for scope-tap renders — a per-call `CIContext` is an allocator and
    /// GPU-state churn hazard on a repeating path.
    private static let scopeTapContext = CIContext(options: [.cacheIntermediates: false])

    /// Downsamples a `CVPixelBuffer` (e.g. from `AVPlayerItemVideoOutput`) into a small RGBA buffer.
    static func rgbaBuffer(
        from pixelBuffer: CVPixelBuffer, maxWidth: Int
    ) -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = scopeTapContext.createCGImage(ciImage, from: ciImage.extent)
        else { return nil }
        return rgbaBuffer(from: UIImage(cgImage: cgImage), maxWidth: maxWidth)
    }

    static func rgbaBuffer(
        from image: UIImage, maxWidth: Int
    ) -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(cgImage.width))
        let width = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(1, Int((Double(cgImage.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                let ctx = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: rgbColorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? (data, width, height, bytesPerRow) : nil
    }
}

extension NativeAppModel {
    /// Transfer curve false colour should measure, derived from the active camera signal.
    var falseColorToneCurve: ExposureToneCurve {
        exposureSignalMapping.curve
    }

    /// Shared 0–100 black-to-clip mapping used by every live exposure assist. In photography
    /// mode the live view is a display-referred preview, so the mapping follows the stills
    /// tone mode (sRGB, or HLG when the body reports it) — the movie codec's log curve would
    /// anchor mid grey and the clip line in the wrong places. Video keeps the codec-derived
    /// log mapping; R3D NE follows Nikon's base-circuit/metadata-ISO warning table instead of
    /// assuming a fixed 70% native endpoint.
    var exposureSignalMapping: ExposureSignalMapping {
        if isPhotographyMode {
            return .stills(toneMode: cameraPropertySnapshot.stillToneMode)
        }
        return videoExposureSignalMapping
    }

    /// The movie-signal mapping, independent of the active selector — playback of video clips
    /// keeps anchoring by the recording codec even while the body sits in photo mode.
    private var videoExposureSignalMapping: ExposureSignalMapping {
        ExposureSignalMapping.camera(
            codec: cameraState.codec,
            iso: cameraPropertySnapshot.iso,
            baseISO: cameraPropertySnapshot.baseISO)
    }

    /// The mapping playback assists use. Clips do not yet persist a verified tone profile, so
    /// this follows the connected camera like every other assist — but with no camera at all it
    /// falls back to Log3G10 (the ZR's primary R3D NE profile) instead of `forCameraCodec("")`'s
    /// N-Log default, so reviewing R3D-derived clips offline anchors correctly.
    var playbackExposureSignalMapping: ExposureSignalMapping {
        guard isConnected || isDemoSession else {
            return ExposureSignalMapping(curve: .redLog3G10)
        }
        return videoExposureSignalMapping
    }

    /// The image effects to bake into the live frame, derived from which assist tools are on. False
    /// colour, peaking, and zebra use their default parameters for now (the tools are on/off
    /// toggles); the LUT follows the operator's picked look.
    var playbackImageEffects: LiveImageEffects {
        imageEffects(for: preferences.visibleAssistTools(for: .playback))
    }

    private func imageEffects(for visible: Set<MonitorAssistTool>) -> LiveImageEffects {
        LiveImageEffects(
            lut: LUTResolution.active(
                visibleTools: visible, selected: assistConfiguration.selectedLUT),
            falseColor: visible.contains(.falseColor)
                ? FalseColorSettings(
                    scale: assistConfiguration.falseColorScale,
                    curve: exposureSignalMapping.curve,
                    clipNative: exposureSignalMapping.clipNative) : nil,
            peaking: visible.contains(.peaking)
                ? PeakingSettings(
                    color: assistConfiguration.peakingColor,
                    threshold: assistConfiguration.peakingSensitivity.peakingThreshold) : nil,
            zebra: visible.contains(.zebra)
                ? ZebraSettings(
                    unit: assistConfiguration.zebra.unit,
                    highlightEnabled: assistConfiguration.zebra.highlightEnabled,
                    highlightIRE: assistConfiguration.zebra.highlightIRE,
                    highlightColor: assistConfiguration.zebra.highlightColor,
                    midtoneEnabled: assistConfiguration.zebra.midtoneEnabled,
                    midtoneIRE: assistConfiguration.zebra.midtoneIRE,
                    midtoneColor: assistConfiguration.zebra.midtoneColor,
                    curve: exposureSignalMapping.curve,
                    clipNative: exposureSignalMapping.clipNative) : nil)
    }

    var liveImageEffects: LiveImageEffects {
        // The photo-filtered set: a creative LUT (or any cinema-only effect) left on in video
        // must not ride into the photo feed — it cannot even be turned off from the photo
        // toolbar. It comes back untouched on the flip to video.
        imageEffects(for: renderedLiveAssistTools)
    }

    /// Whether any scope tool is on, so the frame loop only pays for sampling when a scope is shown.
    var scopesActive: Bool {
        let visible = renderedLiveAssistTools
        return visible.contains(.waveform) || visible.contains(.parade)
            || visible.contains(.histogram) || visible.contains(.vectorscope)
            || visible.contains(.trafficLights)
    }

    /// Whether a scope assist that only needs histogram bins is on (GPU path samples for these).
    var histogramScopeActive: Bool {
        let visible = renderedLiveAssistTools
        return visible.contains(.histogram) || visible.contains(.trafficLights)
    }

    /// Whether the horizon level overlay is visible — gates per-frame virtual-horizon updates.
    var levelAssistActive: Bool {
        renderedLiveAssistTools.contains(.level) && assistConfiguration.level.enabled
    }

    /// The cube the vectorscope pushes its sampled points through so it reads the MONITOR image:
    /// the operator's active LUT when the LUT tool is on, else the built-in display tone map for
    /// the current signal curve. `nil` when the vectorscope is hidden (skips the transform).
    func vectorscopeMonitorCube(
        visibleTools: Set<MonitorAssistTool>, curve: ExposureToneCurve
    ) -> CubeLUT? {
        guard visibleTools.contains(.vectorscope) else { return nil }
        let fallback: MonitorLUT = curve == .redLog3G10 ? .log3G10Rec709 : .nLogRec709
        let selection =
            LUTResolution.active(
                visibleTools: visibleTools, selected: assistConfiguration.selectedLUT)
            ?? .builtIn(fallback)
        return LUTCubeCache.cube(forKey: selection.cacheKey) {
            switch selection {
            case .builtIn(let look): return look.cube()
            case .stored(let category, let fileName):
                return self.lutFileStore.cube(category: category, fileName: fileName)
            }
        }
    }

    /// Publishes scope bins/points and derived traffic-light readings in one assignment.
    /// Heavy derivation runs off the main actor; only the final `scopeAssist` assignment is main-bound.
    func publishScopeAssist(samples: ScopeSamples) async {
        let trafficLightsCrushClip = assistConfiguration.scopes.crushClipCompensation
        let mapping = exposureSignalMapping
        let vectorscopeCube = vectorscopeMonitorCube(
            visibleTools: renderedLiveAssistTools,
            curve: mapping.curve)
        let previous = scopeAssist
        let bundle = await Task.detached(priority: .userInitiated) {
            ScopeAssistSampling.bundle(
                samples: samples,
                trafficLightsCrushClip: trafficLightsCrushClip,
                mapping: mapping,
                vectorscopeCube: vectorscopeCube,
                previous: previous)
        }.value
        scopeAssist = bundle
    }

    func clearScopeAssist() {
        scopeAssist = .empty
    }

    /// Demo / mock-feed path: sample a `UIImage` (no live JPEG loop). `full` forces scatter points
    /// and a fine stride regardless of which live-view assist tools are visible — for scope
    /// surfaces that don't register as assist tools (e.g. the portrait scopes frame).
    func refreshScopes(from image: UIImage, full: Bool = false) async {
        guard let buffer = FrameSampling.rgbaBuffer(from: image, maxWidth: 200) else { return }
        let visible = renderedLiveAssistTools
        let includePoints =
            full || ScopeAssistSampling.needsPointSamples(visible: visible)
        let stride = ScopeAssistSampling.pointStride
        let samples = ScopeSampler.sample(
            rgba: buffer.data, width: buffer.width, height: buffer.height,
            bytesPerRow: buffer.bytesPerRow, stride: stride, includePoints: includePoints)
        await publishScopeAssist(samples: samples)
    }
}

/// Applies the monitor analysis effects to each live frame on the GPU.
///
/// Pipeline per frame: pick a *base* look — false colour (which overrides the creative grade,
/// because it _is_ the monitoring image) or the selected LUT — then layer focus peaking and zebra
/// over it. LUTs and all false-colour scales use cached `CIColorCube` filters; OpenZCine's smoothstep
/// transitions are baked into those cubes. Peaking and zebra are stock Core Image filter chains
/// tuned to the thresholds defined in `OpenZCineCore`. Edges and exposure are measured from the
/// *original* frame, so a grade never changes what reads as in-focus or clipped.
final class LiveFrameProcessor {
    // 16-bit half-float pipeline + matching output so cube interpolation and the composites don't
    // posterize, and Core Animation dithers the result down to the panel (see the LUT banding fix).
    // The working space is sRGB; camera inputs are explicitly marked unmanaged below so the LUT,
    // false-colour, zebra, and peaking tools receive encoded code values instead of an automatic
    // sRGB→linear conversion. That is the domain `ExposureScale` and the `.cube` files use.
    private static let displaySpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let context = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: displaySpace,
        .cacheIntermediates: false,
    ])
    private let outputColorSpace = displaySpace
    private let fileStore: LUTFileStore
    // One CIColorCube filter per look, kept for the renderer's life so switching back to a look is
    // instant (the cube tables themselves are memoized process-wide in `LUTCubeCache`).
    private var cubeFilters: [String: CIFilter] = [:]
    /// Memoizes the last GPU bake so unrelated SwiftUI invalidation doesn't repeat `createCGImage`.
    /// Holds a strong ref and compares by identity (`===`): a bare `ObjectIdentifier` could be
    /// reused by a later allocation and serve a stale bake — a frozen frame reads as a shoot
    /// failure, so one retained `UIImage` buys a collision-proof memo.
    private var lastRenderInput: UIImage?
    private var lastRenderEffects: LiveImageEffects?
    private var lastRenderedImage: UIImage?

    init(fileStore: LUTFileStore) {
        self.fileStore = fileStore
    }

    /// Returns `image` with every active effect baked in, or unchanged when nothing is on or the
    /// frame can't be read as a `CIImage`.
    func render(_ image: UIImage, effects: LiveImageEffects) -> UIImage {
        if effects.isIdentity {
            evictRenderCache()
            return image
        }
        if image === lastRenderInput, effects == lastRenderEffects,
            let cached = lastRenderedImage
        {
            return cached
        }
        guard let output = outputCIImage(for: image, effects: effects) else { return image }
        LiveViewSignposts.beginCreateCGImageReadback()
        defer { LiveViewSignposts.endCreateCGImageReadback() }
        guard
            let cgImage = context.createCGImage(
                output, from: output.extent, format: .RGBAh, colorSpace: outputColorSpace)
        else { return image }
        let rendered = UIImage(
            cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        lastRenderInput = image
        lastRenderEffects = effects
        lastRenderedImage = rendered
        return rendered
    }

    /// Drops the single-frame render memo so assists-off paths do not retain a baked `CGImage`.
    func evictRenderCache() {
        lastRenderInput = nil
        lastRenderEffects = nil
        lastRenderedImage = nil
    }

    /// Builds the output `CIImage` with every active effect applied, or `nil` when nothing is on or
    /// the frame can't be read. Shared by the `UIImageView` path (→ `createCGImage`, a GPU→CPU
    /// readback) and the Metal path (→ rendered straight to a `CAMetalLayer` drawable, no readback).
    /// Pure graph-building — uses no `CIContext`, so a Metal renderer can drive it with its own.
    func outputCIImage(for image: UIImage, effects: LiveImageEffects) -> CIImage? {
        // Camera JPEGs and demo stills carry an sRGB tag, but their RGB components are the encoded
        // signal values the monitoring cubes measure. Suppress Core Image's automatic input match
        // (normally sRGB → linear working values) so Log3G10/N-Log thresholds see those code values.
        guard
            !effects.isIdentity,
            let input = CIImage(image: image, options: [.colorSpace: NSNull()])
        else { return nil }
        let extent = input.extent

        var output = input
        if let falseColor = effects.falseColor, falseColor.scale == .limits {
            // Limits keeps the monitor's normal look between the zones: grade first (the selected
            // LUT, or the untouched feed), then composite the crush/clip paint on top through a
            // zone-weight mask. Both limits cubes measure the raw code values in `input`.
            if let lut = effects.lut {
                output = applyBaseCube(to: input, key: lut.cacheKey) { self.cube(for: lut) }
            }
            let mappingKey = "\(falseColor.curve.rawValue):\(falseColor.mapping.clipNative)"
            let paint = applyBaseCube(to: input, key: "limitsPaint:\(mappingKey)") {
                FalseColorMap.limitsPaintCube(mapping: falseColor.mapping)
            }
            let weight = applyBaseCube(to: input, key: "limitsWeight:\(mappingKey)") {
                FalseColorMap.limitsWeightCube(mapping: falseColor.mapping)
            }
            output = paint.cropped(to: extent).applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: output.cropped(to: extent),
                    kCIInputMaskImageKey: weight.cropped(to: extent),
                ])
        } else if let falseColor = effects.falseColor {
            output = applyBaseCube(
                to: input,
                key:
                    "false:\(falseColor.scale.rawValue):\(falseColor.curve.rawValue):\(falseColor.mapping.clipNative)"
            ) {
                FalseColorMap.cube(scale: falseColor.scale, mapping: falseColor.mapping)
            }
        } else if let lut = effects.lut {
            output = applyBaseCube(to: input, key: lut.cacheKey) { self.cube(for: lut) }
        }

        if let peaking = effects.peaking {
            output = ImageEffectsCompositor.applyPeaking(
                over: output, source: input, settings: peaking, extent: extent)
        }
        if let zebra = effects.zebra {
            output = ImageEffectsCompositor.applyZebra(
                over: output, source: input, settings: zebra, extent: extent)
        }
        return output
    }

    // MARK: - Base look (LUT or false colour)

    private func applyBaseCube(to input: CIImage, key: String, makeCube: () -> CubeLUT?) -> CIImage
    {
        let versionedKey = LUTCubeCache.versionedKey(forKey: key)
        let filter: CIFilter?
        if let cached = cubeFilters[versionedKey] {
            filter = cached
        } else if let cube = LUTCubeCache.cube(forKey: key, makeCube) {
            let data = cube.rgbaComponents.withUnsafeBytes { Data($0) }
            let built = CIFilter(
                name: "CIColorCube",
                parameters: ["inputCubeDimension": cube.size, "inputCubeData": data])
            cubeFilters[versionedKey] = built
            filter = built
        } else {
            filter = nil
        }
        guard let filter else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        return filter.outputImage ?? input
    }

    private func cube(for selection: LUTSelection) -> CubeLUT? {
        switch selection {
        case .builtIn(let look): return look.cube()
        case .stored(let category, let fileName):
            return fileStore.cube(category: category, fileName: fileName)
        }
    }
}
