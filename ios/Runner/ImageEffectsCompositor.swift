import CoreImage
import Foundation
import OpenCineApple
import OpenCineMedia
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
                {
                    FalseColorMap.limitsPaintCube(
                        mapping: falseColor.mapping, read709: falseColor.read709)
                }),
                let weight = LUTCubeCache.cube(
                    forKey: "limitsWeight:\(key)",
                    {
                        FalseColorMap.limitsWeightCube(
                            mapping: falseColor.mapping, read709: falseColor.read709)
                    })
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
                    FalseColorMap.cube(
                        scale: falseColor.scale, mapping: falseColor.mapping,
                        read709: falseColor.read709)
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
    /// (`MonitorFrameBaker.bakeSize`), the fallbacks are `.scaleAspectFill`, and de-squeeze is a
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

    static func applyFlatSmoothing(
        to source: CIImage, settings: BlockSmoothingSettings, extent: CGRect
    ) -> CIImage {
        MonitorBlockArtifactCompositor.applyFlatSmoothing(
            to: source,
            settings: MonitorBlockSmoothing(
                radius: settings.radius, gateLevels: settings.gateLevels,
                strength: settings.strength),
            extent: extent)
    }

    static func applyDither(
        to image: CIImage, settings: BlockDitherSettings, extent: CGRect
    ) -> CIImage {
        MonitorBlockArtifactCompositor.applyDither(
            to: image, settings: MonitorBlockDither(levels: settings.levels), extent: extent)
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
        MonitorImageCompositor.applyResolvedZebra(
            over: base, source: source, extent: extent, zebra: resolvedZebra(settings: settings))
    }

    /// The shared zebra zones for this camera's transfer and clip (A1-40): the highlight on the
    /// hottest channel up to the clip shelf, the midtone band on luma, as on every app.
    static func resolvedZebra(settings: ZebraSettings) -> MonitorCodeZebraSpec {
        let mapping = settings.mapping
        return MonitorCodeZebraSpec(
            MonitorZebraSpec(
                highlightEnabled: settings.highlightEnabled, highlightIRE: settings.highlightIRE,
                highlightColor: MonitorRGB(settings.highlightColor.rgb),
                midtoneEnabled: settings.midtoneEnabled, midtoneIRE: settings.midtoneIRE,
                midtoneColor: MonitorRGB(settings.midtoneColor.rgb)),
            transfer: mapping.curve.monitorTransfer, clipByte: mapping.clipByte)
    }

    private static func falseColorCacheKey(_ settings: FalseColorSettings) -> String {
        "false:\(settings.scale.rawValue):\(settings.curve.rawValue):\(settings.mapping.clipNative):\(settings.read709)"
    }
}
