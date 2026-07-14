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

    @Test func listsBrowsableMediaWithMetadata() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let clips = try session.listMedia()

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

        // Card-present volume discovery went through the vendor op first.
        let operations = server.receivedOperations()
        #expect(operations.contains(.getVendorStorageIDs))
        #expect(operations.contains(.getObjectHandles))
    }

    @Test func boundsEnumerationAtMaxObjects() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let clips = try session.listMedia(maxObjects: 3)

        // Exactly 3 GetObjectInfo round trips — a packed card cannot block
        // the session thread past the cap.
        let infoCount = server.receivedOperations().filter { $0 == .getObjectInfo }.count
        #expect(infoCount == 3)
        // Newest handles first: the inspected tail is 100NIKON (filtered),
        // C0008.MOV, DSC_0007.JPG.
        #expect(clips.map(\.filename) == ["C0008.MOV", "DSC_0007.JPG"])
    }

    @Test func servesEmptyCardAsEmptyList() throws {
        var options = FakeZRServer.Options()
        options.mediaObjects = []
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(try session.listMedia().isEmpty)
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

    @Test func encodesWireRecords() throws {
        let clips = [
            FacadeMediaClip(
                handle: 0x1001, storageID: 0x0001_0001, sizeBytes: 1_284_505_600,
                captureDate: "20260713T101010", pixelWidth: 5760, pixelHeight: 3240,
                filename: "C0001.MOV", isPlayableProxy: true),
            FacadeMediaClip(
                handle: 0x1008, storageID: 0x0001_0001, sizeBytes: 8_400_000,
                captureDate: "20260714T102030", pixelWidth: 8256, pixelHeight: 5504,
                filename: "DSC_0007.JPG", isPlayableProxy: false),
        ]
        #expect(
            MediaListWire.encode(clips) == """
                4097\t65537\t1284505600\t20260713T101010\t5760\t3240\t1\tC0001.MOV
                4104\t65537\t8400000\t20260714T102030\t8256\t5504\t0\tDSC_0007.JPG
                """)
        #expect(MediaListWire.encode([]).isEmpty)
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
