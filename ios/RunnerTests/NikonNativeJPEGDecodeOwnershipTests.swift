import CoreGraphics
import Foundation
import OpenCineApple
import UIKit
import XCTest

@MainActor
final class NikonNativeJPEGDecodeOwnershipTests: XCTestCase {
    private final class InputOwner: NSObject {}

    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        let successor = InputOwner()
        var decoder: MonitorJPEGImageDecoder?
        var didEnter = 0
        var successorSource: MonitorJPEGDecodeSource?
        var unavailableResets = 0

        func replaceDuringNativePreparation() -> Float? {
            lock.withLock {
                didEnter += 1
                successorSource = decoder?.source(successor)
            }
            return nil
        }
        func report(_ reason: String?) {
            if reason == nil { lock.withLock { unavailableResets += 1 } }
        }
    }

    private func decodedJPEG() throws -> Data {
        let width = 96
        let height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = x < width / 2 ? 240 : 30
                bytes[index + 1] = y < height / 2 ? 30 : 220
                bytes[index + 2] = 60
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let raster = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
        return try XCTUnwrap(UIImage(cgImage: raster).jpegData(compressionQuality: 0.95))
    }

    func testQueuedSourceReplacementRefusesOldDecodeAndAdmitsSuccessor() async throws {
        let jpeg = try decodedJPEG()
        let decoder = MonitorJPEGImageDecoder()
        let oldOwner = InputOwner()
        let successor = InputOwner()
        let old = try XCTUnwrap(decoder.source(oldOwner))
        let current = try XCTUnwrap(decoder.source(successor))
        let retired = await decoder.decode(jpeg, source: old, preferHardware: false)
        XCTAssertNil(retired)
        let decoded = await decoder.decode(jpeg, source: current, preferHardware: false)
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(image.size, CGSize(width: 96, height: 64))
        withExtendedLifetime((oldOwner, successor)) {}
    }

    func testReplacementInsideHardwarePreparationRefusesOldRenderedFrame() async throws {
        let jpeg = try decodedJPEG()
        let gate = Gate()
        let decoder = MonitorJPEGImageDecoder(denoiseStrength: {
            gate.replaceDuringNativePreparation()
        })
        gate.lock.withLock { gate.decoder = decoder }
        defer { gate.lock.withLock { gate.decoder = nil } }
        let oldOwner = InputOwner()
        let old = try XCTUnwrap(decoder.source(oldOwner))
        let retired = await decoder.decode(jpeg, source: old)
        XCTAssertEqual(
            gate.lock.withLock { gate.didEnter }, 1, "real native decode must reach preparation")
        XCTAssertNil(retired)
        let current = try XCTUnwrap(gate.lock.withLock { gate.successorSource })
        let successor = await decoder.decode(jpeg, source: current, preferHardware: false)
        XCTAssertNotNil(successor)
        withExtendedLifetime(oldOwner) {}
    }

    func testDelayedOldResetCannotClearSuccessorHistoryOrReport() async throws {
        let jpeg = try decodedJPEG()
        let gate = Gate()
        let decoder = MonitorJPEGImageDecoder(unavailable: { gate.report($0) })
        let oldOwner = InputOwner()
        _ = try XCTUnwrap(decoder.source(oldOwner))
        let retired = decoder.retireSource()
        let current = try XCTUnwrap(decoder.source(gate.successor))
        let before = await decoder.decode(jpeg, source: current, preferHardware: false)
        XCTAssertNotNil(before)
        let resets = gate.lock.withLock { gate.unavailableResets }
        XCTAssertEqual(resets, 1)
        await decoder.resetProcessors(source: retired)
        XCTAssertEqual(gate.lock.withLock { gate.unavailableResets }, resets)
        let after = await decoder.decode(jpeg, source: current, preferHardware: false)
        XCTAssertNotNil(after)
        XCTAssertEqual(gate.lock.withLock { gate.unavailableResets }, resets)
        withExtendedLifetime(oldOwner) {}
    }

    func testClosedOrDeallocatedSourceCannotDecodeOrReopen() async throws {
        let jpeg = try decodedJPEG()
        let decoder = MonitorJPEGImageDecoder()
        var owner: InputOwner? = InputOwner()
        weak var retainedOwner = owner
        let source = try XCTUnwrap(decoder.source(try XCTUnwrap(owner)))
        owner = nil
        XCTAssertNil(retainedOwner, "source binding must not extend acquisition lifetime")
        let detached = await decoder.decode(jpeg, source: source, preferHardware: false)
        XCTAssertNil(detached)
        let successor = InputOwner()
        let current = try XCTUnwrap(decoder.source(successor))
        decoder.close()
        XCTAssertNil(decoder.source(successor))
        let closed = await decoder.decode(jpeg, source: current, preferHardware: false)
        XCTAssertNil(closed)
    }
}
