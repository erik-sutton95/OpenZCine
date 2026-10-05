import CoreImage
import OpenZCineCore
import UIKit

@testable import Runner

final class FrozenNikonUIImageGraphProcessor {
    // 16-bit half-float pipeline + matching output so cube interpolation and the composites don't
    // posterize, and Core Animation dithers the result down to the panel (see the LUT banding fix).
    // The working space is sRGB; camera inputs are explicitly marked unmanaged below so the LUT,
    // false-colour, zebra, and peaking tools receive encoded code values instead of an automatic
    // sRGB→linear conversion. That is the domain `ExposureScale` and the `.cube` files use.
    private static let displaySpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let context = CIContext(options: [
        // 8-bit, not half-float. The half-float working space was chosen to stop LUT
        // banding when the frame was read back and handed to a UIImageView; presenting
        // straight to an 8-bit panel removes that reason and halves the bandwidth of every
        // Core Image intermediate — which is the dominant per-frame cost. `MediaLUTExport`
        // deliberately stays at RGBAh: it writes files, where banding matters and a
        // millisecond does not.
        .workingFormat: CIFormat.BGRA8,
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
                output, from: output.extent, format: .BGRA8, colorSpace: outputColorSpace)
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

        // The block filters run on the DISPLAY path only. `input` stays the pristine decode because
        // three things below measure it rather than show it: zebras would under-report clipping if
        // handed smoothed code values, false colour would mis-assign exposure zones, and peaking —
        // which measures blur RADIUS since 15d1186 — would end up measuring its own smoothing.
        // Splitting here is what lets the operator see a deblocked image while every assist keeps
        // reading what the sensor actually sent, so none of them need recalibrating.
        //
        // Smoothing goes BEFORE the look on purpose: blocking is uniform in the encoded domain, and
        // a shadow-lifting tone curve amplifies it non-uniformly. Filter it where it is still flat.
        // Dither goes AFTER, for the opposite reason — see `applyDither`.
        var display = input
        if let smoothing = effects.blockSmoothing {
            display = FrozenNikonRuntimeEffects.applyFlatSmoothing(
                to: input, settings: smoothing, extent: extent)
        }

        var output = display
        if let falseColor = effects.falseColor, falseColor.scale == .limits {
            // Limits keeps the monitor's normal look between the zones: grade first (the selected
            // LUT, or the untouched feed), then composite the crush/clip paint on top through a
            // zone-weight mask. Both limits cubes measure the raw code values in `input`; only the
            // graded background the operator looks at comes off the smoothed `display`.
            if let lut = effects.lut {
                output = FrozenNikonRuntimeEffects.splitting(
                    applyBaseCube(to: display, key: lut.cacheKey) { self.cube(for: lut) },
                    over: display, extent: extent, orientation: effects.splitComparison)
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
            // Grade only the LUT half when a 50/50 comparison is on. Peaking and zebra below still
            // measure `input`, so the assists read the same across the boundary. Both halves come
            // off `display`, so the comparison varies the grade and nothing else.
            output = FrozenNikonRuntimeEffects.splitting(
                applyBaseCube(to: display, key: lut.cacheKey) { self.cube(for: lut) },
                over: display, extent: extent, orientation: effects.splitComparison)
        }

        // After the look — the noise has to sit in the same space as the artifact it masks, and the
        // tone curve has already stretched both. Before the overlays, so peaking and zebra paint
        // stays clean rather than picking up grain.
        if let dither = effects.blockDither {
            output = FrozenNikonRuntimeEffects.applyDither(
                to: output, settings: dither, extent: extent)
        }

        if let peaking = effects.peaking {
            output = FrozenNikonRuntimeEffects.applyPeaking(
                over: output, source: input, settings: peaking, extent: extent)
        }
        if let zebra = effects.zebra {
            output = FrozenNikonRuntimeEffects.applyZebra(
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
        } else if let cube = LUTCubeCache.cube(forKey: key, makeCube)?.preparedForRenderer() {
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
