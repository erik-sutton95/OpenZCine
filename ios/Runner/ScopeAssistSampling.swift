import Foundation

/// Bundled scope sample plus derived assist readings — published once per throttle tick so SwiftUI
/// invalidates one property instead of separate histogram / traffic-light updates.
struct ScopeAssistBundle: Equatable, Sendable {
    var samples: ScopeSamples = .empty
    /// Monitor-domain points for the vectorscope — the clean samples pushed through the
    /// operator's active look (LUT, or the built-in display tone map). Empty when hidden.
    var vectorscopePoints: [ScopePoint] = []
    /// The previous tick's samples/points — the plots draw these at decayed opacity underneath
    /// the current tick (phosphor-style persistence), so a low sampling rate still reads as a
    /// smoothly evolving trace instead of a hard step every tick.
    var trailSamples: ScopeSamples = .empty
    var trailVectorscopePoints: [ScopePoint] = []
    var trafficLights: TrafficLightsReading = .empty

    static let empty = ScopeAssistBundle()
}

/// Throttle, stride, and publish policy for scope-based view assists.
///
/// **Scope input invariant:** every scope (waveform, parade, histogram, vectorscope, traffic
/// lights) meters the *clean* source/log camera frame — the convention in Nikon's published R3D
/// NE zebra data sheet (the log signal is measured directly, with the ISO-dependent overexposure
/// warning expanded to 100%). Display assists (false colour, LUT, zebra, peaking) are baked into
/// a separate display frame and must never reach the samplers — a false-colour palette would
/// otherwise rewrite the measurements.
///
/// **CPU vs GPU by assist (live view, default paths):**
/// - **LUT / false colour / peaking / zebra** — Core Image on GPU; default `UIImageView` path does a
///   GPU→CPU `createCGImage` readback each displayed frame (`LiveFrameProcessor`). Opt-in
///   `ZC_METAL_FEED=1` avoids readback by presenting straight to a `CAMetalLayer`.
/// - **Waveform / parade** — CPU `ScopeSampler` scatter points, rasterized by the Metal trace
///   renderer (`ScopeTraceMetalView`) from the same points/axis/palette on every surface; the
///   Canvas plots remain as the pixel reference (`ZC_DEMO_CANVAS_SCOPES=1`) and failure fallback.
/// - **Vectorscope** — CPU points binned by CbCr with per-bin colour; SwiftUI draws the density.
/// - **Histogram / traffic lights** — the same shared CPU grid per throttle tick; SwiftUI `Canvas`
///   draws the histogram; traffic lights read the same bins. There is deliberately ONE sampler and
///   ONE live renderer per scope on every surface — live-vs-playback parity is a product
///   requirement, so any renderer change must hold the Canvas-reference pixel diff.
///
/// - **Guides / grid / crosshair / level / grain** — SwiftUI `Canvas` / shapes on the feed overlay;
///   level also reads PTP virtual-horizon angles (~10 Hz). Grain is rasterized once via
///   `.drawingGroup()`.
/// - **Focus boxes** — SwiftUI `Canvas` from live-view header metadata (~15 Hz).
///
/// **Debug memory:** Xcode scheme `enableGPUFrameCaptureMode` / `enableGPUValidationMode` retain
/// GPU frame history and can jetsam the app within ~1–2 minutes on device. Leave both disabled for
/// long live-view sessions; enable only while capturing a single frame from the Debug menu.
enum ScopeAssistSampling {
    /// Scope assists that share the histogram / point grid.
    static let scopeTools: [MonitorAssistTool] = [
        .waveform, .parade, .histogram, .vectorscope, .trafficLights,
    ]

    /// ~30 Hz sampling (24 Hz when more than three scopes share the grid) — near-real-time with
    /// the feed. Affordable because rasterization moved to the GPU: a tick now costs only the
    /// small 200px sampling tap (~1–2 ms off-main), and the phosphor trail turns any dropped or
    /// shed tick into decay instead of a stutter. Thermal shedding still multiplies these
    /// intervals under load, so a hot device degrades to a slower-but-smooth trace, never a
    /// hotter one.
    static let baseMinInterval: CFAbsoluteTime = 1.0 / 30.0
    static let denseMinInterval: CFAbsoluteTime = 1.0 / 24.0
    static let denseAssistThreshold = 3

    static func activeScopeCount(visible: Set<MonitorAssistTool>) -> Int {
        scopeTools.filter { visible.contains($0) }.count
    }

    static func minInterval(activeScopeCount: Int) -> CFAbsoluteTime {
        activeScopeCount > denseAssistThreshold ? denseMinInterval : baseMinInterval
    }

    /// Scope cadence under thermal load — scopes are heavier than feed display (scatter points).
    /// Applies on top of `ThermalTier.sheddingInterval` so Serious runs ~4 Hz instead of ~8 Hz.
    static func thermalScopeInterval(activeScopeCount: Int, thermalTier: ThermalTier)
        -> CFAbsoluteTime
    {
        let base = minInterval(activeScopeCount: activeScopeCount)
        let scopeMultiplier: Double =
            switch thermalTier {
            case .nominal, .fair: 1.0
            case .serious: 2.0
            case .critical: 2.5
            }
        return thermalTier.sheddingInterval(base: base) * scopeMultiplier
    }

    /// ONE sampling density for every surface — live view and playback must produce identical
    /// traces, so the stride is a constant. Thermal load and scope count shed the REFRESH
    /// INTERVAL instead (``thermalScopeInterval``); the phosphor trail bridges slower ticks
    /// without the trace ever going sparse and dim the way stride shedding did.
    static let pointStride = 2

    /// Waveform, parade, and the vectorscope need scatter points; histogram/traffic lights read
    /// only the channel bins.
    static func needsPointSamples(visible: Set<MonitorAssistTool>) -> Bool {
        visible.contains(.vectorscope) || visible.contains(.waveform)
            || visible.contains(.parade)
    }

    /// Whether the live loop should run any scope sampling this frame.
    static func shouldSample(visible: Set<MonitorAssistTool>) -> Bool {
        activeScopeCount(visible: visible) > 0
    }

    /// Derives traffic-light readings from one `ScopeSamples` value.
    static func trafficLightsReading(
        from samples: ScopeSamples,
        trafficLightsCrushClip: AssistConfiguration.CrushClipCompensation,
        mapping: ExposureSignalMapping = ExposureSignalMapping(curve: .redLog3G10)
    ) -> TrafficLightsReading {
        TrafficLightsMeter.measure(
            samples: samples,
            noiseFloorCompensation: trafficLightsCrushClip,
            mapping: mapping)
    }

    static func bundle(
        samples: ScopeSamples,
        trafficLightsCrushClip: AssistConfiguration.CrushClipCompensation,
        mapping: ExposureSignalMapping = ExposureSignalMapping(curve: .redLog3G10),
        vectorscopeCube: CubeLUT? = nil,
        previous: ScopeAssistBundle = .empty
    ) -> ScopeAssistBundle {
        ScopeAssistBundle(
            samples: samples,
            vectorscopePoints: vectorscopeCube.map {
                VectorscopeSampler.monitorPoints(samples.points, through: $0)
            } ?? [],
            trailSamples: previous.samples,
            trailVectorscopePoints: previous.vectorscopePoints,
            trafficLights: trafficLightsReading(
                from: samples,
                trafficLightsCrushClip: trafficLightsCrushClip,
                mapping: mapping))
    }
}
