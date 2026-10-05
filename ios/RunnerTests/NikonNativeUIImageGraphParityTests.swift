import CoreImage
import OpenCineApple
import OpenZCineCore
import UIKit
import XCTest
@testable import Runner

/// SIMULATED actual PNG decode and CI evaluation; no camera or physical qualification.
@MainActor final class NikonNativeUIImageGraphParityTests: XCTestCase {
    func testDecodedColoredZebraPreservesDonorLumaRampAndFixedNativeBand() throws {
        let image = try decodedFixture()
        let source = try XCTUnwrap(CIImage(image: image, options: [.colorSpace: NSNull()]))
        let contexts = [CIFormat.BGRA8, .RGBAf].map { format in
            CIContext(options: [.workingFormat: format, .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(), .cacheIntermediates: false])
        }
        let colors: [AssistConfiguration.Zebra.StripeColor] = [.white, .amber, .red, .cyan, .green]
        var changedChannels = 0
        for context in contexts {
            let plain = pixels(source, context: context)
            for color in colors {
                for threshold in [20.0, 55, 90, 100] {
                    var settings = ZebraSettings()
                    settings.curve = .srgb
                    settings.highlightIRE = threshold
                    settings.midtoneIRE = threshold
                    settings.highlightColor = color
                    for zone in 0..<3 {
                        settings.highlightEnabled = zone != 1
                        settings.midtoneEnabled = zone != 0
                        let donor = FrozenNikonRuntimeEffects.applyZebra(
                            over: source, source: source, settings: settings, extent: source.extent)
                        let composed = ImageEffectsCompositor.applyZebra(
                            over: source, source: source, settings: settings, extent: source.extent)
                        let before = pixels(donor, context: context)
                        let after = pixels(composed, context: context)
                        XCTAssertEqual(before, after, "actual zebra \(color), \(threshold), zone \(zone)")
                        changedChannels += zip(before, plain).filter { $0 != $1 }.count
                    }
                }
            }
        }
        XCTAssertGreaterThan(changedChannels, 0, "The native pixel oracle must really paint zebra")
    }

    func testActualDecodedGraphIdentityMemoAndDisplayOnlyBlockStagesMatchFrozenOwner() throws {
        let image = try decodedFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LUTFileStore(root: root)
        let donor = FrozenNikonUIImageGraphProcessor(fileStore: store)
        let composed = LiveFrameProcessor(fileStore: store)
        XCTAssertTrue(donor.render(image, effects: LiveImageEffects()) === image)
        XCTAssertTrue(composed.render(image, effects: LiveImageEffects()) === image)
        var settings = LiveImageEffects()
        settings.blockSmoothing = BlockSmoothingSettings()
        settings.blockDither = BlockDitherSettings()
        let before = donor.render(image, effects: settings)
        let after = composed.render(image, effects: settings)
        XCTAssertFalse(before === image)
        XCTAssertFalse(after === image)
        XCTAssertEqual(before.scale, after.scale)
        XCTAssertEqual(before.imageOrientation, after.imageOrientation)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        XCTAssertEqual(pixels(try XCTUnwrap(CIImage(image: before)), context: context),
            pixels(try XCTUnwrap(CIImage(image: after)), context: context))
        XCTAssertTrue(composed.render(image, effects: settings) === after)
        XCTAssertTrue(donor.render(image, effects: settings) === before)
        XCTAssertTrue(composed.render(image, effects: LiveImageEffects()) === image)
        XCTAssertFalse(composed.render(image, effects: settings) === after,
            "identity must evict the exact retained-image memo")
    }

    private func decodedFixture() throws -> UIImage {
        let width = 96, height = 32
        let palette: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255),
            (45, 45, 45), (50, 50, 50), (55, 55, 55), (135, 135, 135),
            (140, 140, 140), (145, 145, 145), (224, 224, 224), (229, 229, 229), (255, 255, 255)]
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let value = palette[(x / 8 + y / 8) % palette.count]
                bytes.append(contentsOf: [value.0, value.1, value.2, 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = try XCTUnwrap(UIImage(cgImage: cgImage, scale: 2, orientation: .up).pngData())
        return try XCTUnwrap(UIImage(data: encoded, scale: 2))
    }

    private func pixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                bounds: image.extent, format: .RGBA8, colorSpace: nil)
        }
        return bytes
    }
}
