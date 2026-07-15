import Foundation
import Testing

@testable import OpenZCineCore

@Test func friendlyNameEncodesAsRawUTF16LEWithTerminator() {
    #expect(PTPIPFriendlyName.encode("ZR") == [0x5A, 0x00, 0x52, 0x00, 0x00, 0x00])
}

@Test func initCommandPayloadMatchesPTPIPWireBytes() throws {
    let guid = Data((0..<16).map(UInt8.init))
    let payload = try PTPIPInitCommandRequest(guid: guid, friendlyName: "ZR").payloadBytes

    #expect(Array(payload[0..<16]) == Array(guid))
    #expect(Array(payload[16..<22]) == [0x5A, 0x00, 0x52, 0x00, 0x00, 0x00])
    #expect(Array(payload[22..<26]) == [0x00, 0x00, 0x01, 0x00])
}

@Test func initiatorIdentityUsesStableCameraProfileValues() {
    #expect(
        Array(PTPIPInitiator.appGUID) == [
            0x4F, 0x70, 0x65, 0x6E, 0x5A, 0x43, 0x69, 0x6E,
            0x65, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
        ])
    #expect(PTPIPInitiator.friendlyName == "WTU-iPhone")
}

@Test func initiatorIdentityPreservesAValidPersistedGUID() {
    let legacyGUID = Data([
        0x5A, 0x43, 0x69, 0x6E, 0x65, 0x43, 0x74, 0x72,
        0x6C, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
    ])

    #expect(PTPIPInitiator.resolvedAppGUID(persistedGUID: legacyGUID) == legacyGUID)
}

@Test func initiatorIdentitySeedsFreshOrInvalidStores() {
    #expect(PTPIPInitiator.resolvedAppGUID(persistedGUID: nil) == PTPIPInitiator.appGUID)
    #expect(
        PTPIPInitiator.resolvedAppGUID(persistedGUID: Data(repeating: 0, count: 8))
            == PTPIPInitiator.appGUID)
}

@Test func pairingChallengeExtractsAsciiPinAndRawHex() {
    let challenge = PTPIPPairingChallenge(
        data: Data([0x5A, 0x52, 0x20, 0x31, 0x32, 0x33, 0x34]),
        cameraName: "ZR_6"
    )

    #expect(challenge.pin == "1234")
    #expect(challenge.cameraName == "ZR_6")
    #expect(challenge.rawHex == "5a 52 20 31 32 33 34")
}

@Test func pairingChallengeExtractsUTF16Pins() {
    let littleEndian = PTPIPPairingChallenge(
        data: Data([0x31, 0x00, 0x32, 0x00, 0x33, 0x00, 0x34, 0x00])
    )
    let bigEndian = PTPIPPairingChallenge(
        data: Data([0x00, 0x36, 0x00, 0x37, 0x00, 0x38, 0x00, 0x39])
    )

    #expect(littleEndian.pin == "1234")
    #expect(bigEndian.pin == "6789")
}

@Test func pairingChallengeExtractsLengthPrefixedPins() {
    let byteDigits = PTPIPPairingChallenge(data: Data([0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4]))
    let number = PTPIPPairingChallenge(data: Data([0x04, 0x00, 0x00, 0x00, 0xE1, 0x10]))

    #expect(byteDigits.pin == "1234")
    #expect(number.pin == "4321")
}

@Test func pairingChallengeExtractsStandaloneBCDAndKeepsUnknownRawBytes() {
    let bcd = PTPIPPairingChallenge(data: Data([0x12, 0x34]))
    let unknown = PTPIPPairingChallenge(data: Data([0xFF, 0xFE, 0xFD]))

    #expect(bcd.pin == "1234")
    #expect(unknown.pin == nil)
    #expect(unknown.rawHex == "ff fe fd")
}

@Test func initCommandRejectsNon16ByteGUID() {
    #expect(throws: PTPIPInitCommandError.invalidGUIDLength(actualLength: 8)) {
        _ = try PTPIPInitCommandRequest(guid: Data(repeating: 0, count: 8), friendlyName: "ZR")
    }
}

@Test func initCommandAckParsesConnectionNumberAndCameraName() throws {
    let payload: [UInt8] = [
        0x78, 0x56, 0x34, 0x12,
        0x00, 0x01, 0x02, 0x03,
        0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F,
        0x5A, 0x00, 0x52, 0x00, 0x5F, 0x00, 0x36, 0x00, 0x00, 0x00,
    ]
    let ack = try PTPIPInitCommandAck(payloadBytes: payload)

    #expect(ack.connectionNumber == 0x1234_5678)
    #expect(ack.cameraName == "ZR_6")
}

@Test func initCommandAckRequiresConnectionNumber() {
    #expect(throws: PTPIPInitCommandAckError.shortPayload(actualLength: 3)) {
        _ = try PTPIPInitCommandAck(payloadBytes: [1, 2, 3])
    }
}

@Test func initFailMapsKnownAndUnknownReasons() throws {
    #expect(try PTPIPInitFail(payloadBytes: [0x01, 0x00, 0x00, 0x00]).reason == .rejectedInitiator)
    #expect(try PTPIPInitFail(payloadBytes: [0x02, 0x00, 0x00, 0x00]).reason == .busy)
    #expect(try PTPIPInitFail(payloadBytes: [0x7F, 0x00, 0x00, 0x00]).reason == .unknown)
}

@Test func initFailRequiresReasonCode() {
    #expect(throws: PTPIPInitFailError.shortPayload(actualLength: 2)) {
        _ = try PTPIPInitFail(payloadBytes: [1, 2])
    }
}

@Test func initEventRequestPayloadIsConnectionNumberLittleEndian() {
    #expect(
        PTPIPInitEventRequest(connectionNumber: 0x1234_5678).payloadBytes == [
            0x78, 0x56, 0x34, 0x12,
        ])
}

@Test func sessionScriptSkipsPairingWhenRequested() throws {
    let script = PTPIPSessionScript(requestPairing: false).requests

    #expect(
        script.map(\.operationCode) == [
            .openSession,
            .changeApplicationMode,
            .getDevicePropValueEx,
            .getDeviceInfo,
        ])
    #expect(script.map(\.transactionID) == [0, 1, 2, 3])
    #expect(script[0].parameters == [1])
    #expect(script[2].parameters == [PTPPropertyCode.movieRecProhibitionCondition.rawValue])
}

@Test func sessionScriptIncludesPairingQueryAndConfirmWhenRequested() throws {
    let script = PTPIPSessionScript(requestPairing: true).requests

    #expect(
        script.map(\.operationCode) == [
            .openSession,
            .getPairingInfo,
            .confirmPairing,
            .changeApplicationMode,
            .getDevicePropValueEx,
            .getDeviceInfo,
        ])
    #expect(script.map(\.transactionID) == [0, 1, 2, 3, 4, 5])
    #expect(script[1].dataPhase == .dataIn)
    #expect(script[2].parameters == [PTPIPSessionScript.pairingConfirmValue])
}

@Test func savedProfileProbeAcceptsUnlockedCameraControlGate() {
    let result = PTPIPSavedProfileProbePolicy.resolve(applicationModeResponse: .ok)

    #expect(result == .accepted)
}

@Test func savedProfileProbeRequiresPairingWhenCameraControlGateIsRejected() {
    let result = PTPIPSavedProfileProbePolicy.resolve(applicationModeResponse: .unknown)

    #expect(result == .requiresPairing)
}

@Test func firstTimePairingWaitsWhenPairingInfoHasNoChallengeBytes() {
    let result = PTPIPPairingInfoPolicy.resolve(
        response: .ok,
        byteCount: 0
    )

    #expect(result == .waitForChallenge)
}

@Test func firstTimePairingPromptsWhenPairingInfoHasChallengeBytes() {
    let result = PTPIPPairingInfoPolicy.resolve(
        response: .ok,
        byteCount: 8
    )

    #expect(result == .promptUser)
}
