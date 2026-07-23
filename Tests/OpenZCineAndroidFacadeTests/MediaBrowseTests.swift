// Media-browse tests for the Android facade against the scripted fake card:
// listing (with the media filter and the R3D-hide pairing rule), per-object
// thumbnails, the enumeration bound, and the JNI wire encoding. ObjectInfo
// *parsing* is covered by the core's PTPObjectInfo suite; these cover what
// only a socket pair can — the operation sequence and its policies.

import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct MediaBrowseTests {
    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
    }

    private func collect(
        _ cursor: FacadeMediaBrowseCursor,
        pageSize: Int = 32
    ) throws -> [FacadeMediaClip] {
        var clips: [MediaObjectHandle: FacadeMediaClip] = [:]
        while true {
            let page = try cursor.nextPage(maxObjects: pageSize)
            for clip in page.clips {
                clips[MediaObjectHandle(storageID: clip.storageID, handle: clip.handle)] = clip
            }
            for object in page.removedObjects {
                clips.removeValue(
                    forKey: MediaObjectHandle(
                        storageID: object.storageID, handle: object.handle))
            }
            if !page.hasMore { return Array(clips.values) }
        }
    }

    @Test func listsBrowsableMediaWithMetadata() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let clips = try collect(session.beginMediaBrowse())

        // 10 objects on card → 8 visible: the folder is not media, and the
        // proxy-paired R3D master is hidden (iOS browse parity).
        #expect(clips.count == 8)
        let filenames = clips.map(\.filename)
        #expect(!filenames.contains("100NIKON"))
        #expect(!filenames.contains("A001_C003_0713RC.R3D"))
        #expect(filenames.contains("A001_C003_0713RC.MP4"))
        #expect(filenames.contains("A001_C004_0714RC.R3D"))  // unpaired master stays

        let newest = try #require(clips.first(where: { $0.filename == "C0008.MOV" }))
        #expect(newest.handle == 0x1009)
        #expect(newest.storageID == FakeZRMediaCard.storageID)
        #expect(newest.sizeBytes == 2_000_000_000)
        #expect(newest.captureDate == "20260714T110000")
        #expect(newest.pixelWidth == 5760)
        #expect(newest.pixelHeight == 3240)
        #expect(newest.contentClassification.kind == .playableProxy)

        let pairedProxy = try #require(
            clips.first(where: { $0.filename == "A001_C003_0713RC.MP4" }))
        #expect(pairedProxy.pixelWidth == 1920)
        #expect(pairedProxy.pixelHeight == 1080)
        #expect(pairedProxy.sourcePixelWidth == 6144)
        #expect(pairedProxy.sourcePixelHeight == 3240)

        let still = try #require(clips.first(where: { $0.filename == "DSC_0007.JPG" }))
        #expect(still.contentClassification.kind == .stillPhoto)
        #expect(still.contentClassification.stillPreview?.formatLabel == "JPEG")
        #expect(still.contentClassification.stillPreview?.strategy == .progressive)

        // Card-present volume discovery went through the vendor op first.
        let operations = server.receivedOperations()
        #expect(operations.contains(.getVendorStorageIDs))
        #expect(operations.contains(.getObjectHandles))
    }

    @Test func boundsEachIncrementWithoutCappingTheCatalog() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let cursor = try session.beginMediaBrowse()
        let page = try cursor.nextPage(maxObjects: 3)

        // Exactly 3 GetObjectInfo round trips — a packed card cannot block
        // the session thread past one page, while the cursor remains live.
        let infoCount = server.receivedOperations().filter { $0 == .getObjectInfo }.count
        #expect(infoCount == 3)
        #expect(page.inspectedObjectCount == 3)
        #expect(page.hasMore)
        // Newest handles first: the inspected tail is 100NIKON (filtered),
        // C0008.MOV, DSC_0007.JPG.
        #expect(page.clips.map(\.filename) == ["C0008.MOV", "DSC_0007.JPG"])

        let remaining = try collect(cursor, pageSize: 3)
        #expect((page.clips + remaining).count == 8)
        #expect(
            server.receivedOperations().filter { $0 == .getObjectInfo }.count
                == FakeZRMediaCard.objects.count)
    }

    @Test func servesEmptyCardAsEmptyList() throws {
        var options = FakeZRServer.Options()
        options.mediaObjects = []
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let page = try session.beginMediaBrowse().nextPage(maxObjects: 32)
        #expect(page.clips.isEmpty)
        #expect(!page.hasMore)
    }

    @Test func propagatesTransportFailureWhileSnapshottingHandles() throws {
        var options = FakeZRServer.Options()
        options.disconnectsOnGetObjectHandles = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(throws: PTPIPClientSessionError.connectionClosed) {
            try session.beginMediaBrowse()
        }
    }

    @Test func fetchesPerObjectThumbnails() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let first = try #require(try session.thumbnail(handle: 0x1001))
        #expect(first == Data(FakeZRMediaCard.objects[0].thumbnail))
        #expect(first.prefix(3) == Data([0xFF, 0xD8, 0xFF]))  // decodable JPEG

        // Handle routing: a different object returns different bytes.
        let sixth = try #require(try session.thumbnail(handle: 0x1006))
        #expect(sixth == Data(FakeZRMediaCard.objects[5].thumbnail))
        #expect(sixth != first)

        // The folder has no thumbnail — nil, not an error.
        #expect(try session.thumbnail(handle: 0x100A) == nil)
    }

    @Test func serializesCoreMediaPolicyIntoWireRecords() throws {
        let clips = [
            FacadeMediaClip(
                handle: 0x1001, storageID: 0x0001_0001, sizeBytes: 1_284_505_600,
                captureDate: "20260713T101010", pixelWidth: 5760, pixelHeight: 3240,
                sourcePixelWidth: 6048, sourcePixelHeight: 3402,
                filename: "C0001.MOV"),
            FacadeMediaClip(
                handle: 0x1008, storageID: 0x0001_0001, sizeBytes: 8_400_000,
                captureDate: "20260714T102030", pixelWidth: 8256, pixelHeight: 5504,
                filename: "DSC_0007.JPG"),
            FacadeMediaClip(
                handle: 0x100A, storageID: 0x0001_0001, sizeBytes: 10_400_000,
                captureDate: "20260714T103030", pixelWidth: 8256, pixelHeight: 5504,
                filename: "DSC_0008.HEIC"),
            FacadeMediaClip(
                handle: 0x100B, storageID: 0x0001_0001, sizeBytes: 50_400_000,
                captureDate: "20260714T104030", pixelWidth: 8256, pixelHeight: 5504,
                filename: "DSC_0009.NEF"),
        ]
        #expect(
            MediaListWire.encode(clips) == """
                4097\t65537\t1284505600\t20260713T101010\t5760\t3240\t6048\t3402\t1\tproxy\t\t\tC0001.MOV
                4104\t65537\t8400000\t20260714T102030\t8256\t5504\t0\t0\t0\tstill\tprogressive\tJPEG\tDSC_0007.JPG
                4106\t65537\t10400000\t20260714T103030\t8256\t5504\t0\t0\t0\tstill\tcomplete\tHEIF\tDSC_0008.HEIC
                4107\t65537\t50400000\t20260714T104030\t8256\t5504\t0\t0\t0\tstill\tthumbnail\tNikon RAW\tDSC_0009.NEF
                """)
        #expect(MediaListWire.encode([]).isEmpty)
    }

    @Test func pagesEveryCardRoundRobinAndNewestFirst() throws {
        let snapshots = [
            MediaBrowseStorageSnapshot(storageID: 1, handles: [11, 12, 13, 14, 15]),
            MediaBrowseStorageSnapshot(storageID: 2, handles: [21, 22]),
        ]
        var requested: [MediaObjectHandle] = []
        let cursor = FacadeMediaBrowseCursor(snapshots: snapshots) { object in
            requested.append(object)
            return FacadeMediaClip(
                handle: object.handle,
                storageID: object.storageID,
                sizeBytes: 1,
                captureDate: "20260715T120000",
                pixelWidth: 1,
                pixelHeight: 1,
                filename: "C\(object.handle).MOV")
        }

        var pages: [FacadeMediaBrowsePage] = []
        repeat {
            pages.append(try cursor.nextPage(maxObjects: 2))
        } while pages.last?.hasMore == true

        #expect(
            pages.allSatisfy {
                $0.inspectedObjectCount <= 2 && $0.clips.count + $0.removedObjects.count <= 2
            })
        #expect(
            requested.prefix(4) == [
                MediaObjectHandle(storageID: 1, handle: 15),
                MediaObjectHandle(storageID: 2, handle: 22),
                MediaObjectHandle(storageID: 1, handle: 14),
                MediaObjectHandle(storageID: 2, handle: 21),
            ])
        #expect(Set(pages.flatMap(\.clips).map(\.storageID)) == [1, 2])
        #expect(pages.flatMap(\.clips).count == 7)
    }

    @Test func appliesProxyPairingAcrossPageAndCardBoundaries() throws {
        let master = FacadeMediaClip(
            handle: 2, storageID: 1, sizeBytes: 2, captureDate: "", pixelWidth: 1,
            pixelHeight: 1, filename: "A001_C001.R3D")
        let proxy = FacadeMediaClip(
            handle: 3, storageID: 2, sizeBytes: 1, captureDate: "", pixelWidth: 1,
            pixelHeight: 1, filename: "A001_C001.MP4")
        let clipsByHandle = [master.handle: master, proxy.handle: proxy]
        let cursor = FacadeMediaBrowseCursor(
            snapshots: [
                MediaBrowseStorageSnapshot(storageID: 1, handles: [master.handle]),
                MediaBrowseStorageSnapshot(storageID: 2, handles: [proxy.handle]),
            ],
            fetchClip: { clipsByHandle[$0.handle] })

        let first = try cursor.nextPage(maxObjects: 1)
        #expect(first.clips.map(\.filename) == [master.filename])
        #expect(first.removedObjects.isEmpty)
        #expect(first.hasMore)
        let second = try cursor.nextPage(maxObjects: 1)
        #expect(second.clips.isEmpty)
        #expect(
            second.removedObjects
                == [FacadeMediaClipIdentity(master)])
        #expect(second.hasMore)
        let third = try cursor.nextPage(maxObjects: 1)
        #expect(third.clips.map(\.filename) == [proxy.filename])
        #expect(third.clips.first?.sourcePixelWidth == master.pixelWidth)
        #expect(third.clips.first?.sourcePixelHeight == master.pixelHeight)
        #expect(third.removedObjects.isEmpty)
        #expect(!third.hasMore)
    }

    @Test func enrichesProxyWhenMasterArrivesOnALaterPage() throws {
        let proxy = FacadeMediaClip(
            handle: 3, storageID: 1, sizeBytes: 1, captureDate: "", pixelWidth: 1,
            pixelHeight: 1, filename: "A001_C001.MP4")
        let master = FacadeMediaClip(
            handle: 2, storageID: 2, sizeBytes: 2, captureDate: "", pixelWidth: 6_144,
            pixelHeight: 3_240, filename: "A001_C001.R3D")
        let clipsByHandle = [proxy.handle: proxy, master.handle: master]
        let cursor = FacadeMediaBrowseCursor(
            snapshots: [
                MediaBrowseStorageSnapshot(storageID: 1, handles: [proxy.handle]),
                MediaBrowseStorageSnapshot(storageID: 2, handles: [master.handle]),
            ],
            fetchClip: { clipsByHandle[$0.handle] })

        let first = try cursor.nextPage(maxObjects: 1)
        #expect(first.clips == [proxy])
        #expect(first.hasMore)

        let second = try cursor.nextPage(maxObjects: 1)
        #expect(second.clips.isEmpty)
        #expect(second.removedObjects == [FacadeMediaClipIdentity(master)])
        #expect(second.hasMore)

        let third = try cursor.nextPage(maxObjects: 1)
        let enriched = try #require(third.clips.first)
        #expect(enriched.filename == proxy.filename)
        #expect(enriched.sourcePixelWidth == master.pixelWidth)
        #expect(enriched.sourcePixelHeight == master.pixelHeight)
        #expect(third.removedObjects.isEmpty)
        #expect(!third.hasMore)
    }

    @Test func removesSuppressedProxyFirstMasterWithoutDimensions() throws {
        let proxy = FacadeMediaClip(
            handle: 3, storageID: 1, sizeBytes: 1, captureDate: "20260715T120000",
            pixelWidth: 1, pixelHeight: 1, filename: "A001_C001.MP4")
        let master = FacadeMediaClip(
            handle: 2, storageID: 2, sizeBytes: 2, captureDate: "20260715T120001",
            pixelWidth: 0, pixelHeight: 0, filename: "A001_C001.R3D")
        let clipsByHandle = [proxy.handle: proxy, master.handle: master]
        let cursor = FacadeMediaBrowseCursor(
            snapshots: [
                MediaBrowseStorageSnapshot(storageID: 1, handles: [proxy.handle]),
                MediaBrowseStorageSnapshot(storageID: 2, handles: [master.handle]),
            ],
            fetchClip: { clipsByHandle[$0.handle] })

        let first = try cursor.nextPage(maxObjects: 1)
        #expect(first.clips == [proxy])
        let second = try cursor.nextPage(maxObjects: 1)
        #expect(second.clips.isEmpty)
        #expect(second.removedObjects == [FacadeMediaClipIdentity(master)])
        #expect(!second.hasMore)
    }

    @Test func cancellationStopsTheNextPage() throws {
        let cursor = FacadeMediaBrowseCursor(
            snapshots: [MediaBrowseStorageSnapshot(storageID: 1, handles: [1])],
            fetchClip: { _ in nil })
        cursor.cancel()

        #expect(throws: FacadeMediaBrowseCursorError.cancelled) {
            try cursor.nextPage(maxObjects: 1)
        }
    }

    @Test func serializesVersionedPageHeaderAndRecords() {
        let clip = FacadeMediaClip(
            handle: 1, storageID: 2, sizeBytes: 3, captureDate: "", pixelWidth: 4,
            pixelHeight: 5, filename: "C0001.MOV")

        #expect(
            MediaBrowsePageWire.encode(
                FacadeMediaBrowsePage(
                    clips: [clip], inspectedObjectCount: 32, hasMore: true))
                == "OZCMEDIA2\t1\t32\t0\n1\t2\t3\t\t4\t5\t0\t0\t1\tproxy\t\t\tC0001.MOV")
        #expect(
            MediaBrowsePageWire.encode(
                FacadeMediaBrowsePage(
                    clips: [],
                    removedObjects: [FacadeMediaClipIdentity(clip)],
                    inspectedObjectCount: 0,
                    hasMore: false))
                == "OZCMEDIA2\t0\t0\t1\n-\t2\t1\t\tC0001.MOV")
    }

    @Test func deleteRemovesTheObjectFromEveryLaterListing() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        try session.deleteObject(handle: 0x1001)
        #expect(server.deletedHandles() == [0x1001])

        // A fresh enumeration no longer surfaces the deleted object.
        let clips = try collect(session.beginMediaBrowse())
        #expect(!clips.map(\.filename).contains("C0001.MOV"))
        #expect(clips.count == 7)

        // The card refuses a second delete of the same handle.
        #expect(throws: PTPIPClientSessionError.self) {
            try session.deleteObject(handle: 0x1001)
        }
    }

    @Test func ratingRoundTripsThroughTheCameraWithRoundDown() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        // Unrated JPEG reads the Off step.
        #expect(try session.objectRating(handle: 0x1008) == 0)

        // Steps write through exactly; the camera stays source of truth.
        try session.setObjectRating(handle: 0x1008, value: 75)
        #expect(try session.objectRating(handle: 0x1008) == 75)
        #expect(server.objectRating(handle: 0x1008) == 75)

        // An off-step value rounds down to the nearest step, like the body.
        try session.setObjectRating(handle: 0x1008, value: 60)
        #expect(try session.objectRating(handle: 0x1008) == 50)
    }

    @Test func rawStillsRefuseTheRatingProperty() throws {
        var options = FakeZRServer.Options()
        options.mediaObjects = [
            FakeZRMediaObject(
                handle: 0x2001, filename: "DSC_0001.NEF", objectFormat: 0x3801,
                sizeBytes: 30_000_000, captureDate: "20260714T102030",
                pixelWidth: 8256, pixelHeight: 5504, thumbnail: FakeZRMediaCard.thumb7)
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(throws: PTPIPClientSessionError.self) {
            try session.objectRating(handle: 0x2001)
        }
        #expect(throws: PTPIPClientSessionError.self) {
            try session.setObjectRating(handle: 0x2001, value: 25)
        }
    }

    /// Not a test: an opt-in dev server for the on-device end-to-end. Run
    /// `ZC_FAKE_ZR_PORT=15740 swift test --filter servesFakeZRForMediaBrowse`
    /// on the Mac, `adb reverse tcp:15740 tcp:15740`, then launch the app with
    /// `--es zc.session.host 127.0.0.1`. Serves for an hour or until killed.
    /// `ZC_FAKE_ZR_CLIPS=0` serves an empty card (the browse empty state).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZC_FAKE_ZR_PORT"] != nil))
    func servesFakeZRForMediaBrowseDemo() throws {
        var options = FakeZRServer.Options()
        options.port =
            UInt16(ProcessInfo.processInfo.environment["ZC_FAKE_ZR_PORT"] ?? "") ?? 15_740
        if ProcessInfo.processInfo.environment["ZC_FAKE_ZR_CLIPS"] == "0" {
            options.mediaObjects = []
        }
        if let path = ProcessInfo.processInfo.environment["ZC_FAKE_ZR_MEDIA"] {
            options.mediaPayloadFileURL = URL(fileURLWithPath: path)
        }
        let server = try FakeZRServer(options: options)
        print("fake ZR serving on 127.0.0.1:\(server.port) — Ctrl-C to stop")
        Thread.sleep(forTimeInterval: 3_600)
        server.stop()
    }
}
