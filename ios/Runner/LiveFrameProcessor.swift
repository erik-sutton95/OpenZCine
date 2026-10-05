import CoreImage
import OpenCineApple
import OpenCineMedia
import OpenZCineCore
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
    /// Softens JPEG block steps before the look. Display path only — see `outputCIImage`.
    var blockSmoothing: BlockSmoothingSettings?
    /// Masks whatever block structure survives, after the look.
    var blockDither: BlockDitherSettings?
    /// When set, `lut` grades only its half of the frame (see ``SplitComparison``). Never affects
    /// `isIdentity`: with no LUT there is nothing to compare, so the split alone changes nothing.
    var splitComparison: SplitComparisonOrientation?

    var isIdentity: Bool {
        lut == nil && falseColor == nil && peaking == nil && zebra == nil
            && blockSmoothing == nil && blockDither == nil
    }
}

/// Variance-gated smoothing of flat areas, to soften JPEG block steps.
///
/// Trial values are driven from the demo harness so they can be swept on hardware without a
/// rebuild — these are the only numbers in the feature and none of them have been calibrated
/// against a real camera frame yet.
struct BlockSmoothingSettings: Equatable, Sendable {
    /// Tap offset in pixels. 2 gives a 5 px span from 9 taps — enough to ramp an 8 px block step.
    var radius: Double = 2
    /// Neighbourhood mean-absolute-deviation, in levels out of 255, at which the filter fully
    /// disengages. Below this a region counts as flat; above it, detail is left alone.
    var gateLevels: Double = 5
    /// How far toward the local mean a fully-flat region is pulled, 0…1.
    var strength: Double = 0.8
}

/// Masking noise added after the look to break up residual block periodicity.
struct BlockDitherSettings: Equatable, Sendable {
    /// Peak-to-peak amplitude in levels out of 255. Wants to be comparable to the block step it is
    /// masking — a few levels, not a visible grain overlay.
    var levels: Double = 3
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
    /// The operator-facing step. The detector constants behind it live in shared core
    /// (`Peaking.Sensitivity`), which is also what the Android shells resolve.
    var sensitivity: Peaking.Sensitivity = .medium
    /// Multiplies the sensitivity's noise gate, in the gate's own (squared) domain.
    ///
    /// The RATIO the detector thresholds is near-invariant to the camera's encoding, but the gate is
    /// an absolute magnitude, so it is not — see `Peaking.displayReferredGradientScale`. This is how
    /// a step keeps meaning the same thing on the photography feed, which is display-referred, as it
    /// does on the log video feed the gates were calibrated against.
    var gateScale: Double = 1
}

struct ZebraSettings: Equatable, Sendable {
    var unit: AssistConfiguration.Zebra.Unit = .ire
    var highlightEnabled: Bool = true
    /// Clip point as *reference* IRE — converted to native luma through the signal `curve`.
    var highlightIRE: Double = 100
    var highlightColor: MonitorZebraPaint = .white
    var midtoneEnabled: Bool = true
    var midtoneIRE: Double = 55
    var midtoneColor: MonitorZebraPaint = .amber
    var curve: ExposureToneCurve = .redLog3G10
    var clipNative: Double? = nil

    var mapping: ExposureSignalMapping {
        ExposureSignalMapping(curve: curve, clipNative: clipNative ?? curve.defaultClipNative)
    }
}

/// Source-compatible sampling addresses; the shared native runtime owns the buffers and contexts.
enum FrameSampling {
    static let cameraFileColorSpace = MonitorImageSampling.fileCodeColorSpace
    static func rgbaBuffer(from pixelBuffer: CVPixelBuffer, maxWidth: Int)
        -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)?
    {
        MonitorImageSampling.rgbaBuffer(from: pixelBuffer, maxWidth: maxWidth)
    }
    static func rgbaBuffer(from image: UIImage, maxWidth: Int)
        -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)?
    {
        MonitorImageSampling.rgbaBuffer(from: image, maxWidth: maxWidth)
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
        imageEffects(for: assist.playbackTools)
    }

    private func imageEffects(for visible: Set<MonitorAssistTool>) -> LiveImageEffects {
        LiveImageEffects(
            lut: LUTResolution.active(
                visibleTools: visible, selected: assistConfiguration.selectedLUT),
            falseColor: visible.contains(.falseColor)
                ? FalseColorSettings(
                    scale: assist.falseColorScale.nikonScale,
                    curve: exposureSignalMapping.curve,
                    clipNative: exposureSignalMapping.clipNative) : nil,
            peaking: visible.contains(.peaking)
                ? PeakingSettings(
                    color: Peaking.Color(rawValue: assist.peakingColor.rawValue) ?? .red,
                    sensitivity: Peaking.Sensitivity(rawValue: assist.peakingSensitivity.rawValue)
                        ?? .medium,
                    // The photography feed is a display-referred preview, so its gradients run
                    // larger than the log video feed the gates were calibrated on. Shared core
                    // owns the squaring, so both shells resolve the same number.
                    gateScale: isPhotographyMode
                        ? Peaking.gateScale(
                            gradientScale: Peaking.displayReferredGradientScale) : 1) : nil,
            zebra: visible.contains(.zebra)
                ? ZebraSettings(
                    unit: assistConfiguration.zebra.unit,
                    highlightEnabled: assist.zebraHighlight,
                    highlightIRE: assist.zebraHighlightIRE,
                    highlightColor: assist.zebraHighlightColor,
                    midtoneEnabled: assist.zebraMidtone,
                    midtoneIRE: assist.zebraMidtoneIRE,
                    midtoneColor: assist.zebraMidtoneColor,
                    curve: exposureSignalMapping.curve,
                    clipNative: exposureSignalMapping.clipNative) : nil,
            blockSmoothing: DemoHarness.blockSmoothStrength.map { strength in
                BlockSmoothingSettings(
                    gateLevels: DemoHarness.blockSmoothGateLevels ?? 5,
                    strength: strength)
            },
            blockDither: DemoHarness.blockDitherLevels.map { BlockDitherSettings(levels: $0) },
            splitComparison: LUTResolution.splitComparison(
                visibleTools: visible, enabled: assist.splitComparison,
                vertical: assist.splitVertical, muted: splitComparisonMuted))
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

    /// Whether the horizon level overlay is visible — gates per-frame virtual-horizon updates.
    var levelAssistActive: Bool {
        renderedLiveAssistTools.contains(.level)
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
    func publishScopeAssist(samples: OpenCineMedia.ScopeSamples) async {
        let trafficLightsCrushClip = assist.crushClipCompensation
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
        publishLiveScopeBundle(bundle)
    }

    func clearScopeAssist() {
        publishLiveScopeBundle(.empty)
    }

    /// Demo / mock-feed path: sample a `UIImage` (no live JPEG loop). `full` forces scatter points
    /// and a fine stride regardless of which live-view assist tools are visible — for scope
    /// surfaces that don't register as assist tools (e.g. the portrait scopes frame).
    func refreshScopes(from image: UIImage, full: Bool = false) async {
        guard let buffer = FrameSampling.rgbaBuffer(from: image, maxWidth: 200) else { return }
        openStillScopeSource()
        let visible = renderedLiveAssistTools
        let includePoints =
            full || ScopeAssistSampling.needsPointSamples(visible: visible)
        let stride = ScopeAssistSampling.pointStride
        let samples = OpenCineMedia.ScopeSampler.sampleRaw(
            bytes: buffer.data, width: buffer.width, height: buffer.height,
            bytesPerRow: buffer.bytesPerRow, transfer: .rec709, includePoints: includePoints,
            layout: .rgba, stride: stride, includeSampleCoordinates: true, requireCompleteRows: true
        )
        await publishScopeAssist(samples: samples)
    }
}

/// Source cube and calibration facts; shared native runtime owns the complete image graph and memo.
final class LiveFrameProcessor {
    private let fileStore: LUTFileStore
    private let native = MonitorUIImageGraphProcessor<LiveImageEffects>(
        beginReadback: { LiveViewSignposts.beginCreateCGImageReadback() },
        endReadback: { LiveViewSignposts.endCreateCGImageReadback() })

    init(fileStore: LUTFileStore) { self.fileStore = fileStore }

    func render(_ image: UIImage, effects: LiveImageEffects) -> UIImage {
        native.render(image, settings: effects, identity: effects.isIdentity) {
            graph(for: effects)
        }
    }

    func evictRenderCache() { native.evictRenderCache() }

    func outputCIImage(for image: UIImage, effects: LiveImageEffects) -> CIImage? {
        guard !effects.isIdentity else { return nil }
        return native.outputCIImage(for: image, graph: graph(for: effects))
    }

    private func graph(for effects: LiveImageEffects) -> MonitorUIImageGraph {
        var graph = MonitorUIImageGraph()
        let split = effects.splitComparison.map { $0 == .vertical }
        let grade = effects.lut.map { lut in
            request(key: lut.cacheKey) { self.cube(for: lut) }
        }
        if let falseColor = effects.falseColor, falseColor.scale == .limits {
            let mappingKey = "\(falseColor.curve.rawValue):\(falseColor.mapping.clipNative)"
            graph.look = .limits(
                grade: grade, splitVertical: split,
                paint: request(key: "limitsPaint:\(mappingKey)") {
                    FalseColorMap.limitsPaintCube(mapping: falseColor.mapping)
                },
                weight: request(key: "limitsWeight:\(mappingKey)") {
                    FalseColorMap.limitsWeightCube(mapping: falseColor.mapping)
                })
        } else if let falseColor = effects.falseColor {
            graph.look = .replacement(
                request(
                    key:
                        "false:\(falseColor.scale.rawValue):\(falseColor.curve.rawValue):\(falseColor.mapping.clipNative)"
                ) {
                    FalseColorMap.cube(scale: falseColor.scale, mapping: falseColor.mapping)
                })
        } else if let grade {
            graph.look = .grade(grade, splitVertical: split)
        }
        graph.smoothing = effects.blockSmoothing.map {
            MonitorBlockSmoothing(
                radius: $0.radius, gateLevels: $0.gateLevels, strength: $0.strength)
        }
        graph.dither = effects.blockDither.map { MonitorBlockDither(levels: $0.levels) }
        graph.peaking = effects.peaking.map {
            _ = ImageEffectsCompositor.fusedPeakingAvailable
            return MonitorPeakingOverlay(
                color: MonitorRGB($0.color.rgb),
                sensitivity: MonitorPeakingSensitivity(
                    ratioThreshold: $0.sensitivity.ratioThreshold,
                    noiseGate: $0.sensitivity.noiseGate), gateScale: $0.gateScale,
                fusedWindowPolicy: .admittedKernel)
        }
        graph.zebra = effects.zebra.map { ImageEffectsCompositor.resolvedZebra(settings: $0) }
        return graph
    }

    private func request(key: String, makeCube: @escaping () -> CubeLUT?)
        -> MonitorNativeCubeRequest
    {
        MonitorNativeCubeRequest(key: LUTCubeCache.versionedKey(forKey: key)) {
            guard let cube = LUTCubeCache.cube(forKey: key, makeCube)?.preparedForRenderer() else {
                return nil
            }
            return (cube.size, cube.rgbaComponents.withUnsafeBytes { Data($0) })
        }
    }

    private func cube(for selection: LUTSelection) -> CubeLUT? {
        switch selection {
        case .builtIn(let look): return look.cube()
        case .stored(let category, let fileName):
            return fileStore.cube(category: category, fileName: fileName)
        }
    }
}
