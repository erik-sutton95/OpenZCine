import Foundation
import OpenCineRelay
import Testing

@testable import OpenZCineCore

@Suite struct DeployedRelayCodecTests {
    @Test func deployedProfileKeepsVersionTwoNumericCodecsTXTAndTCPPresence() {
        let profile = DeployedMonitorRelayCodec().profile
        #expect(profile.serviceType == "_openzcine-mon._tcp" && profile.version == 2)
        #expect(profile.maximumPayloadBytes == 8_388_608)
        #expect(profile.servedCameraTXTKey == "ch" && profile.watchableTXTKey == "w")
        #expect(profile.presenceTCPPort == 15741)
        #expect(
            profile.jpegCodec == 0 && profile.hevcCodec == 1 && profile.acceptsPeerCodecDeclaration)
        #expect(RelayWireProfile.sharedMonitor.serviceType == "_opc-mon._tcp")
        #expect(
            RelayWireProfile.sharedMonitor.version == 1
                && RelayWireProfile.sharedMonitor.servedCameraTXTKey == "c")
    }

    @Test func sharedRuntimeHandshakeRoundTripsThroughOriginalDeployedSchema() throws {
        let codec = DeployedMonitorRelayCodec()
        let hello = RelayPeerHello(
            version: 2, hostName: "viewer", passcode: "1234",
            codecs: ["jpeg"], watcherID: "saved-install")
        let body = try codec.encodeHello(hello)
        let original = try JSONDecoder().decode(MonitorRelayHello.self, from: body)
        #expect(original.version == 2 && original.hostName == "viewer")
        #expect(original.passcode == "1234" && original.codecs == ["jpeg"])
        #expect(original.watcherID == "saved-install" && !original.acceptsHEVC)
        #expect(try codec.decodeHello(JSONEncoder().encode(original)) == hello)
        #expect(try codec.decodeHello(Data(#"{"version":2,"hostName":"legacy"}"#.utf8)).acceptsHEVC)
    }

    @Test func typedCommandAndFrameMetadataKeepOriginalPayloadAndOpaqueImage() throws {
        let codec = DeployedMonitorRelayCodec()
        let command = MonitorRelayCommand.pickerValue(picker: "iso", value: "800")
        let object = try #require(
            JSONSerialization.jsonObject(with: codec.encodeCommand(command)) as? NSDictionary)
        let expected = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"pickerValue":{"picker":"iso","value":"800"}}"#.utf8))
                as? NSDictionary)
        #expect(object == expected)
        let metadata = try JSONDecoder().decode(
            MonitorRelayFrameMetadata.self,
            from: Data(
                #"{"codec":1,"isKeyframe":true,"parameterSets":["QAE=","QgE="],"isRecording":false,"timecode":{"on":true,"hour":0,"minute":0,"second":1,"frame":12}}"#
                    .utf8))
        let image = Data([0, 0, 0, 1, 0x26, 0x01, 0xFF])
        let framed = RelayStreamFraming.encode(
            kind: 3, payload: try codec.encodeFrame(metadata: metadata, image: image))
        let message = try #require(
            try RelayStreamFraming.decode(from: framed, profile: codec.profile))
        let decoded = try codec.decodeFrame(message.payload)
        #expect(decoded.metadata == metadata && decoded.image == image)
        #expect(
            codec.videoDescription(of: decoded.metadata)
                == RelayVideoDescription(
                    codec: 1,
                    isKeyframe: true, parameterSets: [Data([0x40, 1]), Data([0x42, 1])]))
        #expect(
            decoded.metadata.timecode
                == Timecode(on: true, hour: 0, minute: 0, second: 1, frame: 12))
    }
}
