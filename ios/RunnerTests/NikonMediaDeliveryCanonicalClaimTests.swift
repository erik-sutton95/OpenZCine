import Foundation
import OpenCineAppKit
import XCTest

@testable import Runner

@MainActor private final class DeliveryCanonicalFacts {
    var root = "SIMULATED-root"
    var generation: UInt64 = 0
    var native = true
    var canonicalReads = 0
}

/// SIMULATED canonical files and the actual byte-store producer retirement.
@MainActor final class NikonMediaDeliveryCanonicalClaimTests: XCTestCase {
    /// A SIMULATED hop that never leaves a network: only its token authority is used.
    private static func route() -> MonitorInternetHop<Int> {
        .init(
            port: .init(
                onCameraNetwork: { false }, leave: { route, _ in route }, rejoin: { _, _ in }))
    }
    func testPlannedProducerRetirementRequiresTheCapturedCurrentRouteForDelivery() throws {
        try fixture { store, clip, codec, bytes in
            let facts = DeliveryCanonicalFacts()
            let action = NikonMediaLibraryAction(
                owner: nil, store: store, codec: codec,
                bytes: bytes, clips: [clip],
                canonicalCurrent: {
                    facts.canonicalReads += 1
                    return facts.root == "SIMULATED-root" && facts.generation == 0
                }, admitted: { facts.native })
            XCTAssertTrue(action.isCurrent)
            XCTAssertEqual(facts.canonicalReads, 0)
            let route = Self.route()
            let captured = try XCTUnwrap(route.begin(0))
            bytes.retire()
            facts.native = false
            XCTAssertFalse(action.sourceIsCurrent)
            XCTAssertFalse(action.isCurrent)
            XCTAssertTrue(action.contentIsCurrent)
            XCTAssertTrue(action.contentIsCurrent && route.owns(captured))
            let successor = try XCTUnwrap(route.transfer(captured))
            XCTAssertTrue(action.contentIsCurrent)
            XCTAssertFalse(action.contentIsCurrent && route.owns(captured))
            XCTAssertTrue(route.owns(successor))
        }
    }

    func testCacheGenerationRootAndCanonicalReplacementRefuseThePreparedClaim() throws {
        for replacement in ["generation", "root", "content"] {
            try fixture { store, clip, codec, bytes in
                let facts = DeliveryCanonicalFacts()
                let action = NikonMediaLibraryAction(
                    owner: nil, store: store, codec: codec,
                    bytes: bytes, clips: [clip],
                    canonicalCurrent: {
                        facts.root == "SIMULATED-root" && facts.generation == 0
                    }, admitted: { facts.native })
                let route = Self.route()
                let captured = try XCTUnwrap(route.begin(0))
                bytes.retire()
                facts.native = false
                XCTAssertTrue(action.contentIsCurrent && route.owns(captured))
                switch replacement {
                case "generation": facts.generation += 1
                case "root": facts.root = "SIMULATED-successor"
                default:
                    store.update(cameraID: clip.cameraID, filename: clip.filename) {
                        $0.sizeBytes = 12
                        $0.captureDate = "20261008T120000"
                    }
                }
                XCTAssertFalse(action.contentIsCurrent)
                XCTAssertFalse(action.contentIsCurrent && route.owns(captured))
                XCTAssertFalse(action.canMutate(clip))
            }
        }
    }

    func testCanonicalCallbackCannotBorrowAReplacementRoot() throws {
        try fixture { store, clip, codec, bytes in
            let facts = DeliveryCanonicalFacts()
            let action = NikonMediaLibraryAction(
                owner: nil, store: store, codec: codec,
                bytes: bytes, clips: [clip],
                canonicalCurrent: {
                    facts.canonicalReads += 1
                    let accepted = facts.generation == 0
                    if facts.canonicalReads == 1 { facts.generation = 1 }
                    return accepted
                }, admitted: { facts.native })
            XCTAssertFalse(action.contentIsCurrent)
            XCTAssertEqual(facts.canonicalReads, 2)
            XCTAssertTrue(action.isCurrent)
            XCTAssertEqual(facts.canonicalReads, 2)
        }
    }

    func testLegacyCanonicalFactsRetireWithTheOriginalProducer() throws {
        try fixture { store, clip, codec, bytes in
            let action = NikonMediaLibraryAction(
                owner: nil, store: store, codec: codec,
                bytes: bytes, clips: [clip], admitted: { true })
            XCTAssertTrue(action.contentIsCurrent)
            XCTAssertTrue(action.isCurrent)
            bytes.retire()
            XCTAssertFalse(action.contentIsCurrent)
            XCTAssertFalse(action.isCurrent)
        }
    }

    func testContentOnlyClaimCannotPublishOrMutateAnExpiredNativeAction() throws {
        try fixture { store, clip, codec, bytes in
            let action = NikonMediaLibraryAction(
                owner: nil, store: store, codec: codec,
                bytes: bytes, clips: [clip], canonicalCurrent: { true }, admitted: { true })
            let original = try XCTUnwrap(store.catalogBytes(cameraID: clip.cameraID))
            bytes.retire()
            XCTAssertTrue(action.contentIsCurrent)
            XCTAssertFalse(action.canMutate(clip))
            action.publish()
            XCTAssertEqual(try store.catalogBytes(cameraID: clip.cameraID), original)
        }
    }

    private func fixture(
        _ body: (MediaClipStore, MediaClip, NikonMediaLibraryCodec, NikonMediaLibraryByteStore)
            throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-delivery-canonical-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let clip = MediaClip(
            cameraID: "SIMULATED", filename: "original.MOV", handle: 4,
            storageID: 65_537, sizeBytes: 4, captureDate: "20261007T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let codec = NikonMediaLibraryCodec(
            store: store, bucket: clip.cameraID,
            service: nil, downloaded: { _ in true })
        let bytes = NikonMediaLibraryByteStore(
            store: store, bucket: clip.cameraID, admitted: { true })
        try body(store, clip, codec, bytes)
    }
}
