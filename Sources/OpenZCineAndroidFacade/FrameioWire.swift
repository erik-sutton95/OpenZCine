import Foundation
import OpenZCineCore

/// Android-facing wire over the portable Frame.io OAuth and V4 request policy.
///
/// Kotlin owns browser presentation, Android Keystore storage, and HTTPS I/O.
/// This facade owns PKCE generation, state validation, exact redirect matching,
/// Adobe form construction, V4 endpoint paths, and Codable response decoding so
/// the Android shell cannot gradually fork the iOS policy. The returned JSON is
/// process-local JNI data and must never be logged because token and code wires
/// can contain bearer material.
public enum AndroidFrameioWire {
    /// Names accepted by `apiRequest` and `decodedResponse`.
    public enum Operation {
        public static let accounts = "accounts"
        public static let workspaces = "workspaces"
        public static let projects = "projects"
        public static let createProject = "create_project"
        public static let createFile = "create_file"
        public static let uploadStatus = "upload_status"
        public static let token = "token"
    }

    private struct AuthorizationStart: Codable, Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        let authorizationURL: String
        let state: String
        let verifier: String

        var description: String { "AuthorizationStart(redacted)" }
        var debugDescription: String { description }
    }

    private struct HTTPRequest: Codable, Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        let url: String
        let method: String
        let body: String?

        var description: String { "HTTPRequest(redacted)" }
        var debugDescription: String { description }
    }

    /// Starts a new shared-core PKCE authorization transaction.
    ///
    /// - Returns: JSON containing the authorize URL, state, and verifier, or
    ///   `nil` when build-time configuration is absent or malformed.
    public static func beginAuthorization(clientID: String, redirectURI: String) -> String? {
        guard let config = configuration(clientID: clientID, redirectURI: redirectURI) else {
            return nil
        }
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let authorizationURL = FrameioOAuth.authorizeURL(config: config, pkce: pkce, state: state)
        return encode(
            AuthorizationStart(
                authorizationURL: authorizationURL.absoluteString,
                state: state,
                verifier: pkce.verifier))
    }

    /// Validates the callback URI against the registered redirect and shared
    /// OAuth state, returning only the authorization code on success.
    public static func parseRedirect(
        redirectURI: String, callbackURI: String, expectedState: String
    ) -> String? {
        guard
            validatedRedirectURI(redirectURI) != nil,
            let callback = URL(string: callbackURI),
            redirectMatches(
                expectedURI: redirectURI,
                callbackURI: callbackURI,
                callback: callback)
        else { return nil }
        return try? FrameioOAuth.parseRedirect(callback, expectedState: expectedState)
    }

    /// Plans the Adobe IMS code-exchange or refresh-token POST without issuing
    /// it. `kind` is `"exchange"` or `"refresh"`.
    public static func tokenRequest(
        kind: String, clientID: String, redirectURI: String, code: String?, verifier: String?,
        refreshToken: String?
    ) -> String? {
        guard let config = configuration(clientID: clientID, redirectURI: redirectURI) else {
            return nil
        }
        let form: FrameioFormRequest
        switch kind {
        case "exchange":
            guard let code, !code.isEmpty, let verifier, !verifier.isEmpty else { return nil }
            form = FrameioOAuth.tokenExchangeForm(config: config, code: code, verifier: verifier)
        case "refresh":
            guard let refreshToken, !refreshToken.isEmpty else { return nil }
            form = FrameioOAuth.refreshForm(config: config, refreshToken: refreshToken)
        default:
            return nil
        }
        return encode(
            HTTPRequest(url: form.url.absoluteString, method: "POST", body: form.formBody))
    }

    /// Plans one core-owned Frame.io V4 request. The Android HTTPS adapter
    /// attaches the bearer token but cannot assemble endpoint paths itself.
    /// Request planning is intentionally independent of OAuth client identity:
    /// the Android controller refuses to send any result until the separately
    /// validated build-time Adobe configuration is present.
    public static func apiRequest(
        operation: String, accountID: String?, workspaceID: String?, folderID: String?,
        fileID: String?, name: String?, fileSize: Int64
    ) -> String? {
        let request: FrameioAPIRequest
        do {
            switch operation {
            case Operation.accounts:
                request = try FrameioAPI.accounts()
            case Operation.workspaces:
                guard let accountID else { return nil }
                request = try FrameioAPI.workspaces(accountID: accountID)
            case Operation.projects:
                guard let accountID, let workspaceID else { return nil }
                request = try FrameioAPI.projects(accountID: accountID, workspaceID: workspaceID)
            case Operation.createProject:
                guard let accountID, let workspaceID, let name else { return nil }
                request = try FrameioAPI.createProject(
                    accountID: accountID, workspaceID: workspaceID, name: name)
            case Operation.createFile:
                guard let accountID, let folderID, let name, let size = Int(exactly: fileSize)
                else {
                    return nil
                }
                request = try FrameioAPI.createFile(
                    accountID: accountID, folderID: folderID, name: name, fileSize: size)
            case Operation.uploadStatus:
                guard let accountID, let fileID else { return nil }
                request = try FrameioAPI.uploadStatus(accountID: accountID, fileID: fileID)
            default:
                return nil
            }
        } catch {
            return nil
        }
        return encode(
            HTTPRequest(
                url: request.url.absoluteString,
                method: request.method.rawValue,
                body: request.body.map { String(decoding: $0, as: UTF8.self) }))
    }

    /// Decodes a Frame.io JSON response with the portable model types, then
    /// returns canonical JSON for Kotlin's presentation adapter.
    public static func decodedResponse(operation: String, response: String) -> String? {
        guard !response.isEmpty else { return nil }
        let data = Data(response.utf8)
        do {
            switch operation {
            case Operation.token:
                return try canonical(FrameioToken.self, from: data)
            case Operation.accounts:
                return try canonical(FrameioList<FrameioAccount>.self, from: data)
            case Operation.workspaces:
                return try canonical(FrameioList<FrameioWorkspace>.self, from: data)
            case Operation.projects:
                return try canonical(FrameioList<FrameioProject>.self, from: data)
            case Operation.createProject:
                return try canonical(FrameioOne<FrameioProject>.self, from: data)
            case Operation.createFile:
                return try canonical(FrameioCreateFileResponse.self, from: data)
            case Operation.uploadStatus:
                return try canonical(FrameioFileUploadStatus.self, from: data)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// Resolves the upload MIME family through the shared Frame.io policy.
    public static func mediaType(forFilename filename: String) -> String {
        FrameioMediaType.forFilename(filename)
    }

    private static func configuration(clientID: String, redirectURI: String)
        -> FrameioConfiguration?
    {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedClientID.isEmpty,
            trimmedClientID == clientID,
            validatedRedirectURI(redirectURI) != nil
        else { return nil }
        return FrameioConfiguration(clientID: clientID, redirectURI: redirectURI)
    }

    private static func validatedRedirectURI(_ redirectURI: String) -> URL? {
        let trimmedRedirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedRedirect.isEmpty,
            trimmedRedirect == redirectURI,
            let redirect = URL(string: redirectURI),
            let scheme = redirect.scheme,
            redirect.host != nil,
            scheme.caseInsensitiveCompare("http") != .orderedSame,
            scheme.caseInsensitiveCompare("https") != .orderedSame,
            redirect.user == nil,
            redirect.password == nil,
            redirect.query == nil,
            redirect.fragment == nil
        else { return nil }
        return redirect
    }

    private static func redirectMatches(
        expectedURI: String,
        callbackURI: String,
        callback: URL
    ) -> Bool {
        guard
            callback.user == nil,
            callback.password == nil,
            callback.fragment == nil,
            let queryStart = callbackURI.firstIndex(of: "?")
        else { return false }
        return callbackURI[..<queryStart] == expectedURI[...]
    }

    private static func canonical<Value: Codable & Sendable>(_ type: Value.Type, from data: Data)
        throws
        -> String
    {
        let value = try FrameioJSON.decode(type, from: data)
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func encode<Value: Encodable>(_ value: Value) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
