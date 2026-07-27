// Wire-level proof that picker option lists come from the connected body (#274, #276).
//
// These drive the real facade session over a socket pair against fakes that advertise different
// descriptor enums, and assert both on the option lists that come back and on what reached the
// wire. The pure mapping rules are covered in `PickerOptionPolicyTests`; what is proven here is
// that the session actually asks the body, writes only the exact advertised raw, and — the part
// that matters most next to the #257/#268 work already on this branch — that REBUILDING a list
// never writes anything.

import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct PickerDescriptorWireTests {
    /// A Z6III-shaped body: both H.265 depths, the body's own release-mode order, no user banks.
    private func z6iii() throws -> FakeZRServer {
        var options = FakeZRServer.Options()
        options.model = "Z6III"
        options.serialNumber = "6300002"
        options.movieFileTypeEnum = [0x0000_0801, 0x0001_0800, 0x0001_0A00]
        options.movieFileTypeRaw = 0x0001_0A00  // currently on H.265 10-bit
        options.stillCaptureModeEnum = [0x0001, 0x8010, 0x0002, 0x8019]
        options.exposureProgramEnum = [0x8010, 0x0002, 0x0004, 0x0003, 0x0001]
        return try FakeZRServer(options: options)
    }

    /// A body WITH user banks, to prove the rule is "what the body says", not "never banks".
    private func bodyWithUserBanks() throws -> FakeZRServer {
        var options = FakeZRServer.Options()
        options.model = "Z8"
        options.serialNumber = "8000003"
        options.exposureProgramEnum = [0x0002, 0x0004, 0x0003, 0x0001, 0x8050, 0x8051, 0x8052]
        return try FakeZRServer(options: options)
    }

    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1",
            port: server.port,
            timeoutMilliseconds: 2_000,
            strategy: .savedProfile,
            onPhase: { _, _ in })
    }

    @Test func bothHEVCDepthsReachTheShellBesideTheirCodecRow() throws {
        let server = try z6iii()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        // One row per family; the two H.265 depths ride beside their row (#276 follow-up).
        #expect(controls.codecs == ["H.264", "H.265"])
        #expect(controls.codec == "H.265")
        #expect(
            controls.codecBitDepths == [
                "H.265\u{1E}8-bit\u{1E}H.265 8-bit",
                "H.265\u{1E}10-bit\u{1E}H.265 10-bit",
            ])
        // And the pair lights the depth the body is actually on.
        #expect(controls.codecBitDepth == "10-bit")
    }

    @Test func pickingTenBitPutsTheAdvertisedTenBitValueOnTheWire() throws {
        let server = try z6iii()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        // Leave H.265, then come back to it — the exact reported sequence.
        try session.applyControl(.codec, label: "H.264")
        try session.applyControl(.codec, label: "H.265 10-bit")

        let codecWrites = server.receivedPropertyWrites()
            .filter { $0.property == PTPPropertyCode.movieFileType.rawValue }
            .map { ByteCoding.readUInt32LE(Array($0.data), at: 0) }
        #expect(codecWrites == [0x0000_0801, 0x0001_0A00])

        // Authoritative readback keeps it at 10-bit, and reopening the picker lands on the same
        // row with the same depth lit. The old collapse landed here on 8-bit.
        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(controls.codec == "H.265")
        #expect(controls.codecBitDepth == "10-bit")
    }

    @Test func settlingTheDrumOnACodecRowKeepsTheDepthTheBodyIsOn() throws {
        let server = try z6iii()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        // H.264 is 8-bit here, so returning to the H.265 ROW records 8-bit; only the depth
        // button moves it to 10. The row must never snap to the first advertised variant.
        try session.applyControl(.codec, label: "H.264")
        try session.applyControl(.codec, label: "H.265")
        #expect(
            session.refreshAndroidPropertySnapshot(.bootstrap).controls.codecBitDepth == "8-bit")

        try session.applyControl(.codec, label: "H.265 10-bit")
        #expect(
            session.refreshAndroidPropertySnapshot(.bootstrap).controls.codecBitDepth == "10-bit")
    }

    @Test func aCodecLabelTheBodyNeverAdvertisedIsRefusedRatherThanGuessed() throws {
        let server = try z6iii()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)
        let baseline = server.receivedPropertyWrites().count

        // A depth this body does not offer for that codec, and a codec it does not have at all.
        for label in ["H.265 12-bit", "ProRes 422 HQ"] {
            #expect(throws: (any Error).self) {
                try session.applyControl(.codec, label: label)
            }
        }
        #expect(server.receivedPropertyWrites().count == baseline)
    }

    @Test func theBodysDriveOrderAndProgramSetSurviveToTheShell() throws {
        let server = try z6iii()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(
            controls.driveModes
                == ["Single", "Continuous L", "Continuous H", "Continuous H+"])
        #expect(controls.exposureModes == ["Auto", "P", "S", "A", "M"])
        #expect(!controls.exposureModes.contains { $0.hasPrefix("U") })
    }

    @Test func aBodyWithUserBanksStillAdvertisesThem() throws {
        let server = try bodyWithUserBanks()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(controls.exposureModes == ["P", "S", "A", "M", "U1", "U2", "U3"])
    }

    @Test func rebuildingEveryOptionListWritesNothingToTheBody() throws {
        // The guard that matters next to #257/#268: a descriptor refresh reshapes option lists,
        // and the shells re-resolve an open picker's centred row against the new list. That is
        // the LIST moving, not the operator. Repeated full rebuilds must stay read-only.
        let server = try z6iii()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        for _ in 0..<4 {
            let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
            #expect(!controls.codecs.isEmpty)
        }
        #expect(server.receivedPropertyWrites().isEmpty)
    }

    @Test func swappingBodiesRebuildsTheListsAndWritesNothingToEither() throws {
        // Camera replacement: no list, and no write, may carry from one body to the next.
        let z6 = try z6iii()
        defer { z6.stop() }
        let firstSession = try connect(to: z6)
        let first = firstSession.refreshAndroidPropertySnapshot(.bootstrap).controls
        firstSession.disconnect()
        #expect(first.codecs.contains("H.265"))
        #expect(first.codecBitDepths.contains { $0.hasSuffix("H.265 10-bit") })
        #expect(z6.receivedPropertyWrites().isEmpty)

        let zr = try FakeZRServer()  // default fixture: RAW-first ZR codec set, no banks
        defer { zr.stop() }
        let secondSession = try connect(to: zr)
        defer { secondSession.disconnect() }
        let second = secondSession.refreshAndroidPropertySnapshot(.bootstrap).controls

        // The second body's lists are its own — nothing of the Z6III's survives, including the
        // depth pair, which this body never earns.
        #expect(second.codecBitDepths.isEmpty)
        #expect(second.codecs != first.codecs)
        #expect(zr.receivedPropertyWrites().isEmpty)
    }
}
