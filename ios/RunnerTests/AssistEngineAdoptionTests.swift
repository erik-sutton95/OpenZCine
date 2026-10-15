import CoreImage
import CoreVideo
import OpenCineApple
import OpenCineCameraControls
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit
import XCTest

@testable import Runner

private typealias MonitorAssistTool = OpenZCineCore.MonitorAssistTool

/// F11: Z's live assists against the shared engine's own definitions. SIMULATED frames through
/// the app's real scope tap and image graph; no camera transport.
@MainActor
final class AssistEngineAdoptionTests: XCTestCase {
    private static let width = 200
    private static let height = 100

    /// One RGBA frame of four column bands: Log3G10 grey, a dark band, a band whose red channel
    /// sits on the clip shelf (`hot` columns of it), and a bright neutral.
    private static func frame(hotColumns: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: (UInt8, UInt8, UInt8) =
                    switch x {
                    case 0..<50: (85, 85, 85)
                    case 50..<100: (30, 30, 30)
                    case 100..<(100 + hotColumns): (176, 120, 110)
                    case 100..<150: (140, 120, 110)
                    default: (150, 150, 150)
                    }
                let i = (y * width + x) * 4
                pixels[i] = rgb.0
                pixels[i + 1] = rgb.1
                pixels[i + 2] = rgb.2
            }
        }
        return pixels
    }

    private static func image(_ rgba: [UInt8]) throws -> UIImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let cgImage = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent))
        return UIImage(cgImage: cgImage)
    }

    /// The same frame as the BGRA pixel buffer a video source hands the shared engine.
    private static func pixelBuffer(_ rgba: [UInt8]) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let o = y * rowBytes + x * 4
                base[o] = rgba[i + 2]
                base[o + 1] = rgba[i + 1]
                base[o + 2] = rgba[i]
                base[o + 3] = 255
            }
        }
        return result
    }

    /// What the shared engine publishes for this frame on a Log3G10 source clipping at 180:
    /// the shared tap, the shared sampler and its traffic lights.
    private static func shared(
        _ rgba: [UInt8], threshold: Double, previous: ScopeAssistBundle
    ) throws -> ScopeAssistBundle {
        let tap = try XCTUnwrap(
            LiveFrameTap.copyBGRA8(
                try pixelBuffer(rgba), maxWidth: OpenCineMedia.ScopeSampler.maxWidth))
        return OpenCineMedia.ScopeSampler.sample(
            bytes: tap.bytes, width: tap.width, height: tap.height, bytesPerRow: tap.bytesPerRow,
            transfer: .log3G10, clipByte: 180, includePoints: true, look: nil,
            trafficThreshold: threshold, previous: previous)
    }

    private func published(after revision: UInt64, _ model: NativeAppModel) async throws
        -> ScopeAssistBundle
    {
        for _ in 0..<150 where model.scopeAssist.revision <= revision {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(model.scopeAssist.revision, revision, "no scope bundle published")
        return model.scopeAssist
    }

    /// A1-05, A1-38, A1-39: a Log3G10 body clipping at 180 (R3D NE at base ISO). The bundle the
    /// shared surface reads is exactly what the shared engine derives from the same frame:
    /// samples, transfer, ceiling, histogram axis and the latched traffic lights.
    func testTheLiveScopeTapPublishesTheSharedEnginesBundle() async throws {
        let model = NativeAppModel(assist: .scratch())
        model.cameraState = .preview
        XCTAssertEqual(model.exposureSignalMapping.curve, .redLog3G10)
        XCTAssertEqual(model.exposureSignalMapping.clipNative, 180)
        for tool in [MonitorAssistTool.waveform, .histogram, .trafficLights] {
            model.assist.set(tool, visible: true, context: .liveView)
        }
        model.assist.crushClipCompensation = .half
        let threshold = MonitorCrushClipCompensation.half.pixelFractionThreshold
        model.openStillScopeSource()

        // Frame 1: a quarter of the picture on the red clip shelf (above the fire threshold).
        let first = Self.frame(hotColumns: 50)
        model.sampleScopesIfDue(clean: try Self.image(first)) { true }
        let one = try await published(after: 0, model)
        let expectedOne = try Self.shared(first, threshold: threshold, previous: .empty)

        // Frame 2, after the dense cadence: 4% on the shelf, between hold and fire.
        try await Task.sleep(for: .milliseconds(400))
        let second = Self.frame(hotColumns: 8)
        model.sampleScopesIfDue(clean: try Self.image(second)) { true }
        let two = try await published(after: one.revision, model)
        let expectedTwo = try Self.shared(second, threshold: threshold, previous: expectedOne)

        let surface = NikonMonitorShell.assistSource(model)
        let read = surface.readBundle()
        // A1-05: one engine definition of the bundle.
        XCTAssertEqual(read.transfer, .log3G10, "A1-05: the bundle carries the Nikon transfer")
        XCTAssertEqual(read.clipByte, 180, "A1-05: the bundle carries the Nikon ceiling")
        XCTAssertEqual(surface.readTransfer(), .log3G10)
        XCTAssertEqual(one.samples, expectedOne.samples, "A1-05: shared tap and luma weights")
        XCTAssertEqual(
            one.histogramDisplay, expectedOne.histogramDisplay, "A1-05: shared histogram axis")
        XCTAssertEqual(two.samples, expectedTwo.samples)
        XCTAssertEqual(two.trailSamples, expectedTwo.trailSamples)
        XCTAssertEqual(
            Self.withoutRevision(read), Self.withoutRevision(expectedTwo),
            "A1-05: the surface reads the shared engine's bundle")
        // A1-38: WAVE / PARADE draw on the shared axis (black on 0, the ceiling on 100).
        let axis =
            read.levelAxis ?? ScopeLevelAxis(transfer: read.transfer, clipByte: read.clipByte)
        XCTAssertEqual(
            axis, ScopeLevelAxis(transfer: .log3G10, clipByte: 180),
            "A1-38: the waveform axis is the shared one")
        XCTAssertEqual(axis.table[180], 100, "A1-38: the clip line is 100")
        // A1-39: the shared lamps, with the clip shelf and the hold.
        XCTAssertEqual(one.traffic, expectedOne.traffic, "A1-39: frame 1 lamps")
        XCTAssertEqual(two.traffic, expectedTwo.traffic, "A1-39: frame 2 lamps")
        XCTAssertTrue(one.traffic.red.clip, "A1-39: the red clip shelf lights")
        XCTAssertTrue(two.traffic.red.clip, "A1-39: a clip under the fire threshold holds")
    }

    /// A1-39: a frame the tap cannot read publishes nothing, so the lamps stay neutral instead
    /// of reading a low level from an empty histogram.
    func testAnUnreadableFramePublishesNoLamps() async throws {
        let model = NativeAppModel(assist: .scratch())
        model.cameraState = .preview
        model.assist.set(.trafficLights, visible: true, context: .liveView)
        model.openStillScopeSource()
        let unreadable = UIImage(
            ciImage: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        model.sampleScopesIfDue(clean: unreadable) { true }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.scopeAssist.traffic, .none, "A1-39: no data reads neutral")
    }

    /// A1-40: Z zebra is the shared zebra for the Nikon transfer and ceiling. A saturated blue
    /// patch clips its blue channel with low luma; the shared highlight measure flags it.
    func testZebraPaintsTheSharedZonesForTheNikonSignal() throws {
        let model = NativeAppModel(assist: .scratch())
        model.cameraState = .preview
        model.assist.set(.zebra, visible: true, context: .liveView)
        model.assist.zebraHighlight = true
        model.assist.zebraHighlightIRE = 100
        model.assist.zebraMidtone = true
        model.assist.zebraMidtoneIRE = 55
        let settings = try XCTUnwrap(model.liveImageEffects.zebra)
        let extent = CGRect(x: 0, y: 0, width: 64, height: 32)
        // Left half: saturated blue (B 200, luma 66). Right half: a grey ramp across midtones.
        var rgba = [UInt8](repeating: 255, count: 64 * 32 * 4)
        for y in 0..<32 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                let value = UInt8(60 + x * 2)
                rgba[i] = x < 32 ? 40 : value
                rgba[i + 1] = x < 32 ? 60 : value
                rgba[i + 2] = x < 32 ? 200 : value
            }
        }
        let source = CIImage(
            bitmapData: Data(rgba), bytesPerRow: 64 * 4, size: extent.size, format: .RGBA8,
            colorSpace: nil)
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
        ])
        func pixels(_ image: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 64 * 32 * 4)
            context.render(
                image, toBitmap: &out, rowBytes: 64 * 4, bounds: extent, format: .RGBA8,
                colorSpace: nil)
            return out
        }
        let nikon = pixels(
            ImageEffectsCompositor.applyZebra(
                over: source, source: source, settings: settings, extent: extent))
        let shared = pixels(
            MonitorImageCompositor.applyZebra(
                over: source, source: source, extent: extent,
                zebra: MonitorZebraSpec(
                    highlightEnabled: true, highlightIRE: 100,
                    highlightColor: MonitorRGB(model.assist.zebraHighlightColor.rgb),
                    midtoneEnabled: true, midtoneIRE: 55,
                    midtoneColor: MonitorRGB(model.assist.zebraMidtoneColor.rgb)),
                transfer: .log3G10, clipByte: 180))
        let plain = pixels(source)
        let bluePainted = (0..<(32 * 32)).contains { index in
            let row = index / 32
            let i = (row * 64 + index % 32) * 4
            return nikon[i..<(i + 3)] != plain[i..<(i + 3)]
        }
        XCTAssertTrue(bluePainted, "A1-40: a clipped blue channel is striped")
        XCTAssertEqual(nikon, shared, "A1-40: Z zebra paints the shared zones")
    }

    private static func withoutRevision(_ bundle: ScopeAssistBundle) -> ScopeAssistBundle {
        var value = bundle
        value.revision = 0
        return value
    }
}

/// The demo monitor with WAVE, HISTO and the traffic lights on, in both phone orientations, for
/// visual review of the scope axis and lamps. SIMULATED demo frame.
@MainActor
final class AssistEngineScreens: XCTestCase {
    func testTheDemoScopesInBothOrientations() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        for (name, size) in [
            ("portrait", CGSize(width: 402, height: 874)),
            ("landscape", CGSize(width: 874, height: 402)),
        ] {
            let model = NativeAppModel(assist: .scratch())
            model.preferences = OperatorPreferences.defaults
            model.startDemoSession()
            for tool in [MonitorAssistTool.waveform, .histogram, .trafficLights] {
                model.assist.set(tool, visible: true, context: .liveView)
            }
            let host = UIHostingController(
                rootView: AnyView(
                    NativeRootContent().environment(model).environment(model.delivery)))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            let mock = try XCTUnwrap(model.liveFrameImage ?? UIImage(named: "MockFeed"))
            await model.refreshScopes(from: mock, full: true)
            for _ in 0..<100 where model.scopeAssist == .empty {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotEqual(model.scopeAssist, .empty, "\(name): the demo frame was sampled")
            for _ in 0..<60 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "z-demo-scopes-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
