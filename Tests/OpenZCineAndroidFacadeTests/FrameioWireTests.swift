import Foundation
import Testing

@testable import OpenZCineAndroidFacade

private let androidClientID = "android-client"
private let androidRedirect = "adobe+android://adobeid/android-client"

@Test func androidFrameioWireBuildsSharedPKCEAuthorization() throws {
    let payload = try #require(
        AndroidFrameioWire.beginAuthorization(
            clientID: androidClientID, redirectURI: androidRedirect))
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String])
    let authorizationURL = try #require(json["authorizationURL"])
    let state = try #require(json["state"])
    let verifier = try #require(json["verifier"])

    let components = try #require(URLComponents(string: authorizationURL))
    let query = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    let challenge = try #require(query["code_challenge"] ?? nil)
    #expect(query["client_id"] == androidClientID)
    #expect(query["redirect_uri"] == androidRedirect)
    #expect(query["state"] == state)
    #expect(!challenge.isEmpty)
    #expect(verifier.count >= 43)
}

@Test func androidFrameioWireRejectsMalformedConfiguration() {
    #expect(
        AndroidFrameioWire.beginAuthorization(clientID: "", redirectURI: androidRedirect) == nil)
    #expect(
        AndroidFrameioWire.beginAuthorization(clientID: androidClientID, redirectURI: "not a URI")
            == nil)
    #expect(
        AndroidFrameioWire.beginAuthorization(
            clientID: androidClientID, redirectURI: "https://example.invalid/oauth") == nil)
    #expect(
        AndroidFrameioWire.beginAuthorization(
            clientID: androidClientID,
            redirectURI: "adobe+android://adobeid/android-client?unexpected=value") == nil)
}

@Test func androidFrameioWireValidatesExactRedirectBeforeReturningCode() {
    let callback = "adobe+android://adobeid/android-client?code=approved&state=state-1"
    #expect(
        AndroidFrameioWire.parseRedirect(
            redirectURI: androidRedirect, callbackURI: callback, expectedState: "state-1")
            == "approved")
    #expect(
        AndroidFrameioWire.parseRedirect(
            redirectURI: androidRedirect,
            callbackURI: "adobe+other://adobeid/android-client?code=approved&state=state-1",
            expectedState: "state-1") == nil)
    #expect(
        AndroidFrameioWire.parseRedirect(
            redirectURI: androidRedirect, callbackURI: callback, expectedState: "wrong") == nil)
}

@Test func androidFrameioWirePlansSharedTokenAndV4Requests() throws {
    let tokenPayload = try #require(
        AndroidFrameioWire.tokenRequest(
            kind: "exchange", clientID: androidClientID, redirectURI: androidRedirect,
            code: "code/+", verifier: "verifier", refreshToken: nil))
    let token = try #require(
        JSONSerialization.jsonObject(with: Data(tokenPayload.utf8)) as? [String: String])
    #expect(token["method"] == "POST")
    #expect(token["url"]?.contains("ims/token/v3?client_id=android-client") == true)
    #expect(token["body"]?.contains("code=code%2F%2B") == true)

    let projectPayload = try #require(
        AndroidFrameioWire.apiRequest(
            operation: AndroidFrameioWire.Operation.projects, accountID: "account",
            workspaceID: "workspace",
            folderID: nil, fileID: nil, name: nil, fileSize: 0))
    let project = try #require(
        JSONSerialization.jsonObject(with: Data(projectPayload.utf8)) as? [String: String])
    #expect(project["method"] == "GET")
    #expect(
        project["url"] == "https://api.frame.io/v4/accounts/account/workspaces/workspace/projects")
}

@Test func androidFrameioWireCanonicalizesSharedResponseModels() throws {
    let token = try #require(
        AndroidFrameioWire.decodedResponse(
            operation: AndroidFrameioWire.Operation.token,
            response:
                #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"bearer"}"#
        ))
    let tokenJSON = try #require(
        JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any])
    #expect(tokenJSON["access_token"] as? String == "access")

    let projects = try #require(
        AndroidFrameioWire.decodedResponse(
            operation: AndroidFrameioWire.Operation.projects,
            response: #"{"data":[{"id":"project","name":"Dailies","root_folder_id":"folder"}]}"#))
    let projectsJSON = try #require(
        JSONSerialization.jsonObject(with: Data(projects.utf8)) as? [String: Any])
    let records = try #require(projectsJSON["data"] as? [[String: Any]])
    #expect(records.first?["root_folder_id"] as? String == "folder")
}
