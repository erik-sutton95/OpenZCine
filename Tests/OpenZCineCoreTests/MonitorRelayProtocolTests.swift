import Foundation
import Testing

@testable import OpenZCineCore

/// The relay runs over TCP, which is a byte stream with no message boundaries of its own. Almost
/// every failure mode of a protocol like this is a framing failure that presents as garbage much
/// later, so the framing is what these pin.
@Suite("Monitor relay protocol")
struct MonitorRelayProtocolTests {

    private func hello() -> Data {
        try! JSONEncoder().encode(
            MonitorRelayHello(
                version: MonitorRelayProtocol.version, hostName: "A-cam iPhone",
                cameraName: "Nikon ZR"))
    }

    @Test("A framed message round-trips with its kind and payload intact")
    func roundTrip() throws {
        let payload = hello()
        let wire = MonitorRelayFraming.encode(kind: .hello, payload: payload)
        let decoded = try #require(try MonitorRelayFraming.decode(from: wire))
        #expect(decoded.kind == .hello)
        #expect(decoded.payload == payload)
        #expect(decoded.consumedBytes == wire.count)
    }

    /// The case a stream protocol lives or dies on: a read that stops mid-message must leave the
    /// buffer untouched and be retried, never consumed as a short message.
    @Test("A partial message decodes to nothing and consumes nothing")
    func partialMessageWaits() throws {
        let wire = MonitorRelayFraming.encode(kind: .state, payload: hello())
        for prefixLength in [0, 1, 4, MonitorRelayFraming.headerBytes, wire.count - 1] {
            let partial = wire.prefix(prefixLength)
            #expect(try MonitorRelayFraming.decode(from: Data(partial)) == nil)
        }
    }

    /// TCP coalesces writes, so two sends routinely arrive as one read. The reader has to peel
    /// them one at a time and report exactly how much it took.
    @Test("Coalesced messages peel off one at a time")
    func coalescedMessages() throws {
        var buffer = Data()
        buffer.append(MonitorRelayFraming.encode(kind: .hello, payload: hello()))
        buffer.append(MonitorRelayFraming.encode(kind: .releaseControl, payload: Data()))

        let first = try #require(try MonitorRelayFraming.decode(from: buffer))
        #expect(first.kind == .hello)
        buffer.removeFirst(first.consumedBytes)

        let second = try #require(try MonitorRelayFraming.decode(from: buffer))
        #expect(second.kind == .releaseControl)
        #expect(second.payload.isEmpty)
        buffer.removeFirst(second.consumedBytes)
        #expect(buffer.isEmpty)
    }

    /// A desynchronised or hostile stream must not be able to make the reader allocate without
    /// bound. The caller's contract is to drop the connection, so this has to throw rather than
    /// return nil — nil means "wait for more", and it would wait forever.
    @Test("An impossible length is an error, not a request for more bytes")
    func oversizedPayloadThrows() {
        var wire = Data()
        wire.append(contentsOf: ByteCoding.uint32BE(UInt32(UInt32.max)))
        wire.append(MonitorRelayProtocol.Kind.frame.rawValue)
        #expect(throws: MonitorRelayFraming.DecodeError.self) {
            _ = try MonitorRelayFraming.decode(from: wire)
        }
        // A zero-length payload cannot even hold the kind byte.
        var empty = Data()
        empty.append(contentsOf: ByteCoding.uint32BE(0))
        empty.append(contentsOf: [0, 0, 0, 0])
        #expect(throws: MonitorRelayFraming.DecodeError.self) {
            _ = try MonitorRelayFraming.decode(from: empty)
        }
    }

    @Test("An unknown kind is rejected rather than guessed at")
    func unknownKindThrows() {
        var wire = Data()
        wire.append(contentsOf: ByteCoding.uint32BE(1))
        wire.append(0xEE)
        #expect(throws: MonitorRelayFraming.DecodeError.self) {
            _ = try MonitorRelayFraming.decode(from: wire)
        }
    }

    /// The picture travels beside its metadata in one message so the AF box can never arrive a
    /// frame out of step with the picture it was measured on.
    @Test("A frame carries its readings and its image without disturbing either")
    func framePayloadRoundTrip() throws {
        let metadata = MonitorRelayFrameMetadata(
            timecode: Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 4),
            isRecording: true,
            focus: MonitorRelayFrameMetadata.Focus(
                coordinateWidth: 6048, coordinateHeight: 3400, focusResult: 2,
                subjectDetectionActive: true, trackingAFActive: false, selectedBoxIndex: 1,
                boxes: [
                    .init(centerX: 100, centerY: 200, width: 38, height: 40),
                    .init(centerX: 300, centerY: 400, width: 20, height: 22),
                ]),
            levelRoll: -1.5, levelPitch: 0.25,
            sound: MonitorRelayFrameMetadata.Sound(
                peakLeft: 12, peakRight: 10, currentLeft: 9, currentRight: 7),
            codec: MonitorRelayProtocol.FrameCodec.hevc,
            isKeyframe: true,
            // Parameter sets are opaque bytes and must survive exactly: one bit wrong and the
            // viewer's decoder rejects every frame that follows.
            parameterSets: [Data([0x40, 0x01, 0x0C]), Data([0x42, 0x01]), Data([0x44, 0x01])])
        // Deliberately not a valid JPEG: the payload must survive as opaque bytes.
        let image = Data((0..<4096).map { UInt8($0 % 251) })

        let encoded = try MonitorRelayFramePayload.encode(metadata: metadata, image: image)
        let decoded = try MonitorRelayFramePayload.decode(encoded)
        #expect(decoded.metadata == metadata)
        #expect(decoded.image == image)
    }

    @Test("A truncated frame payload is an error rather than a half-read picture")
    func truncatedFramePayload() throws {
        let encoded = try MonitorRelayFramePayload.encode(
            metadata: MonitorRelayFrameMetadata(
                timecode: nil, isRecording: false, focus: nil, levelRoll: nil, levelPitch: nil,
                sound: nil),
            image: Data([1, 2, 3]))
        #expect(throws: MonitorRelayFramePayload.DecodeError.self) {
            _ = try MonitorRelayFramePayload.decode(encoded.prefix(3))
        }
    }

    /// A viewer must refuse a host it cannot speak to rather than render nonsense from a payload
    /// whose shape it is guessing at.
    @Test("The wire version travels in the greeting")
    func helloCarriesVersion() throws {
        let decoded = try JSONDecoder().decode(MonitorRelayHello.self, from: hello())
        #expect(decoded.version == MonitorRelayProtocol.version)
        #expect(decoded.hostName == "A-cam iPhone")
        #expect(decoded.cameraName == "Nikon ZR")
    }

    /// The service type has to match `NSBonjourServices` in the app's Info.plist exactly, or the
    /// browser is denied with no error the operator can act on.
    @Test("The Bonjour service type is a well-formed TCP service")
    func serviceType() {
        #expect(MonitorRelayProtocol.serviceType.hasPrefix("_"))
        #expect(MonitorRelayProtocol.serviceType.hasSuffix("._tcp"))
        // Bonjour caps the service name at 15 characters between the underscore and the dot.
        let name = MonitorRelayProtocol.serviceType
            .dropFirst()
            .replacingOccurrences(of: "._tcp", with: "")
        #expect(name.count <= 15)
    }
}
