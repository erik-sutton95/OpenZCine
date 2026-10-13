import CoreImage
import OpenCineApple
import OpenCineMedia
import OpenZCineCore
import UIKit
import XCTest

import class OpenCineCameraVocabulary.CustomLUTStore
import enum OpenCineMedia.MonitorZebraPaint

@testable import Runner

/// SIMULATED actual PNG decode and CI evaluation; no camera or physical qualification.
@MainActor final class NikonNativeUIImageGraphParityTests: XCTestCase {
    /// A1-41: actual Nikon CI rendering uses the same encoded-source science as the shared monitor.
    func testDecodedNikonFalseColorMatchesTheSharedSignalLattice() throws {
        let image = try decodedFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = LiveFrameProcessor(fileStore: CustomLUTStore.nikon(root: root))
        let reference = MonitorUIImageGraphProcessor<LiveImageEffects>()
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        for curve in [ExposureToneCurve.redLog3G10, .nikonNLog] {
            let mapping = ExposureSignalMapping(curve: curve, clipNative: 180)
            var effects = LiveImageEffects()
            effects.falseColor = FalseColorSettings(scale: .stops, curve: curve, clipNative: 180)
            let shared = MonitorFalseColorLattice.signal(
                scale: .sceneStops,
                transfer: curve.monitorTransfer, clipByte: mapping.clipByte, readThroughLook: false
            )
            .cube(.composite).preparedForRenderer()
            var graph = MonitorUIImageGraph()
            graph.look = .replacement(
                MonitorNativeCubeRequest(key: curve.rawValue) {
                    (shared.size, shared.rgbaComponents.withUnsafeBytes { Data($0) })
                })
            let expected = reference.render(image, settings: effects, identity: false) { graph }
            let rendered = actual.render(image, effects: effects)
            XCTAssertEqual(
                try pixels(XCTUnwrap(CIImage(image: rendered)), context: context),
                try pixels(XCTUnwrap(CIImage(image: expected)), context: context),
                "The actual decoded Nikon \(curve) image must paint the shared source signal")
        }
    }

    /// A1-40: Nikon zebra is the shared zebra (hottest-channel highlight to the clip shelf,
    /// luma midtone band) on the camera's transfer and clip, as Pocket and Insta paint it.
    func testDecodedColoredZebraPaintsTheSharedZones() throws {
        let image = try decodedFixture()
        let source = try XCTUnwrap(CIImage(image: image, options: [.colorSpace: NSNull()]))
        let contexts = [CIFormat.BGRA8, .RGBAf].map { format in
            CIContext(options: [
                .workingFormat: format, .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(), .cacheIntermediates: false,
            ])
        }
        let colors: [MonitorZebraPaint] = [.white, .amber, .red, .cyan, .green]
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
                        let donor = MonitorImageCompositor.applyZebra(
                            over: source, source: source, extent: source.extent,
                            zebra: MonitorZebraSpec(
                                highlightEnabled: settings.highlightEnabled,
                                highlightIRE: threshold,
                                highlightColor: MonitorRGB(color.rgb),
                                midtoneEnabled: settings.midtoneEnabled, midtoneIRE: threshold,
                                midtoneColor: MonitorRGB(settings.midtoneColor.rgb)),
                            transfer: .srgb, clipByte: 255)
                        let composed = ImageEffectsCompositor.applyZebra(
                            over: source, source: source, settings: settings, extent: source.extent)
                        let before = pixels(donor, context: context)
                        let after = pixels(composed, context: context)
                        XCTAssertEqual(
                            before, after, "actual zebra \(color), \(threshold), zone \(zone)")
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
        let store = CustomLUTStore.nikon(root: root)
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
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        XCTAssertEqual(
            pixels(try XCTUnwrap(CIImage(image: before)), context: context),
            pixels(try XCTUnwrap(CIImage(image: after)), context: context))
        XCTAssertTrue(composed.render(image, effects: settings) === after)
        XCTAssertTrue(donor.render(image, effects: settings) === before)
        XCTAssertTrue(composed.render(image, effects: LiveImageEffects()) === image)
        XCTAssertFalse(
            composed.render(image, effects: settings) === after,
            "identity must evict the exact retained-image memo")
    }

    /// Nikon main grades the LUT half of a 50/50 comparison: the right half for Left / Right and
    /// the bottom half for Top / Bottom ("LUT on the bottom"), as Nikon playback still does.
    func testSplitComparisonGradesTheSameHalfAsTheFrozenOwner() throws {
        let image = try decodedFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomLUTStore.nikon(root: root)
        let donor = FrozenNikonUIImageGraphProcessor(fileStore: store)
        let composed = LiveFrameProcessor(fileStore: store)
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        let plain = pixels(try XCTUnwrap(CIImage(image: image)), context: context)
        for orientation in SplitComparisonOrientation.allCases {
            var settings = LiveImageEffects()
            settings.lut = .builtIn(.monochrome)
            settings.splitComparison = orientation
            let before = pixels(
                try XCTUnwrap(CIImage(image: donor.render(image, effects: settings))),
                context: context)
            let after = pixels(
                try XCTUnwrap(CIImage(image: composed.render(image, effects: settings))),
                context: context)
            XCTAssertNotEqual(before, plain, "\(orientation) must grade half the frame")
            let differing = zip(before, after).filter { $0 != $1 }.count
            XCTAssertEqual(differing, 0, "\(orientation): channels unlike the frozen owner")
        }
    }

    private func decodedFixture() throws -> UIImage {
        let width = 96
        let height = 32
        let palette: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (45, 45, 45), (50, 50, 50), (55, 55, 55), (135, 135, 135),
            (140, 140, 140), (145, 145, 145), (224, 224, 224), (229, 229, 229), (255, 255, 255),
        ]
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let value = palette[(x / 8 + y / 8) % palette.count]
                bytes.append(contentsOf: [value.0, value.1, value.2, 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cgImage = try XCTUnwrap(
            CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue:
                        CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = try XCTUnwrap(UIImage(cgImage: cgImage, scale: 2, orientation: .up).pngData())
        return try XCTUnwrap(UIImage(data: encoded, scale: 2))
    }

    private func pixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(
                image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                bounds: image.extent, format: .RGBA8, colorSpace: nil)
        }
        return bytes
    }
}
