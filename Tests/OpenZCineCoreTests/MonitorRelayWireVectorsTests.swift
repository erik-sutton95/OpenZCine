import Foundation
import Testing

@testable import OpenZCineCore

/// The Android relay speaks a Kotlin TRANSCRIPTION of this protocol
/// (`Apps/Android/.../relay/MonitorRelayWire.kt`), pinned to these same vectors in
/// `MonitorRelayWireTest`. JSON payload vectors are DECODE-side (key order is not part of the
/// contract); framing and the frame-payload prefix are byte-exact. Editing the protocol must
/// update BOTH tests — that is the drift alarm firing, not a nuisance.
@Test func relayFramingBytesMatchTheSharedVector() throws {
    let encoded = MonitorRelayFraming.encode(kind: .hello, payload: Data("{}".utf8))
    #expect(Array(encoded) == [0x00, 0x00, 0x00, 0x03, 0x01, 0x7B, 0x7D])
    let decoded = try #require(try MonitorRelayFraming.decode(from: encoded))
    #expect(decoded.kind == .hello)
    #expect(decoded.payload == Data("{}".utf8))
    #expect(decoded.consumedBytes == 7)
}

@Test func relayHelloDecodesTheSharedVector() throws {
    let hello = try JSONDecoder().decode(
        MonitorRelayHello.self,
        from: Data(
            #"{"version":2,"hostName":"iPhone","cameraName":"ZR_6002199","passcode":"4321"}"#
                .utf8))
    #expect(
        hello
            == MonitorRelayHello(
                version: 2, hostName: "iPhone", cameraName: "ZR_6002199", passcode: "4321"))
    let bare = try JSONDecoder().decode(
        MonitorRelayHello.self, from: Data(#"{"version":2,"hostName":"iPad"}"#.utf8))
    #expect(bare == MonitorRelayHello(version: 2, hostName: "iPad", cameraName: nil))
}

@Test func relayJoinDeniedAndControlTokenDecodeTheSharedVectors() throws {
    let denied = try JSONDecoder().decode(
        MonitorRelayJoinDenied.self,
        from: Data(
            #"{"reason":"This broadcast asks for a passcode.","passcodeRequired":true}"#.utf8))
    #expect(
        denied
            == MonitorRelayJoinDenied(
                reason: "This broadcast asks for a passcode.", passcodeRequired: true))
    let token = try JSONDecoder().decode(
        MonitorRelayControlToken.self,
        from: Data(#"{"holderName":"iPhone 17 Pro Max","holderIsRecipient":false}"#.utf8))
    #expect(
        token == MonitorRelayControlToken(holderName: "iPhone 17 Pro Max", holderIsRecipient: false)
    )
}

@Test func relayStateDecodesTheSharedVector() throws {
    let json = """
        {"recordState":"recording","resolutionFrameRate":"6K · 25p","codec":"R3D NE",
        "media":"CFexpress","liveFPS":"25.0","cameraBatteryPercent":76,
        "cameraName":"ZR_6002199","lens":"NIKKOR Z 24-70","temperature":"OK",
        "values":[{"label":"ISO","value":"800"}],
        "mediaStatus":{"gigabytesFree":412,"percentFree":81,"minutesRemaining":96},
        "isRecording":true,"allowsControlRequests":false}
        """
    let state = try JSONDecoder().decode(MonitorRelayState.self, from: Data(json.utf8))
    #expect(state.recordState == .recording)
    #expect(state.resolutionFrameRate == "6K · 25p")
    #expect(state.cameraBatteryPercent == 76)
    #expect(state.values == [MonitorRelayState.Value(label: "ISO", value: "800")])
    #expect(
        state.mediaStatus
            == MediaStatus(gigabytesFree: 412, percentFree: 81, minutesRemaining: 96))
    #expect(state.allowsControlRequests == false)
}

@Test func relayFrameMetadataDecodesTheSharedVector() throws {
    let json = """
        {"isRecording":false,"codec":1,"isKeyframe":true,
        "parameterSets":["QAE=","QgE="],
        "timecode":{"on":true,"hour":0,"minute":0,"second":1,"frame":12}}
        """
    let metadata = try JSONDecoder().decode(MonitorRelayFrameMetadata.self, from: Data(json.utf8))
    #expect(metadata.codec == MonitorRelayProtocol.FrameCodec.hevc)
    #expect(metadata.isKeyframe)
    #expect(metadata.parameterSets == [Data([0x40, 0x01]), Data([0x42, 0x01])])
    #expect(metadata.timecode == Timecode(on: true, hour: 0, minute: 0, second: 1, frame: 12))
    #expect(metadata.focus == nil)
}

@Test func relayCommandsUseTheSingleKeyObjectForm() throws {
    let toggle = try JSONDecoder().decode(
        MonitorRelayCommand.self, from: Data(#"{"toggleRecording":{}}"#.utf8))
    #expect(toggle == .toggleRecording)
    let focus = try JSONDecoder().decode(
        MonitorRelayCommand.self,
        from: Data(
            #"{"focusPoint":{"cameraX":100,"cameraY":200,"coordinateWidth":8192,"coordinateHeight":5464}}"#
                .utf8))
    #expect(
        focus
            == .focusPoint(
                cameraX: 100, cameraY: 200, coordinateWidth: 8192, coordinateHeight: 5464))
    let picker = try JSONDecoder().decode(
        MonitorRelayCommand.self,
        from: Data(#"{"pickerValue":{"picker":"iso","value":"800"}}"#.utf8))
    #expect(picker == .pickerValue(picker: "iso", value: "800"))
    // Encoded form stays the single-key object the Kotlin side parses.
    let encoded = String(
        decoding: try JSONEncoder().encode(MonitorRelayCommand.toggleRecording), as: UTF8.self)
    #expect(encoded.contains("toggleRecording"))
}
