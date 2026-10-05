import CoreImage
import OpenCineApple
import OpenZCineCore
import UIKit
import XCTest
import os

@testable import Runner

final class NikonPeakingTinyWindowParityTests: XCTestCase {
    func testDecodedTinyWindowsPreserveActualDonorAndComposedPixels() throws {
        XCTAssertEqual(
            FrozenNikonPeakingDonor.fusedPeakingAvailable,
            ImageEffectsCompositor.fusedPeakingAvailable,
            "The real donor and shared runtime must admit the same normal-window detector")
        for workingFormat in [CIFormat.BGRA8, CIFormat.RGBAf] {
            let context = renderContext(workingFormat: workingFormat)
            for size in windows {
                let source = try decodedProbe(width: size.0, height: size.1)
                for sensitivity in Peaking.Sensitivity.allCases {
                    for color in Peaking.Color.allCases {
                        for gateScale in [1.0, 4.0] {
                            let settings = PeakingSettings(
                                color: color, sensitivity: sensitivity, gateScale: gateScale)
                            let donor = FrozenNikonPeakingDonor.applyPeaking(
                                over: source, source: source, settings: settings,
                                extent: source.extent)
                            let composed = ImageEffectsCompositor.applyPeaking(
                                over: source, source: source, settings: settings,
                                extent: source.extent)
                            assertPixels(
                                render(donor, with: context, extent: source.extent),
                                render(composed, with: context, extent: source.extent),
                                maximumDelta: 2,
                                note: "actual donor \(size), \(workingFormat), \(sensitivity), "
                                    + "\(color), gate \(gateScale)")
                        }
                    }
                }
            }
        }
    }

    func testDecodedTinyWindowChainFallbackIsExactlyTheFrozenDonor() throws {
        let context = renderContext(workingFormat: .BGRA8)
        for size in windows {
            let source = try decodedProbe(width: size.0, height: size.1)
            for sensitivity in Peaking.Sensitivity.allCases {
                let settings = PeakingSettings(color: .green, sensitivity: sensitivity)
                let donor = FrozenNikonPeakingDonor.applyPeakingFilterChain(
                    over: source, source: source, settings: settings, extent: source.extent)
                let composed = ImageEffectsCompositor.applyPeakingFilterChain(
                    over: source, source: source, settings: settings, extent: source.extent)
                XCTAssertEqual(
                    render(donor, with: context, extent: source.extent),
                    render(composed, with: context, extent: source.extent),
                    "\(size), \(sensitivity): replacing the fallback must preserve every byte")
            }
        }
    }

    func testAdmittedDonorFusedTinyWindowsMatchActualSharedFallback() throws {
        try XCTSkipIf(
            !FrozenNikonPeakingDonor.fusedPeakingAvailable,
            "Actual donor does not admit the fused detector: "
                + FrozenNikonPeakingDonor.fusedPeakingNote)
        XCTAssertTrue(ImageEffectsCompositor.fusedPeakingAvailable)
        let context = renderContext(workingFormat: .RGBAf)
        var paintedChannels = 0
        // Both non-square cases prove that either narrow dimension triggers the shared fallback.
        for size in [(16, 16), (20, 20), (20, 28), (28, 20)] {
            let source = try decodedProbe(width: size.0, height: size.1)
            let analysed = source.extent.insetBy(dx: Peaking.edgeInset, dy: Peaking.edgeInset)
            XCTAssertTrue(analysed.width <= 8 || analysed.height <= 8)
            let plain = render(source, with: context, extent: source.extent)
            for sensitivity in Peaking.Sensitivity.allCases {
                let settings = PeakingSettings(color: .red, sensitivity: sensitivity)
                let fused = try XCTUnwrap(
                    FrozenNikonPeakingDonor.fusedAttempt(
                        over: source, source: source, settings: settings,
                        extent: source.extent),
                    "Actual donor's admitted kernel must really apply for \(size)")
                let before = render(fused, with: context, extent: source.extent)
                let after = render(
                    ImageEffectsCompositor.applyPeaking(
                        over: source, source: source, settings: settings, extent: source.extent),
                    with: context, extent: source.extent)
                paintedChannels +=
                    zip(before, plain).filter {
                        abs(Int($0.0) - Int($0.1)) > 2
                    }.count
                assertPixels(
                    before, after, maximumDelta: 2,
                    note: "admitted donor fused to shared fallback \(size), \(sensitivity)")
            }
        }
        XCTAssertGreaterThan(
            paintedChannels, 0,
            "The narrow-window comparison must paint; identical unmodified pixels prove nothing")
    }

    func testSharedDefaultKeepsOriginalNarrowWindowFilterChainAdmission() throws {
        var paintedChannels = 0
        for workingFormat in [CIFormat.BGRA8, CIFormat.RGBAf] {
            let context = renderContext(workingFormat: workingFormat)
            for size in windows {
                let source = try decodedProbe(width: size.0, height: size.1)
                let analysed = source.extent.insetBy(dx: Peaking.edgeInset, dy: Peaking.edgeInset)
                guard analysed.width <= 8 || analysed.height <= 8 else { continue }
                let plain = render(source, with: context, extent: source.extent)
                for sensitivity in Peaking.Sensitivity.allCases {
                    for color in Peaking.Color.allCases {
                        for gateScale in [1.0, 4.0] {
                            let rgb = MonitorRGB(color.rgb)
                            let sense = MonitorPeakingSensitivity(
                                ratioThreshold: sensitivity.ratioThreshold,
                                noiseGate: sensitivity.noiseGate)
                            let implicit = MonitorImageCompositor.applyPeaking(
                                over: source, source: source, extent: source.extent,
                                color: rgb, sense: sense, gateScale: gateScale)
                            let explicit = MonitorImageCompositor.applyPeaking(
                                over: source, source: source, extent: source.extent,
                                color: rgb, sense: sense, gateScale: gateScale,
                                fusedWindowPolicy: .extendedAnalysisWindow)
                            let chain = MonitorImageCompositor.applyPeakingFilterChain(
                                over: source, source: source, extent: source.extent,
                                color: rgb, sense: sense, gateScale: gateScale)
                            let actual = render(implicit, with: context, extent: source.extent)
                            XCTAssertEqual(
                                actual,
                                render(explicit, with: context, extent: source.extent))
                            XCTAssertEqual(
                                actual,
                                render(chain, with: context, extent: source.extent))
                            paintedChannels +=
                                zip(actual, plain).filter {
                                    abs(Int($0.0) - Int($0.1)) > 2
                                }.count
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(
            paintedChannels, 0,
            "The unchanged shared default must exercise actual painted filter-chain pixels")
    }

    // An analysed window has 12 fewer pixels per dimension. 20 is the shared <=8 boundary,
    // 21 is its first fused control, and 13 exercises the smallest positive analysed window.
    private let windows = [(13, 13), (16, 16), (20, 20), (20, 28), (28, 20), (21, 21)]

    private func decodedProbe(width: Int, height: Int) throws -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8 = 64
                if x % 7 == 3 { value = 210 }
                if y % 9 == 4 { value = 16 }
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        // The shipping UIKit codec is exercised, rather than comparing two synthetic CI graphs.
        let encoded = try XCTUnwrap(UIImage(cgImage: image).pngData())
        let decoded = try XCTUnwrap(UIImage(data: encoded)?.cgImage)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        return CIImage(cgImage: decoded)
    }

    private func renderContext(workingFormat: CIFormat) -> CIContext {
        CIContext(options: [
            .workingFormat: workingFormat,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ])
    }

    private func render(_ image: CIImage, with context: CIContext, extent: CGRect) -> [UInt8] {
        let width = Int(extent.width)
        let height = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: width * 4, bounds: extent, format: .BGRA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }

    private func assertPixels(
        _ before: [UInt8], _ after: [UInt8], maximumDelta: Int, note: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(before.count, after.count, note, file: file, line: line)
        let worst = zip(before, after).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, maximumDelta, note, file: file, line: line)
    }
}

// Frozen test-only donor slices. These are the exact retired shipping implementation, not a
// second expected formula. Only fusedAttempt below is added to observe its private apply result.
private enum FrozenNikonPeakingDonor {
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

    static func fusedAttempt(
        over base: CIImage, source: CIImage, settings: PeakingSettings, extent: CGRect
    ) -> CIImage? {
        guard let kernel = fusedPeakingKernel else { return nil }
        return applyFusedPeaking(
            kernel: kernel, over: base, source: source, settings: settings, extent: extent)
    }
}
