import CoreImage
import Foundation
import OpenCineApple
import OpenZCineCore
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
            if let lut = effects.lut, let cube = lutCube(lut)?.preparedForRenderer() {
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
        } else if let lut = effects.lut, let cube = lutCube(lut)?.preparedForRenderer() {
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

    // MARK: - Shared focus peaking owner

    /// Source diagnostics retain their app namespace; the shared owner performs qualification.
    private static let fusedPeakingCheck: (matches: Bool, note: String) = {
        let note = MonitorImageCompositor.fusedPeakingNote
        Logger(subsystem: "OpenZCine", category: "Peaking").notice(
            "focus peaking detector: \(note, privacy: .public)")
        return (MonitorImageCompositor.fusedPeakingAvailable, note)
    }()

    static var fusedPeakingNote: String { fusedPeakingCheck.note }
    static var fusedPeakingAvailable: Bool { fusedPeakingCheck.matches }

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

    /// Existing source settings remain values; the shared native owner builds both detector graphs.
    static func applyPeaking(
        over base: CIImage, source: CIImage, settings: PeakingSettings, extent: CGRect
    ) -> CIImage {
        _ = fusedPeakingCheck
        return MonitorImageCompositor.applyPeaking(
            over: base, source: source, extent: extent,
            color: MonitorRGB(settings.color.rgb),
            sense: MonitorPeakingSensitivity(
                ratioThreshold: settings.sensitivity.ratioThreshold,
                noiseGate: settings.sensitivity.noiseGate),
            gateScale: settings.gateScale, fusedWindowPolicy: .admittedKernel)
    }

    static func applyPeakingFilterChain(
        over base: CIImage, source: CIImage, settings: PeakingSettings, extent: CGRect
    ) -> CIImage {
        MonitorImageCompositor.applyPeakingFilterChain(
            over: base, source: source, extent: extent,
            color: MonitorRGB(settings.color.rgb),
            sense: MonitorPeakingSensitivity(
                ratioThreshold: settings.sensitivity.ratioThreshold,
                noiseGate: settings.sensitivity.noiseGate),
            gateScale: settings.gateScale)
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
                return lutFileStore.cube(category: category, fileName: fileName)?
                    .preparedForRenderer()
            }
        }
    }
}
