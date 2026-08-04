import CoreImage
import Foundation
import os

/// Shared Core Image pipeline for monitor analysis effects (false colour, LUT, peaking, zebra).
/// Used by the live-view renderer and media-playback `AVVideoComposition` so both paths share the
/// same thresholds and colour mapping.
enum ImageEffectsCompositor {
    /// Sendable snapshot of effects for AVFoundation's composition handler (cube tables resolved
    /// up front on the main actor).
    struct ResolvedEffects: Equatable, Sendable {
        var baseCubeDimension: Int?
        var baseCubeData: Data?
        /// Limits false colour composites crush/clip paint OVER the graded base instead of
        /// replacing it: paint colours and a grayscale zone-weight mask, both indexed by the
        /// encoded source signal (`FalseColorMap.limitsPaintCube` / `limitsWeightCube`).
        var limitsCubeDimension: Int?
        var limitsPaintCubeData: Data?
        var limitsWeightCubeData: Data?
        var peaking: PeakingSettings?
        var zebra: ZebraSettings?
        /// Set only when the base cube IS the operator's LUT — a false-colour base is the
        /// monitoring image itself and has no ungraded half to compare against.
        var splitComparison: SplitComparisonOrientation?

        var needsComposition: Bool {
            baseCubeData != nil || limitsPaintCubeData != nil || peaking != nil || zebra != nil
        }
    }

    /// Resolves `LiveImageEffects` into sendable cube payloads for playback composition.
    static func resolve(
        _ effects: LiveImageEffects,
        lutCube: (LUTSelection) -> CubeLUT?
    ) -> ResolvedEffects {
        var dimension: Int?
        var data: Data?
        var limitsDimension: Int?
        var limitsPaint: Data?
        var limitsWeight: Data?
        var split: SplitComparisonOrientation?

        if let falseColor = effects.falseColor, falseColor.scale == .limits {
            // Limits keeps the monitor's normal look between the zones: the base stays the
            // selected LUT (or the untouched feed) and the crush/clip paint composites on top.
            if let lut = effects.lut, let cube = lutCube(lut) {
                dimension = cube.size
                data = cube.rgbaComponents.withUnsafeBytes { Data($0) }
                split = effects.splitComparison
            }
            let key = falseColorCacheKey(falseColor)
            if let paint = LUTCubeCache.cube(
                forKey: "limitsPaint:\(key)",
                { FalseColorMap.limitsPaintCube(mapping: falseColor.mapping) }),
                let weight = LUTCubeCache.cube(
                    forKey: "limitsWeight:\(key)",
                    { FalseColorMap.limitsWeightCube(mapping: falseColor.mapping) })
            {
                limitsDimension = paint.size
                limitsPaint = paint.rgbaComponents.withUnsafeBytes { Data($0) }
                limitsWeight = weight.rgbaComponents.withUnsafeBytes { Data($0) }
            }
        } else if let falseColor = effects.falseColor {
            let key = falseColorCacheKey(falseColor)
            if let cube = LUTCubeCache.cube(
                forKey: key,
                {
                    FalseColorMap.cube(scale: falseColor.scale, mapping: falseColor.mapping)
                })
            {
                dimension = cube.size
                data = cube.rgbaComponents.withUnsafeBytes { Data($0) }
            }
        } else if let lut = effects.lut, let cube = lutCube(lut) {
            dimension = cube.size
            data = cube.rgbaComponents.withUnsafeBytes { Data($0) }
            split = effects.splitComparison
        }

        return ResolvedEffects(
            baseCubeDimension: dimension,
            baseCubeData: data,
            limitsCubeDimension: limitsDimension,
            limitsPaintCubeData: limitsPaint,
            limitsWeightCubeData: limitsWeight,
            peaking: effects.peaking,
            zebra: effects.zebra,
            splitComparison: split
        )
    }

    /// Applies every resolved effect to `source`. Peaking and zebra measure from the original
    /// `source` frame so a grade never changes what reads as in-focus or clipped.
    static func apply(to source: CIImage, effects: ResolvedEffects) -> CIImage {
        let extent = source.extent
        var output = source

        if let dimension = effects.baseCubeDimension, let cubeData = effects.baseCubeData {
            // The composition render context works in DISPLAY-ENCODED sRGB (see
            // `MediaLUT.renderContext`), so `source` already carries the encoded code values the
            // cubes are built for. Do NOT re-add a linear→sRGB "recovery" step: against the
            // encoded working space it gamma-encodes a second time and shoves every pixel into
            // the clip zones.
            output =
                applyBaseCube(to: source, dimension: dimension, cubeData: cubeData).map {
                    splitting(
                        $0, over: source, extent: extent,
                        orientation: effects.splitComparison)
                } ?? source
        }

        if let dimension = effects.limitsCubeDimension,
            let paintData = effects.limitsPaintCubeData,
            let weightData = effects.limitsWeightCubeData
        {
            // The limits zones are measured on encoded code values — which is what the
            // display-encoded working space already delivers (same reasoning as the base cube).
            if let paint = applyBaseCube(
                to: source, dimension: dimension, cubeData: paintData),
                let weight = applyBaseCube(
                    to: source, dimension: dimension, cubeData: weightData)
            {
                output = paint.cropped(to: extent).applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: output.cropped(to: extent),
                        kCIInputMaskImageKey: weight.cropped(to: extent),
                    ])
            }
        }

        if let peaking = effects.peaking {
            output = applyPeaking(over: output, source: source, settings: peaking, extent: extent)
        }
        if let zebra = effects.zebra {
            output = applyZebra(over: output, source: source, settings: zebra, extent: extent)
        }
        return output
    }

    // MARK: - 50/50 Log vs LUT comparison

    /// Restricts `graded` to the LUT half of a 50/50 comparison and lets the untouched `source`
    /// show through the other half. Returns `graded` unchanged when the comparison is off.
    ///
    /// One crop and one pointwise composite — no second decode and no second pipeline. The crop is
    /// what keeps it free: Core Image propagates it back through the region of interest, so the
    /// cube is only ever evaluated over the half that shows it and the graph costs *less* with the
    /// comparison on than without. (`encode` cost in this pipeline is per-node, not per-pixel, and
    /// `CISourceOverCompositing` is pointwise, so Core Image concatenates it into the neighbouring
    /// pass rather than adding one.)
    ///
    /// `extent` is the frame's own rect and the boundary is its centre. Every present path centres
    /// the frame as a whole — the Metal bake takes a centred crop at the drawable's aspect
    /// (`MetalFeedFrameBaker.bakeSize`), the fallbacks are `.scaleAspectFill`, and de-squeeze is a
    /// `.scaleEffect` about the centre — so the middle of the frame is the middle of the visible
    /// image rectangle on screen, with letterbox, pillarbox and chrome all outside it.
    ///
    /// Core Image's y axis points **up**, so the operator's top half is the high-y half.
    static func splitting(
        _ graded: CIImage, over source: CIImage, extent: CGRect,
        orientation: SplitComparisonOrientation?
    ) -> CIImage {
        guard let orientation, extent.width > 0, extent.height > 0 else { return graded }
        let half: CGRect =
            switch orientation {
            case .vertical:
                CGRect(
                    x: extent.midX, y: extent.minY,
                    width: extent.width / 2, height: extent.height)
            case .horizontal:
                CGRect(
                    x: extent.minX, y: extent.minY,
                    width: extent.width, height: extent.height / 2)
            }
        return graded.cropped(to: half).composited(over: source.cropped(to: extent))
    }

    // MARK: - Base look (LUT or false colour)

    private static func applyBaseCube(
        to input: CIImage, dimension: Int, cubeData: Data
    ) -> CIImage? {
        // Match `LiveFrameProcessor`: use `CIColorCube` without an `inputColorSpace` conversion.
        // Proxy and live-view pixels carry log code values, not display-referred colour; running them
        // through `CIColorCubeWithColorSpace` (709/sRGB tagged sources) remaps the codes before the
        // exposure LUT/ZC Stops cube sees them and breaks scopes, zebra, peaking, and false colour.
        guard
            let filter = CIFilter(
                name: "CIColorCube",
                parameters: [
                    "inputCubeDimension": dimension,
                    "inputCubeData": cubeData,
                ])
        else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        return filter.outputImage
    }

    // MARK: - Focus peaking

    /// One Core Image kernel for the whole detector: the two gradient scales, the ratio, the noise
    /// gate and both ramps, in a single pass.
    ///
    /// The filter-chain form below spends its time in Core Image's *graph*, not in pixels. Measured
    /// against the real shipping graph at 1024×576: a bare render is 1.43 ms, adding the LUT makes
    /// it 1.63, adding zebra 1.64 — and adding peaking 8.14. Zebra is free because it is all
    /// pointwise matrices that Core Image concatenates into one pass; peaking is not, because
    /// `CIGaussianBlur`, two `CIEdges` and the two morphology filters each force a pass boundary and
    /// strand the ~20 pointwise nodes between them in passes of their own. That cost is per-NODE,
    /// not per-pixel: it did not move when the render dropped to a fifth of the pixels, and the
    /// simulator reproduces the device's 8.0–8.3 ms to within 2% on a completely different GPU.
    ///
    /// So this collapses the pointwise interior into one kernel — which is what the Android shells
    /// have always been (one fragment shader, 8 taps and some arithmetic). The blur and the closing
    /// stay as stock filters: the blur is a genuine second pass, and closing is a min-of-max that
    /// would need 25 evaluations of everything above it to fold in.
    ///
    /// `CIEdges` is reproduced rather than approximated, and every part of the transcription is
    /// measured, because getting any of it wrong silently invalidates every calibrated constant in
    /// `Peaking` — they all live in its squared domain:
    ///
    /// * It is the **squared Roberts cross**: a 0.2 step gives 0.08 and a 0.4 step 0.32, i.e.
    ///   `d1² + d2²` over the two diagonals — exactly 2·step² for a vertical edge, and a ratio of
    ///   4 between those two steps, which is what rules out a linear operator.
    /// * Taps are the pixel quad anchored at the destination, `+x` and `−y` (the down-right quad in
    ///   image terms, Core Image being bottom-up). Checked against the wrong alternatives: ±0.5
    ///   corner taps bilinear-average and quarter the response, and a central difference spreads it
    ///   over two pixels instead of one.
    /// * That placement is **not** OS-dependent. An earlier revision believed it was and passed the
    ///   sign in as a uniform; the real 18.x divergence was the two uncropped infinite-extent masks
    ///   in the chain (see `ramp`), and the uniform was noise on top of it. A single-bright-pixel
    ///   response pattern pins the quad identically on 18.2 and 26.2.
    ///
    /// `nil` when the kernel does not compile — `CIKernel(source:)` is the Core Image Kernel
    /// Language path, deprecated since iOS 12 and still functional on iOS 26. The chain below is
    /// kept as the fallback precisely so that deprecation can never break the tool.
    private static let fusedPeakingKernel: CIKernel? = makeFusedPeakingKernel()

    /// Verified once, by MEASUREMENT: whether the fused kernel actually reproduces the filter chain
    /// on the OS the app is running on. When it does not, peaking stays on the chain.
    ///
    /// A self-check rather than a version gate, because the chain is built from undocumented Core
    /// Image internals and this kernel had to chase several of them (a quadratic `CIEdges`, taps on
    /// the destination pixel quad, out-of-extent sampling that edge-clamps instead of reading
    /// transparent, and infinite-extent masks whose value beyond the analysed window differs by OS
    /// release). It earned its keep immediately: on iOS 18.2 it refused the kernel, and the reason
    /// turned out to be a latent bug in the CHAIN — a 6 px dark vignette plus a brightened window
    /// perimeter that only appeared on that OS. Both are fixed, both implementations now agree
    /// byte-for-byte on 18.2 and 26.2, and the check stays because the next such difference will
    /// land on an OS nobody has measured yet. Where they disagree the operator gets the chain,
    /// never a subtly wrong overlay.
    private static let fusedPeakingCheck: (matches: Bool, note: String) = {
        let result = verifyAgainstChain()
        Logger(subsystem: "OpenZCine", category: "Peaking").notice(
            "focus peaking detector: \(result.1, privacy: .public)")
        return result
    }()

    /// Why the fused detector is or is not in force on this OS, logged once when it resolves.
    ///
    /// Not diagnostics for their own sake: this check has quietly sent peaking down the slow chain
    /// twice, and without a line in the log "the kernel did not ship" is indistinguishable on a
    /// device from "the kernel shipped and did nothing". One `os_log` at resolution, never per frame.
    static var fusedPeakingNote: String { fusedPeakingCheck.note }

    /// Whether the single-pass detector compiled AND reproduced the chain on this OS —
    /// the equivalence test skips (loudly) when it did not.
    static var fusedPeakingAvailable: Bool {
        fusedPeakingKernel != nil && fusedPeakingCheck.matches
    }

    private static func verifyAgainstChain() -> (Bool, String) {
        guard let kernel = fusedPeakingKernel else { return (false, "kernel did not compile") }
        // Single-pixel strokes both ways on flat grey — horizontal ones are what a wrong vertical
        // tap direction shifts by a row, vertical ones anchor the rest of the formula.
        let w = 96
        let h = 64
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var value = 64
                if x % 7 == 3 { value = 210 }
                if y % 9 == 4 { value = 16 }
                for c in 0..<3 { bytes[(y * w + x) * 4 + c] = UInt8(value) }
            }
        }
        let source = CIImage(
            bitmapData: Data(bytes), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
            format: .RGBA8, colorSpace: nil)
        let extent = source.extent
        let settings = PeakingSettings(color: .red, sensitivity: .medium)
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: false,
        ])
        func rendered(_ image: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            context.render(
                image, toBitmap: &out, rowBytes: w * 4, bounds: extent, format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
            return out
        }
        let chain = rendered(
            applyPeakingFilterChain(
                over: source, source: source, settings: settings, extent: extent))
        // The frame must actually trigger peaking, or a trivially identical pair would "validate"
        // a kernel this probe never exercised.
        let plain = rendered(source)
        let painted = zip(chain, plain).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 2 ? 1 : 0) }
        guard painted > 0 else {
            return (false, "chain fallback — probe frame drew no peaking, so nothing was validated")
        }
        guard
            let fusedImage = applyFusedPeaking(
                kernel: kernel, over: source, source: source, settings: settings, extent: extent)
        else { return (false, "chain fallback — kernel apply returned nil") }
        let fused = rendered(fusedImage)
        var worst = 0
        var differing = 0
        for i in 0..<chain.count {
            let d = abs(Int(chain[i]) - Int(fused[i]))
            worst = max(worst, d)
            if d > 2 { differing += 1 }
        }
        guard worst <= 2 else {
            return (
                false,
                "chain fallback — worst \(worst)/255 over \(differing) channels (chain painted "
                    + "\(painted))"
            )
        }
        return (true, "fused (chain painted \(painted) channels, worst delta \(worst)/255)")
    }

    // MARK: - Block-artifact suppression

    /// Variance-gated smoothing: pulls each pixel toward a local mean, but only where the
    /// neighbourhood is flat enough that there is no real detail to lose.
    ///
    /// Deliberately **grid-free**. A boundary filter that keys on the JPEG 8×8 lattice is cheaper
    /// per pixel, but it has to know the grid phase — and the phase moves under cropping, and moved
    /// on Android for as long as the decoder was halving the frame. A filter aimed at the wrong
    /// phase does nothing while looking like it works. This one keys on the only thing that is
    /// always true: blocking is visible *because* it sits in smooth areas, so smooth areas are
    /// where it is safe and sufficient to filter.
    ///
    /// Nine taps on a sparse 5×5 lattice (offsets 0, ±`r`) rather than a dense 25. Undersampling
    /// aliases high frequencies, which is exactly the content the flatness gate has already
    /// excluded — so the sparse lattice buys a 5 px span, wide enough to flatten an 8 px block
    /// step into a ramp, at 3×3 cost.
    private static let flatSmoothKernel: CIKernel? = CIKernel(
        source: """
            kernel vec4 flatSmooth(sampler src, float r, float gateGain, float strength) {
              vec2 p = destCoord();
              vec4 c4 = sample(src, samplerTransform(src, p));
              vec4 c0 = sample(src, samplerTransform(src, p + vec2(-r, -r)));
              vec4 c1 = sample(src, samplerTransform(src, p + vec2(0.0, -r)));
              vec4 c2 = sample(src, samplerTransform(src, p + vec2( r, -r)));
              vec4 c3 = sample(src, samplerTransform(src, p + vec2(-r, 0.0)));
              vec4 c5 = sample(src, samplerTransform(src, p + vec2( r, 0.0)));
              vec4 c6 = sample(src, samplerTransform(src, p + vec2(-r,  r)));
              vec4 c7 = sample(src, samplerTransform(src, p + vec2(0.0,  r)));
              vec4 c8 = sample(src, samplerTransform(src, p + vec2( r,  r)));
              vec4 mean = (c0 + c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8) / 9.0;
              vec3 w = vec3(0.2126, 0.7152, 0.0722);
              float m = dot(mean.rgb, w);
              // Mean absolute deviation, not variance: same decision, no squaring, and it stays in
              // code-value units so the gate is readable as "levels out of 255".
              float dev = abs(dot(c0.rgb, w) - m) + abs(dot(c1.rgb, w) - m)
                        + abs(dot(c2.rgb, w) - m) + abs(dot(c3.rgb, w) - m)
                        + abs(dot(c4.rgb, w) - m) + abs(dot(c5.rgb, w) - m)
                        + abs(dot(c6.rgb, w) - m) + abs(dot(c7.rgb, w) - m)
                        + abs(dot(c8.rgb, w) - m);
              dev = dev / 9.0;
              float flatness = clamp(1.0 - dev * gateGain, 0.0, 1.0);
              return vec4(mix(c4.rgb, mean.rgb, flatness * strength), c4.a);
            }
            """)

    /// Adds a small amount of per-pixel noise to break up the periodicity of what blocking is left.
    ///
    /// This does not remove error, it makes the remaining error harder to *detect*, which is a
    /// different and much cheaper goal. Blocking is objectionable out of proportion to its magnitude
    /// because it is a regular lattice and the visual system locks onto periodic structure; measured
    /// against ground truth, a boundary filter moved PSNR by +0.06 dB while dropping the blockiness
    /// ratio from 1.85 to 1.50. Magnitude was never the thing that mattered. AV1 ships film-grain
    /// synthesis as a normative feature for the same reason.
    ///
    /// Applied at **source** resolution, after the look. That reads like the wrong place for a
    /// masker — the eye sees display pixels — but the artifact and the noise are magnified by the
    /// same uniform upscale, so their spatial-frequency relationship is preserved exactly, and it
    /// costs no extra full-drawable pass.
    ///
    /// White noise via a hash, not blue noise: blue noise masks better per unit visibility, but it
    /// needs a texture to sample and this needs nothing. Upgrade path if it reads as too coarse.
    private static let ditherKernel: CIKernel? = CIKernel(
        source: """
            kernel vec4 blockDither(sampler src, float amplitude) {
              vec2 p = destCoord();
              vec4 c = sample(src, samplerTransform(src, p));
              float n = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
              return vec4(c.rgb + (n - 0.5) * amplitude, c.a);
            }
            """)

    /// Smooths flat regions of `source` to soften block steps, leaving detail untouched. Returns
    /// `source` unchanged when the kernel is unavailable — never drops the frame.
    ///
    /// The caller must keep this OFF the measurement path: zebras would under-report clipping and
    /// peaking would measure its own smoothing. See `LiveFrameProcessor.outputCIImage`.
    static func applyFlatSmoothing(
        to source: CIImage, settings: BlockSmoothingSettings, extent: CGRect
    ) -> CIImage {
        guard let kernel = flatSmoothKernel, settings.strength > 0 else { return source }
        let clamped = source.clampedToExtent()
        guard
            let smoothed = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -settings.radius, dy: -settings.radius)
                },
                arguments: [
                    clamped,
                    settings.radius,
                    // Gate expressed as "levels out of 255" at the call site; the kernel wants its
                    // reciprocal so the comparison is a multiply.
                    1.0 / max(settings.gateLevels / 255.0, 1e-6),
                    settings.strength,
                ])
        else { return source }
        return smoothed.cropped(to: extent)
    }

    /// Adds masking noise over `image`. Returns `image` unchanged when the kernel is unavailable.
    static func applyDither(
        to image: CIImage, settings: BlockDitherSettings, extent: CGRect
    ) -> CIImage {
        guard let kernel = ditherKernel, settings.levels > 0 else { return image }
        guard
            let dithered = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect },
                arguments: [image.clampedToExtent(), settings.levels / 255.0])
        else { return image }
        return dithered.cropped(to: extent)
    }

    private static func makeFusedPeakingKernel() -> CIKernel? {
        // Deprecated initialiser, deliberately: the Metal route needs a new `.ci.metal` file plus
        // `-fcikernel`/`-cikernel` build flags in the target, and this needs no build inputs at all.
        CIKernel(
            source: """
                float robertsSquared(sampler s, vec2 p) {
                  float a = sample(s, samplerTransform(s, p)).r;
                  float b = sample(s, samplerTransform(s, p + vec2(1.0,  0.0))).r;
                  float c = sample(s, samplerTransform(s, p + vec2(0.0, -1.0))).r;
                  float d = sample(s, samplerTransform(s, p + vec2(1.0, -1.0))).r;
                  float d1 = d - a;
                  float d2 = c - b;
                  return d1 * d1 + d2 * d2;
                }

                kernel vec4 peakingMask(
                    sampler grey, sampler blurred,
                    float ratioScale, float gateGain, float gateBias,
                    float rampGain, float coreBias, float underBias,
                    vec2 lo, vec2 hi) {
                  vec2 p = destCoord();
                  float fine = robertsSquared(grey, p);
                  float coarse = robertsSquared(blurred, p);
                  // CIDivideBlendMode saturates at 1, which is why the numerator is pre-shrunk by
                  // `ratioScale` and the thresholds are shrunk to match. Reproduced, not removed.
                  float ratio = min(fine * ratioScale / max(coarse, 1e-9), 1.0);
                  // Noise is not lens-blurred, so it always reads as perfectly sharp; only this
                  // gate on the coarse magnitude keeps shadow grain from painting.
                  float gate = clamp(coarse * gateGain + gateBias, 0.0, 1.0);
                  float core = clamp(ratio * rampGain + coreBias, 0.0, 1.0) * gate;
                  float under = clamp(ratio * rampGain + underBias, 0.0, 1.0) * gate;
                  // Arithmetic window to the edge-inset rect, in the kernel's own domain. Nothing
                  // downstream may rely on out-of-extent sampling of a kernel image: measured on
                  // iOS 26.2 it edge-clamps rather than reading transparent black (a black pad
                  // composited underneath never showed through, and the closing kept a border
                  // halo). The kernel is therefore applied over a rect LARGER than the window, so
                  // the zero ring is real pixels. step() products, not an if: CIKL miscompiled a
                  // uniform branch in this very kernel's development.
                  float window = step(lo.x, p.x) * step(lo.y, p.y)
                      * (1.0 - step(hi.x, p.x)) * (1.0 - step(hi.y, p.y));
                  return vec4(core * window, under * window, 0.0, 1.0);
                }
                """)
    }

    /// Thin, strict peaking on the two-scale gradient RATIO (see `Peaking` in shared core).
    /// Amplitude cancels, so a bright defocused bokeh rim no longer outranks dim in-focus
    /// detail. Measured on the raw source — the de-log that used to run here clamped the top
    /// quarter of the range flat and made in-focus highlight detail undetectable.
    ///
    /// Runs the fused kernel when it is available and the equivalent filter chain when it is not;
    /// the two are verified pixel-for-pixel against each other in `RunnerTests`.
    static func applyPeaking(
        over base: CIImage, source: CIImage, settings: PeakingSettings, extent: CGRect
    ) -> CIImage {
        if let kernel = fusedPeakingKernel, fusedPeakingCheck.matches,
            let fused = applyFusedPeaking(
                kernel: kernel, over: base, source: source, settings: settings, extent: extent)
        {
            return fused
        }
        return applyPeakingFilterChain(
            over: base, source: source, settings: settings, extent: extent)
    }

    /// Single-pass detector. Returns `nil` if the kernel cannot be applied, so the caller falls
    /// back to the filter chain rather than dropping the overlay.
    private static func applyFusedPeaking(
        kernel: CIKernel, over base: CIImage, source: CIImage, settings: PeakingSettings,
        extent: CGRect
    ) -> CIImage? {
        let threshold = settings.sensitivity.ratioThreshold
        let gate = settings.sensitivity.noiseGate * settings.gateScale
        let aa = Peaking.antialiasWidth
        let ratioScale = Peaking.ratioScale
        let cropped = extent.insetBy(dx: Peaking.edgeInset, dy: Peaking.edgeInset)

        let grey = greyscale(source).clampedToExtent()
        let blurred = grey.applyingFilter(
            "CIGaussianBlur", parameters: [kCIInputRadiusKey: Peaking.reblurRadius])

        // Same gains and biases the chain's `CIColorMatrix` + `CIColorClamp` pairs encode.
        let gateGain = 1.0 / max(gate * (1 - Peaking.gateRampFloor), 1e-6)
        let rampGain = 1.0 / max(aa * ratioScale, 1e-6)
        // Applied over a rect larger than the visible window so the kernel's arithmetic zero ring
        // (see the kernel source) is real pixels — every downstream consumer (closing, broadcast,
        // blend) then reads genuine zeros at and beyond the inset boundary regardless of how CI
        // treats sampling past a kernel image's extent.
        guard
            let mask = kernel.apply(
                extent: cropped.insetBy(dx: -2, dy: -2),
                roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
                arguments: [
                    grey, blurred,
                    ratioScale, gateGain, -(gate * Peaking.gateRampFloor) * gateGain,
                    rampGain, -(threshold * ratioScale) * rampGain,
                    -((threshold - aa * Peaking.underRampOffset) * ratioScale) * rampGain,
                    CIVector(x: cropped.minX, y: cropped.minY),
                    CIVector(x: cropped.maxX, y: cropped.maxY),
                ])
        else { return nil }

        // Closing on the CORE channel only — the under hairline stays as the kernel drew it, which
        // is what the chain does (see `smoothed` below for why closing and not opening). The
        // erosion reads the kernel's in-domain zero ring at the inset boundary — the same zeros
        // the chain's alpha-biased infinite intermediates carry there — so both erode the border
        // row identically.
        let closed: CIImage
        if Peaking.maskClosingRadius > 0 {
            closed =
                mask
                .applyingFilter(
                    "CIMorphologyMaximum",
                    parameters: [kCIInputRadiusKey: Peaking.maskClosingRadius]
                )
                .applyingFilter(
                    "CIMorphologyMinimum",
                    parameters: [kCIInputRadiusKey: Peaking.maskClosingRadius]
                )
                .cropped(to: cropped)
        } else {
            closed = mask
        }

        return composite(
            over: base, coreMask: broadcast(.red, of: closed),
            underMask: broadcast(.green, of: mask), color: settings.color, extent: extent)
    }

    /// Splats one channel across RGB with opaque alpha, so a packed mask channel can drive
    /// `CIBlendWithMask`.
    private static func broadcast(_ channel: MaskChannel, of image: CIImage) -> CIImage {
        let vector =
            channel == .red
            ? CIVector(x: 1, y: 0, z: 0, w: 0) : CIVector(x: 0, y: 1, z: 0, w: 0)
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": vector,
                "inputGVector": vector,
                "inputBVector": vector,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    private enum MaskChannel { case red, green }

    /// Rec. 601-free flat average — the detector wants equal channel weight, not luma.
    private static func greyscale(_ source: CIImage) -> CIImage {
        let third = 1.0 / 3.0
        return source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputGVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputBVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    /// Paints the dark hairline under the stroke, then the stroke — shared by both detectors.
    private static func composite(
        over base: CIImage, coreMask: CIImage, underMask: CIImage, color: Peaking.Color,
        extent: CGRect
    ) -> CIImage {
        let under = Peaking.underColor
        let dark = CIImage(
            color: CIColor(red: under.red, green: under.green, blue: under.blue)
        ).cropped(to: extent)
        let (red, green, blue) = color.rgb
        let tint = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: extent)
        let withUnder =
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: dark, kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: underMask,
                ])?.outputImage ?? base)
            .cropped(to: extent)
        return
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: tint, kCIInputBackgroundImageKey: withUnder,
                    kCIInputMaskImageKey: coreMask,
                ])?.outputImage ?? withUnder)
            .cropped(to: extent)
    }

    /// Reference implementation and fallback. Kept because it is the calibration ground truth: every
    /// constant in `Peaking` was measured against this graph, and the fused kernel above is checked
    /// against it rather than the other way round.
    static func applyPeakingFilterChain(
        over base: CIImage, source: CIImage, settings: PeakingSettings, extent: CGRect
    ) -> CIImage {
        let threshold = settings.sensitivity.ratioThreshold
        let gate = settings.sensitivity.noiseGate * settings.gateScale
        let aa = Peaking.antialiasWidth
        let edgeInset = Peaking.edgeInset

        let grey = greyscale(source).clampedToExtent()

        let cropped = extent.insetBy(dx: edgeInset, dy: edgeInset)
        // Fine scale: the operator straight off the source. Coarse scale: the same operator on a
        // re-blurred copy. Their ratio depends only on how defocused the edge is.
        let fine =
            grey
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
            .cropped(to: cropped)
        let coarse =
            grey
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Peaking.reblurRadius])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
            .cropped(to: cropped)

        /// Scales every colour channel, leaving alpha opaque. Pure linear — no clamping.
        func scale(_ image: CIImage, by factor: Double, bias: Double = 0) -> CIImage {
            image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
                ])
        }

        // The divide blend saturates at 1, so shrink the numerator first and compare against a
        // correspondingly shrunk threshold; otherwise every sharp edge clamps to the same value.
        let ratioScale = Peaking.ratioScale
        let ratio =
            (CIFilter(
                name: "CIDivideBlendMode",
                parameters: [
                    kCIInputImageKey: coarse,
                    kCIInputBackgroundImageKey: scale(fine, by: ratioScale),
                ])?.outputImage ?? coarse)
            .cropped(to: cropped)

        // Noise is not lens-blurred, so it always reads as perfectly sharp. Only this gate — on
        // the coarse magnitude — keeps shadow grain from painting.
        let gateGain = 1.0 / max(gate * (1 - Peaking.gateRampFloor), 1e-6)
        let gateMask =
            scale(coarse, by: gateGain, bias: -(gate * Peaking.gateRampFloor) * gateGain)
            .applyingFilter("CIColorClamp")

        /// Cropped to the analysed window, and that crop is load-bearing rather than tidy: `scale`
        /// and `CIColorClamp` carry an alpha bias, which makes their output INFINITE-extent, and
        /// what it evaluates to beyond the window turns out to be OS-dependent — measured 0 on iOS
        /// 26.2 but 1 on iOS 18.2. Uncropped, that 1 reached both consumers: the under mask painted
        /// the dark hairline colour over the whole `Peaking.edgeInset` border as a 6 px vignette,
        /// and `smoothed`'s dilation pulled it one pixel further in, brightening the window's
        /// outermost row and column. Both were invisible on 26.2 and wrong on 18.2.
        func ramp(from start: Double) -> CIImage {
            let gain = 1.0 / max(aa * ratioScale, 1e-6)
            let masked =
                scale(ratio, by: gain, bias: -(start * ratioScale) * gain)
                .applyingFilter("CIColorClamp")
            return
                (CIFilter(
                    name: "CIMultiplyCompositing",
                    parameters: [
                        kCIInputImageKey: masked, kCIInputBackgroundImageKey: gateMask,
                    ])?.outputImage ?? masked)
                .cropped(to: cropped)
        }

        /// Morphological closing on the finished overlay — dilate, then erode.
        ///
        /// A strict gate is the only thing that removes grain (the ratio cannot: unblurred noise
        /// reads as perfectly sharp), but its cost is punching holes in edges that ARE sharp, and
        /// a line broken into dashes reads as more noise than a continuous line even with less
        /// ink on screen. Closing rejoins the dashes without inventing a line where there was
        /// none, which is what makes a wide sensitivity range usable at all — see
        /// `Peaking.maskClosingRadius`.
        ///
        /// Closing and not opening: the strokes are about a pixel wide, so eroding first would
        /// take the lines with the specks.
        func smoothed(_ mask: CIImage) -> CIImage {
            let radius = Peaking.maskClosingRadius
            guard radius > 0 else { return mask }
            return
                mask
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: cropped)
        }

        // Closed on the core stroke only. Morphology is two more filters in a graph that is
        // rebuilt and re-rendered every frame, and the under-mask is a hairline drawn at 28%
        // opacity — closing it costs the same as closing the visible stroke and buys almost
        // nothing. Halves the added per-frame cost.
        let coreMask = smoothed(ramp(from: threshold))
        // The ramp is already grey with opaque alpha, so it needs no channel splat.
        let underMask = ramp(from: threshold - aa * Peaking.underRampOffset)

        return composite(
            over: base, coreMask: coreMask, underMask: underMask, color: settings.color,
            extent: extent)
    }

    // MARK: - Zebra

    static func applyZebra(
        over base: CIImage, source: CIImage, settings: ZebraSettings, extent: CGRect
    ) -> CIImage {
        let luma = zebraLuma(from: source)
        var output = base
        if settings.highlightEnabled {
            let threshold =
                ExposureScale.signalNative(
                    monitorPercent: settings.highlightIRE, mapping: settings.mapping)
                / 255.0
            let mask = highlightMask(luma: luma, threshold: threshold)
            output = blendStripedZebra(
                over: output, mask: mask, color: settings.highlightColor, extent: extent)
        }
        if settings.midtoneEnabled {
            let centre = midtoneComparisonNative(settings: settings) / 255.0
            let mask = midtoneBandMask(luma: luma, centre: centre, halfWidth: 5.0 / 255.0)
            output = blendStripedZebra(
                over: output, mask: mask, color: settings.midtoneColor, extent: extent)
        }
        return output
    }

    /// Resolves the midtone band centre on the native code-value axis.
    private static func midtoneComparisonNative(settings: ZebraSettings) -> Double {
        switch settings.unit {
        case .ire:
            ExposureScale.signalNative(
                monitorPercent: settings.midtoneIRE, mapping: settings.mapping)
        case .native:
            // Stored threshold remains on the common 0–100 axis; only its editor displays native code.
            ExposureScale.signalNative(
                monitorPercent: settings.midtoneIRE, mapping: settings.mapping)
        }
    }

    private static func falseColorCacheKey(_ settings: FalseColorSettings) -> String {
        "false:\(settings.scale.rawValue):\(settings.curve.rawValue):\(settings.mapping.clipNative)"
    }

    private static func zebraLuma(from source: CIImage) -> CIImage {
        source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    private static func highlightMask(luma: CIImage, threshold: Double) -> CIImage {
        let gain = 40.0
        return
            luma
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(
                        x: -threshold * gain, y: -threshold * gain, z: -threshold * gain, w: 1),
                ]
            )
            .applyingFilter("CIColorClamp")
    }

    /// Band mask that peaks when luma sits within `halfWidth` of `centre` (prototype ±5 native).
    private static func midtoneBandMask(luma: CIImage, centre: Double, halfWidth: Double) -> CIImage
    {
        let gain = 40.0
        let lower = centre - halfWidth
        let upper = centre + halfWidth
        let lowSide =
            luma
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(
                        x: -lower * gain, y: -lower * gain, z: -lower * gain, w: 1),
                ]
            )
            .applyingFilter("CIColorClamp")
        let highSide =
            luma
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(
                        x: upper * gain, y: upper * gain, z: upper * gain, w: 1),
                ]
            )
            .applyingFilter("CIColorClamp")
        return lowSide.applyingFilter(
            "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: highSide])
    }

    private static func blendStripedZebra(
        over base: CIImage, mask: CIImage, color: AssistConfiguration.Zebra.StripeColor,
        extent: CGRect
    ) -> CIImage {
        let stripes =
            (CIFilter(
                name: "CIStripesGenerator",
                parameters: [
                    "inputColor0": CIColor(red: 0, green: 0, blue: 0),
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1),
                    "inputWidth": 5.0,
                    "inputSharpness": 1.0,
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                ])?.outputImage ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1)))
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: extent)
        let stripedMask = stripes.applyingFilter(
            "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        let (red, green, blue) = zebraRGB(color)
        let tint = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: extent)
        return
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: tint,
                    kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: stripedMask,
                ])?.outputImage ?? base)
            .cropped(to: extent)
    }

    private static func zebraRGB(_ color: AssistConfiguration.Zebra.StripeColor) -> (
        Double, Double, Double
    ) {
        switch color {
        case .white: (1, 1, 1)
        case .amber: (1, 0.72, 0.2)
        case .red: (1, 0.15, 0.15)
        case .cyan: (0, 0.85, 0.9)
        case .green: (0.2, 0.9, 0.35)
        }
    }
}

extension NativeAppModel {
    /// Resolves the operator's current assist settings into a sendable payload for playback
    /// `AVVideoComposition`.
    func resolvedPlaybackEffects() -> ImageEffectsCompositor.ResolvedEffects {
        ImageEffectsCompositor.resolve(playbackImageEffects) { selection in
            switch selection {
            case .builtIn(let look): return look.cube()
            case .stored(let category, let fileName):
                return lutFileStore.cube(category: category, fileName: fileName)
            }
        }
    }
}
