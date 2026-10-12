import Foundation
import XCTest

@testable import Runner

@MainActor private final class NikonDeliverySourceFacts { var revision = 0 }

/// SIMULATED cache bytes exercise the actual delivery capture, canonical store and file checks.
@MainActor final class NikonDeliveryCapturedSourceTests: XCTestCase {
    private func fixture(_ body: (NativeAppModel, MediaClip, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-delivery-source-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clip = MediaClip(
            cameraID: "SIMULATED", filename: "original.MOV", handle: 4,
            storageID: 65_537, sizeBytes: 4, captureDate: "20261007T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let url = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: url)
        try body(NativeAppModel(mediaClipStore: store), clip, url)
    }
    func testCapturedCanonicalReplacementCannotBorrowTheSuccessorRecord() throws {
        try fixture { model, clip, url in
            let capture = try XCTUnwrap(NikonMediaDeliveryCapture(model: model, clips: [clip]))
            XCTAssertTrue(capture.isCurrent)
            XCTAssertTrue(capture.isCached(clip))
            model.mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
                $0.sizeBytes = 12
                $0.captureDate = "20261008T120000"
            }
            XCTAssertFalse(capture.isCurrent)
            capture.update(clip) { $0.frameioStatus = .uploaded }
            XCTAssertEqual(model.mediaClipStore.list(cameraID: clip.cameraID).first?.sizeBytes, 12)
            XCTAssertNotEqual(
                model.mediaClipStore.list(cameraID: clip.cameraID).first?.frameioStatus, .uploaded)
            XCTAssertEqual(capture.localURL(clip), url)
        }
    }
    func testExpiredNativeClaimCannotUseCanonicalFilesWithoutItsOwnedRoute() throws {
        try fixture { model, clip, _ in
            let facts = NikonDeliverySourceFacts()
            let action = NikonMediaLibraryAction(
                owner: nil, store: model.mediaClipStore,
                codec: NikonMediaLibraryCodec(
                    store: model.mediaClipStore, bucket: clip.cameraID,
                    service: nil, downloaded: { _ in true }),
                bytes: nil, clips: [clip], canonicalCurrent: { true },
                admitted: { facts.revision == 0 })
            let capture = try XCTUnwrap(
                NikonMediaDeliveryCapture(model: model, clips: [clip], action: action))
            XCTAssertTrue(capture.isCurrent)
            facts.revision = 1
            XCTAssertTrue(action.contentIsCurrent)
            XCTAssertFalse(action.sourceIsCurrent)
            XCTAssertFalse(capture.isCurrent)
            facts.revision = 2
            XCTAssertFalse(capture.isCurrent)
        }
    }
    func testActualCachedFactRejectsTruncationEmptyFileAndSymlink() throws {
        try fixture { model, clip, url in
            let capture = try XCTUnwrap(NikonMediaDeliveryCapture(model: model, clips: [clip]))
            XCTAssertTrue(capture.isCached(clip))
            try Data([1, 2, 3]).write(to: url)
            XCTAssertFalse(capture.isCached(clip))
            try Data().write(to: url)
            XCTAssertFalse(capture.isCached(clip))
            let borrowed = url.deletingLastPathComponent().appendingPathComponent("borrowed.MOV")
            try Data([1, 2, 3, 4]).write(to: borrowed)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: borrowed)
            XCTAssertFalse(capture.isCached(clip))
            XCTAssertEqual(try Data(contentsOf: borrowed), Data([1, 2, 3, 4]))
        }
    }
    func testDuplicateSelectedIDRetainsOriginalContentAndSelectionOrder() throws {
        try fixture { model, clip, url in
            let capture = try XCTUnwrap(
                NikonMediaDeliveryCapture(model: model, clips: [clip, clip]))
            XCTAssertEqual(capture.clips.map(\.id), [clip.id, clip.id])
            XCTAssertEqual(capture.localURL(clip), url)
            XCTAssertTrue(capture.isCached(clip))
            XCTAssertTrue(capture.isCurrent)
        }
    }
}
