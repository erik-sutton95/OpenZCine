import Foundation
import Testing

@testable import OpenZCineCore

private let apiConfig = FrameioConfiguration(
    clientID: "test-client-id",
    redirectURI: "adobe+abc123://adobeid/test-client-id")

@Test func frameioAPIPlansAccountWorkspaceAndProjectPaths() throws {
    let currentUser = try FrameioAPI.currentUser(config: apiConfig)
    let accounts = try FrameioAPI.accounts(config: apiConfig)
    let workspaces = try FrameioAPI.workspaces(config: apiConfig, accountID: "account-1")
    let projects = try FrameioAPI.projects(
        config: apiConfig, accountID: "account-1", workspaceID: "workspace-1")

    #expect(currentUser.url.absoluteString == "https://api.frame.io/v4/me")
    #expect(accounts.method == .get)
    #expect(accounts.url.absoluteString == "https://api.frame.io/v4/accounts")
    #expect(
        workspaces.url.absoluteString == "https://api.frame.io/v4/accounts/account-1/workspaces")
    #expect(
        projects.url.absoluteString
            == "https://api.frame.io/v4/accounts/account-1/workspaces/workspace-1/projects")
    #expect(projects.body == nil)
}

@Test func frameioAPIDefaultEndpointPlanningNeedsNoOAuthClientIdentity() throws {
    let request = try FrameioAPI.accounts()

    #expect(request.url.absoluteString == "https://api.frame.io/v4/accounts")
    #expect(request.method == .get)
}

@Test func frameioAPIPostBodiesUseTheSharedCodableModels() throws {
    let project = try FrameioAPI.createProject(
        config: apiConfig, accountID: "account-1", workspaceID: "workspace-1", name: " Dailies ")
    let file = try FrameioAPI.createFile(
        config: apiConfig, accountID: "account-1", folderID: "folder-1", name: "C0001.MOV",
        fileSize: 42)

    #expect(project.method == .post)
    #expect(String(decoding: try #require(project.body), as: UTF8.self).contains("Dailies"))
    #expect(file.method == .post)
    let fileBody = String(decoding: try #require(file.body), as: UTF8.self)
    #expect(fileBody.contains("file_size"))
    #expect(fileBody.contains("C0001.MOV"))
}

@Test func frameioAPIRejectsUnsafePathIdentifiersAndMediaNames() {
    #expect(throws: FrameioAPIError.invalidIdentifier("../account")) {
        _ = try FrameioAPI.workspaces(config: apiConfig, accountID: "../account")
    }
    #expect(throws: FrameioAPIError.invalidFilename) {
        _ = try FrameioAPI.createFile(
            config: apiConfig, accountID: "account", folderID: "folder", name: "folder/C0001.MOV",
            fileSize: 1)
    }
    #expect(throws: FrameioAPIError.invalidFileSize) {
        _ = try FrameioAPI.createFile(
            config: apiConfig, accountID: "account", folderID: "folder", name: "C0001.MOV",
            fileSize: 0)
    }
}

@Test func frameioAPIErrorsRedactUnsafeIdentifiersFromDiagnosticDescriptions() {
    let unsafeIdentifier = "account?code=unit-authorization-code"
    do {
        _ = try FrameioAPI.workspaces(config: apiConfig, accountID: unsafeIdentifier)
        Issue.record("expected unsafe identifier to fail")
    } catch let error as FrameioAPIError {
        #expect(!String(describing: error).contains(unsafeIdentifier))
        #expect(!String(reflecting: error).contains(unsafeIdentifier))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func frameioAPIRequestRedactsURLQueriesAndBodiesFromDiagnosticDescriptions() throws {
    let authorizationCode = "unit-authorization-code"
    let url = try #require(URL(string: "https://api.example.invalid/v4?code=\(authorizationCode)"))
    let request = FrameioAPIRequest(
        url: url,
        method: .post,
        body: Data("refresh_token=unit-refresh-token".utf8))

    #expect(!String(describing: request).contains(authorizationCode))
    #expect(!String(reflecting: request).contains(authorizationCode))
    #expect(!String(describing: request).contains("unit-refresh-token"))
    #expect(!String(reflecting: request).contains("unit-refresh-token"))
}

@Test func frameioAPIPlansUploadStatusPath() throws {
    let request = try FrameioAPI.uploadStatus(
        config: apiConfig, accountID: "account-1", fileID: "file-1")
    #expect(request.method == .get)
    #expect(
        request.url.absoluteString
            == "https://api.frame.io/v4/accounts/account-1/files/file-1/status")
}
