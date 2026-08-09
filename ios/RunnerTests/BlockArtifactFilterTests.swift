import CoreImage
import UIKit
import XCTest

@testable import Runner

/// `CIKernel(source:)` returns nil when the CIKL fails to compile, and both filters then fall back
/// to returning their input untouched. That is the right failure mode — never drop a frame — but it
/// makes a broken kernel indistinguishable from a working one that does nothing. These render the
/// real kernels through a real `CIContext` so a compile failure or a sign error fails the build
/// rather than shipping a silent no-op.
final class BlockArtifactFilterTests: XCTestCase {

    /// Renders `image` and returns the red channel of every pixel, row-major.
    private func redChannel(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        pixels.withUnsafeMutableBytes { bytes in
            context.render(
                image,
                toBitmap: bytes.baseAddress!,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: nil)
        }
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    }

    /// A flat field split down the middle by `step` levels — a single block boundary, and the thing
    /// the smoother exists to ramp out.
    private func blockStep(width: Int, height: Int, base: UInt8, step: Int) -> CIImage {
        var raw = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = x < width / 2 ? Int(base) : Int(base) + step
                let index = (y * width + x) * 4
                raw[index] = UInt8(clamping: value)
                raw[index + 1] = UInt8(clamping: value)
                raw[index + 2] = UInt8(clamping: value)
            }
        }
        return CIImage(
            bitmapData: Data(raw),
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: nil)
    }

    private let width = 32
    private let height = 16

    func testFlatSmoothingRampsABlockStep() {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = blockStep(width: width, height: height, base: 100, step: 8)
        let smoothed = ImageEffectsCompositor.applyFlatSmoothing(
            to: source,
            settings: BlockSmoothingSettings(radius: 2, gateLevels: 5, strength: 1.0),
            extent: extent)

        let before = redChannel(source, width: width, height: height)
        let after = redChannel(smoothed, width: width, height: height)
        XCTAssertEqual(after.count, before.count)

        // The step is between columns 15 and 16 on the row sampled here.
        let row = height / 2
        let jumpBefore = abs(Int(before[row * width + 16]) - Int(before[row * width + 15]))
        let jumpAfter = abs(Int(after[row * width + 16]) - Int(after[row * width + 15]))
        XCTAssertEqual(jumpBefore, 8, "fixture should present an 8-level step")
        XCTAssertLessThan(
            jumpAfter, jumpBefore,
            "flat-region smoothing must reduce the boundary discontinuity; got \(jumpAfter)")

        // Far from the boundary the field is flat and must come back unchanged — a filter that
        // shifts flat areas is altering exposure, not removing an artifact.
        XCTAssertEqual(Int(after[row * width + 2]), Int(before[row * width + 2]), accuracy: 1)
        XCTAssertEqual(
            Int(after[row * width + width - 3]), Int(before[row * width + width - 3]), accuracy: 1)
    }

    func testFlatSmoothingLeavesRealDetailAlone() {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // 120 levels is far past any plausible block step — this is a real edge, and the gate must
        // disengage completely rather than ramping it.
        let source = blockStep(width: width, height: height, base: 60, step: 120)
        let smoothed = ImageEffectsCompositor.applyFlatSmoothing(
            to: source,
            settings: BlockSmoothingSettings(radius: 2, gateLevels: 5, strength: 1.0),
            extent: extent)

        let before = redChannel(source, width: width, height: height)
        let after = redChannel(smoothed, width: width, height: height)
        let row = height / 2
        let jumpBefore = abs(Int(before[row * width + 16]) - Int(before[row * width + 15]))
        let jumpAfter = abs(Int(after[row * width + 16]) - Int(after[row * width + 15]))
        XCTAssertGreaterThan(
            jumpAfter, Int(Double(jumpBefore) * 0.9),
            "a 120-level edge is detail, not blocking — the gate must leave it intact")
    }

    func testFlatSmoothingIsAPassthroughAtZeroStrength() {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = blockStep(width: width, height: height, base: 100, step: 8)
        let smoothed = ImageEffectsCompositor.applyFlatSmoothing(
            to: source,
            settings: BlockSmoothingSettings(radius: 2, gateLevels: 5, strength: 0),
            extent: extent)
        XCTAssertEqual(
            redChannel(smoothed, width: width, height: height),
            redChannel(source, width: width, height: height))
    }

    func testDitherPerturbsPixelsWithinAmplitude() {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = blockStep(width: width, height: height, base: 128, step: 0)
        let dithered = ImageEffectsCompositor.applyDither(
            to: source, settings: BlockDitherSettings(levels: 6), extent: extent)

        let before = redChannel(source, width: width, height: height)
        let after = redChannel(dithered, width: width, height: height)

        let deltas = zip(before, after).map { abs(Int($0) - Int($1)) }
        XCTAssertTrue(
            deltas.contains { $0 > 0 },
            "dither that changes nothing means the kernel failed to compile and fell through")
        XCTAssertLessThanOrEqual(
            deltas.max() ?? 0, 4,
            "a 6-level peak-to-peak dither must stay within ±3 levels; got \(deltas.max() ?? 0)")
        // Must not shift the picture's overall level — masking noise, not an exposure offset.
        let meanBefore = Double(before.reduce(0) { $0 + Int($1) }) / Double(before.count)
        let meanAfter = Double(after.reduce(0) { $0 + Int($1) }) / Double(after.count)
        XCTAssertEqual(meanAfter, meanBefore, accuracy: 1.0)
    }

    func testDitherIsAPassthroughAtZeroLevels() {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = blockStep(width: width, height: height, base: 128, step: 0)
        let dithered = ImageEffectsCompositor.applyDither(
            to: source, settings: BlockDitherSettings(levels: 0), extent: extent)
        XCTAssertEqual(
            redChannel(dithered, width: width, height: height),
            redChannel(source, width: width, height: height))
    }

    /// Neither filter may reach the measurement path: peaking measures blur radius and zebras
    /// measure clipping, and both read the raw decode. This pins the split in `outputCIImage`.
    func testEffectsAreNotIdentityWhenOnlyBlockFiltersAreActive() {
        var effects = LiveImageEffects()
        XCTAssertTrue(effects.isIdentity)
        effects.blockSmoothing = BlockSmoothingSettings()
        XCTAssertFalse(
            effects.isIdentity,
            "an identity graph skips outputCIImage entirely, so the filters would never run")
        effects = LiveImageEffects()
        effects.blockDither = BlockDitherSettings()
        XCTAssertFalse(effects.isIdentity)
    }
}
