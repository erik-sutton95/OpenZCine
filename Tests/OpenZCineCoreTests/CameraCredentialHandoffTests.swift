import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Camera credential handoff")
struct CameraCredentialHandoffTests {
    private func request(
        serial: String? = nil,
        name: String = "Nikon ZR",
        ssid: String? = nil
    ) -> CredentialHandoffRequest {
        CredentialHandoffRequest(
            requestID: "R1",
            requesterName: "Erik's iPad",
            cameraSerialNumber: serial,
            cameraDisplayName: name,
            knownSSID: ssid
        )
    }

    @Test("A serial picks its own camera out of several")
    func matchesOnSerial() {
        let candidates = [
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_7005555", serialNumber: "7005555"),
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_6002199", serialNumber: "6002199"),
        ]
        let match = CredentialHandoffMatch.candidate(
            for: request(serial: "6002199"), among: candidates)
        #expect(match?.ssid == "NIKON_ZR_6002199")
    }

    @Test("An exact SSID answers a request with no serial")
    func matchesOnExactSSID() {
        let candidates = [
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_6002199", serialNumber: nil)
        ]
        let match = CredentialHandoffMatch.candidate(
            for: request(ssid: "nikon_zr_6002199"), among: candidates)
        #expect(match?.ssid == "NIKON_ZR_6002199")
    }

    /// The whole reason this matching is a pure function with a test: a product name is shared by
    /// every body of that model, so honouring it would hand one operator's key to another's phone.
    @Test("A shared product name never matches")
    func neverMatchesOnDisplayName() {
        let candidates = [
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_6002199", serialNumber: "6002199")
        ]
        let match = CredentialHandoffMatch.candidate(
            for: request(name: "Nikon ZR"), among: candidates)
        #expect(match == nil)
    }

    @Test("A serial that matches nothing here does not fall through to the first network")
    func unknownSerialDoesNotFallThrough() {
        let candidates = [
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_6002199", serialNumber: "6002199")
        ]
        let match = CredentialHandoffMatch.candidate(
            for: request(serial: "9999999"), among: candidates)
        #expect(match == nil)
    }

    @Test("Serial outranks a stale SSID hint")
    func serialWinsOverSSIDHint() {
        let candidates = [
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_7005555", serialNumber: "7005555"),
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_6002199", serialNumber: "6002199"),
        ]
        let match = CredentialHandoffMatch.candidate(
            for: request(serial: "6002199", ssid: "NIKON_ZR_7005555"),
            among: candidates
        )
        #expect(match?.ssid == "NIKON_ZR_6002199")
    }

    @Test("Blank identity is unanswerable")
    func blankIdentityMatchesNothing() {
        let candidates = [
            CredentialHandoffMatch.Candidate(ssid: "NIKON_ZR_6002199", serialNumber: "6002199")
        ]
        let match = CredentialHandoffMatch.candidate(
            for: request(serial: "   ", ssid: "  "), among: candidates)
        #expect(match == nil)
    }

    @Test("A refusal stops the next prompt")
    func declineLatches() {
        #expect(
            CredentialHandoffPolicy.shouldPrompt(
                requesterName: "Erik's iPad", declinedRequesters: []))
        #expect(
            !CredentialHandoffPolicy.shouldPrompt(
                requesterName: "Erik's iPad", declinedRequesters: ["Erik's iPad"]))
    }

    @Test("Every payload survives the wire")
    func payloadsRoundTrip() throws {
        let grant = CredentialHandoffGrant(
            requestID: "R1", ssid: "NIKON_ZR_6002199", key: "a1b2c3d4", donorName: "iPhone")
        let decodedGrant = try JSONDecoder().decode(
            CredentialHandoffGrant.self, from: JSONEncoder().encode(grant))
        #expect(decodedGrant == grant)

        let decline = CredentialHandoffDecline(
            requestID: "R1", reason: .operatorDeclined, donorName: "iPhone")
        let decodedDecline = try JSONDecoder().decode(
            CredentialHandoffDecline.self, from: JSONEncoder().encode(decline))
        #expect(decodedDecline == decline)

        let ask = request(serial: "6002199")
        let decodedAsk = try JSONDecoder().decode(
            CredentialHandoffRequest.self, from: JSONEncoder().encode(ask))
        #expect(decodedAsk == ask)
    }
}
