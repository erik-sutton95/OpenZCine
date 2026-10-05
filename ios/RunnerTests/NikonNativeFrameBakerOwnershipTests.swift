import CoreImage
import Metal
import OpenCineApple
import XCTest
import UIKit

@testable import Runner

final class NikonNativeFrameBakerOwnershipTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func note(_ name: String) { lock.withLock { values[name, default: 0] += 1 } }
        func count(_ name: String) -> Int { lock.withLock { values[name, default: 0] } }
    }

    func testRetiredPreparationCannotCompleteOrPublishOverSuccessor() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let native = MonitorFrameBaker(device: device, workingSpace: .encodedSRGB)
        let counts = Counts()
        let successor = expectation(description: "actual successor preparation finished")
        native.scheduleBake(preparing: {
            counts.note("old prepared")
            native.reset()
            native.scheduleBake(preparing: { counts.note("new prepared"); return nil },
                drawableSize: CGSize(width: 8, height: 8), pixelFormat: .bgra8Unorm) {
                    counts.note("new completed")
                    successor.fulfill()
                }
            return CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        }, drawableSize: CGSize(width: 8, height: 8), pixelFormat: .bgra8Unorm) {
            counts.note("old completed")
        }
        wait(for: [successor], timeout: 5)
        XCTAssertEqual(counts.count("old prepared"), 1)
        XCTAssertEqual(counts.count("new prepared"), 1)
        XCTAssertEqual(counts.count("new completed"), 1)
        XCTAssertEqual(counts.count("old completed"), 0)
        XCTAssertNil(native.acquireFrame(for: CGSize(width: 8, height: 8), pixelFormat: .bgra8Unorm))
        native.close()
    }
    @MainActor func testCapturedSourceRetirementSkipsCompletionAndOldCloseCannotRetireSuccessor() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let native = MonitorFrameBaker(device: device, workingSpace: .encodedSRGB)
        let bus = LiveFrameSampleBus()
        let old = bus.openSource(.live)
        let counts = Counts()
        let entered = expectation(description: "actual old preparation entered")
        let completed = expectation(description: "admitted successor prepared")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); native.close() }
        native.scheduleBake(preparing: {
            counts.note("old prepared")
            entered.fulfill()
            if release.wait(timeout: .now() + 5) != .success { counts.note("gate timeout") }
            return nil
        }, drawableSize: CGSize(width: 8, height: 8), pixelFormat: .bgra8Unorm,
            source: MonitorFrameBakeSource(lease: old)) {
            counts.note("old completed")
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(counts.count("old prepared"), 1,
            "The retirement gate must operate on drained work, not only coalescing")
        let next = bus.openSource(.live)
        bus.closeSource(old)
        XCTAssertFalse(old.isActive)
        XCTAssertTrue(next.isActive)
        XCTAssertTrue(bus.isCurrent(next))
        native.scheduleBake(preparing: {
            counts.note("successor prepared")
            return nil
        }, drawableSize: CGSize(width: 8, height: 8), pixelFormat: .bgra8Unorm,
            source: MonitorFrameBakeSource(lease: next)) {
            completed.fulfill()
        }
        release.signal()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(counts.count("gate timeout"), 0)
        XCTAssertEqual(counts.count("old completed"), 0)
        XCTAssertEqual(counts.count("successor prepared"), 1)
        XCTAssertTrue(next.isActive)
        bus.closeSource(next)
    }

    @MainActor func testActualHeldPictureStatusAndRepaintKeepLeaseUntilExplicitClear() async throws {
        let model = NativeAppModel()
        model.preferences = OperatorPreferences.defaults
        model.videoSource = .hdmiCapture
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }
        model.liveFrameImage = image
        let held = try XCTUnwrap(model.liveFrameSource)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let native = MonitorFrameBaker(device: device, workingSpace: .encodedSRGB,
            scheduling: .waitForGPUCompletion)
        defer { native.close(); model.liveFrameImage = nil }
        model.connection = .reconnecting
        XCTAssertTrue(model.liveFrameImage === image)
        XCTAssertTrue(model.liveFrameSource === held)
        XCTAssertTrue(held.isActive)
        let completed = expectation(description: "held recovery picture actually baked")
        let graph = try XCTUnwrap(CIImage(image: image))
        native.scheduleBake(image: graph, drawableSize: CGSize(width: 16, height: 12),
            pixelFormat: .bgra8Unorm, source: MonitorFrameBakeSource(lease: held)) {
                completed.fulfill()
            }
        await fulfillment(of: [completed], timeout: 5)
        let acquired = try XCTUnwrap(native.acquireFrame(
            for: CGSize(width: 16, height: 12), pixelFormat: .bgra8Unorm))
        defer { native.releaseBakedTexture(acquired.texture) }
        XCTAssertTrue(acquired.isCurrent)
        let repaint = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }
        model.liveFrameImage = repaint
        XCTAssertTrue(model.liveFrameImage === repaint)
        XCTAssertTrue(model.liveFrameSource === held)
        XCTAssertTrue(acquired.isCurrent)
        model.liveFrameImage = nil
        XCTAssertFalse(held.isActive)
        XCTAssertFalse(acquired.isCurrent)
        model.liveFrameImage = image
        let successor = try XCTUnwrap(model.liveFrameSource)
        XCTAssertFalse(successor === held)
        XCTAssertTrue(successor.isActive)
        XCTAssertFalse(acquired.isCurrent)
        XCTAssertNil(native.acquireFrame(for: CGSize(width: 16, height: 12), pixelFormat: .bgra8Unorm))
    }

    @MainActor func testActiveLeaseCannotKeepAcquiredFrameCurrentAfterBakerResetOrClose() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let native = MonitorFrameBaker(device: device, workingSpace: .encodedSRGB,
            scheduling: .waitForGPUCompletion)
        let bus = LiveFrameSampleBus()
        let lease = bus.openSource(.live)
        defer { native.close(); bus.closeSource(lease) }
        let size = CGSize(width: 8, height: 8)
        func bake(_ red: CGFloat) async throws -> MonitorFrameBaker.Frame {
            let completed = expectation(description: "actual GPU bake \(red)")
            native.scheduleBake(image: CIImage(color: CIColor(red: red, green: 0, blue: 0))
                .cropped(to: CGRect(origin: .zero, size: size)), drawableSize: size,
                pixelFormat: .bgra8Unorm, source: MonitorFrameBakeSource(lease: lease)) {
                    completed.fulfill()
                }
            await fulfillment(of: [completed], timeout: 5)
            return try XCTUnwrap(native.acquireFrame(for: size, pixelFormat: .bgra8Unorm))
        }
        let old = try await bake(1)
        defer { native.releaseBakedTexture(old.texture) }
        XCTAssertTrue(old.isCurrent)
        native.reset()
        XCTAssertTrue(lease.isActive)
        XCTAssertFalse(old.isCurrent, "the same active lease must not keep a reset frame current")
        XCTAssertNil(native.acquireFrame(for: size, pixelFormat: .bgra8Unorm))
        let successor = try await bake(0)
        defer { native.releaseBakedTexture(successor.texture) }
        XCTAssertTrue(successor.isCurrent)
        XCTAssertFalse(old.isCurrent)
        XCTAssertFalse(successor.texture === old.texture)
        native.close()
        XCTAssertTrue(lease.isActive)
        XCTAssertFalse(successor.isCurrent, "the same active lease must not keep a closed frame current")
        XCTAssertNil(native.acquireFrame(for: size, pixelFormat: .bgra8Unorm))
    }
}
