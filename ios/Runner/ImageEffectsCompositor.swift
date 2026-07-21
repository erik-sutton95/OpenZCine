import CoreImage
import Foundation

/// Shared Core Image pipeline for monitor analysis effects (false colour, LUT, peaking, zebra).
/// Used by the live-view renderer and media-playback `AVVideoComposition` so both paths share the
/// same thresholds and colour mapping.
enum ImageEffectsCompositor {
    /// Marks the mock feed as log-encoded so peaking de-logs it (see `applyPeaking`).
    private static let demoLogFeed = DemoHarness.logFeed

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

        if let falseColor = effects.falseColor, falseColor.scale == .limits {
            // Limits keeps the monitor's normal look between the zones: the base stays the
            // selected LUT (or the untouched feed) and the crush/clip paint composites on top.
            if let lut = effects.lut, let cube = lutCube(lut) {
                dimension = cube.size
                data = cube.rgbaComponents.withUnsafeBytes { Data($0) }
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
        }

        return ResolvedEffects(
            baseCubeDimension: dimension,
            baseCubeData: data,
            limitsCubeDimension: limitsDimension,
            limitsPaintCubeData: limitsPaint,
            limitsWeightCubeData: limitsWeight,
            peaking: effects.peaking,
            zebra: effects.zebra
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
                applyBaseCube(to: source, dimension: dimension, cubeData: cubeData) ?? source
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

    /// Thin, strict first-derivative peaking (Android GLES parity).
    /// Sobel-class edges via mild blur + CIEdges, hard threshold (narrow AA),
    /// hairline under-stroke only. Log feeds de-logged first (redLog3G10).
    static func applyPeaking(
        over base: CIImage, source: CIImage, settings: PeakingSettings, extent: CGRect
    ) -> CIImage {
        // Match Android: threshold×0.06 × 30, clamped — stricter Med for set use.
        let threshold = min(0.14, max(0.045, settings.threshold * 0.06 * 30.0))
        let aa = threshold * 0.10  // narrow AA — thin strokes
        // Minimal denoise: CIEdges alone is noisy; ~0.2 keeps ridges thin.
        let noiseFloorRadius = 0.2
        let edgeInset: CGFloat = 6

        var source = source
        if demoLogFeed {
            var encode: [String: Any] = [:]
            for i in 0...4 {
                let x = Double(i) / 4
                encode["inputPoint\(i)"] = CIVector(
                    x: x,
                    y: ExposureScale.signalNative(referenceIRE: x * 100, curve: .redLog3G10) / 255)
            }
            source = source.applyingFilter("CIToneCurve", parameters: encode)
        }

        let third = 1.0 / 3.0
        let grey =
            source
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: third, y: third, z: third, w: 0),
                    "inputGVector": CIVector(x: third, y: third, z: third, w: 0),
                    "inputBVector": CIVector(x: third, y: third, z: third, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]
            )
            .clampedToExtent()

        var deLog: [String: Any] = [:]
        for i in 0...4 {
            let x = Double(i) / 4
            deLog["inputPoint\(i)"] = CIVector(
                x: x, y: ExposureScale.referenceIRE(signalNative: x * 255, curve: .redLog3G10) / 100
            )
        }
        let deLogged = grey.applyingFilter("CIToneCurve", parameters: deLog)

        let edges =
            deLogged
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: noiseFloorRadius])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
            .cropped(to: extent.insetBy(dx: edgeInset, dy: edgeInset))

        // Narrow AA band only — thin strokes, not soft highlighter.
        let gain = 1.0 / max(aa, 0.008)
        let bias = -threshold * gain
        let coreMask =
            edges
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
                ]
            )
            .applyingFilter("CIColorClamp")
        let underGain = gain * 1.2
        let underBias = -(threshold - aa * 0.5) * underGain
        let underMask =
            edges
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: underGain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: underGain, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: underGain, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: underBias, y: underBias, z: underBias, w: 1),
                ]
            )
            .applyingFilter("CIColorClamp")

        let dark =
            CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: extent)
        let (red, green, blue) = settings.color.rgb
        let tint = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: extent)

        // Hairline under only where core is not already solid.
        let underOnly =
            underMask
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]
            )
        let withUnder =
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: dark, kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: underOnly,
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
