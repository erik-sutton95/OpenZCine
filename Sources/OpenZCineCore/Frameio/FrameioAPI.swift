import Foundation

/// HTTP method for a Frame.io V4 request planned by the portable core.
public enum FrameioHTTPMethod: String, Codable, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
}

/// A transport-neutral Frame.io V4 request.
///
/// The shared core owns endpoint construction and request-model encoding;
/// platform shells attach the stored bearer token and perform HTTPS with their
/// native client. This keeps Android from carrying a second copy of the API
/// path and JSON-body policy while avoiding FoundationNetworking on Android.
public struct FrameioAPIRequest: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// Fully resolved V4 endpoint URL.
    public let url: URL
    /// HTTP method expected by the endpoint.
    public let method: FrameioHTTPMethod
    /// UTF-8 JSON request body for POST endpoints, otherwise `nil`.
    public let body: Data?

    public init(url: URL, method: FrameioHTTPMethod, body: Data? = nil) {
        self.url = url
        self.method = method
        self.body = body
    }

    /// URL queries and request bodies may carry external-service material.
    public var description: String { "FrameioAPIRequest(method: \(method.rawValue), redacted)" }

    /// URL queries and request bodies may carry external-service material.
    public var debugDescription: String { description }
}

/// Validation errors raised before a platform shell attempts a Frame.io request.
public enum FrameioAPIError: LocalizedError, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case invalidIdentifier(String)
    case invalidProjectName
    case invalidFilename
    case invalidFileSize

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "Frame.io returned an invalid resource identifier."
        case .invalidProjectName:
            "Enter a project name before creating it."
        case .invalidFilename:
            "The media filename is invalid for Frame.io delivery."
        case .invalidFileSize:
            "The media file size is invalid for Frame.io delivery."
        }
    }

    /// Invalid external identifiers must not be reflected into diagnostics.
    public var description: String { "FrameioAPIError(redacted)" }

    /// Invalid external identifiers must not be reflected into diagnostics.
    public var debugDescription: String { description }
}

/// Portable Frame.io V4 endpoint and JSON-body builder.
///
/// This type deliberately does not send network traffic or attach OAuth
/// credentials. iOS and Android own those platform concerns, while every
/// endpoint path, resource identifier check, and Codable request body stays
/// in one testable shared implementation.
public enum FrameioAPI {
    /// The production Frame.io V4 base URL. API request planning deliberately
    /// needs no OAuth client identity; shells gate actual sending on their
    /// separately validated OAuth configuration.
    public static let defaultBaseURL = FrameioConfiguration.frameioAPIBaseURL

    /// Plans `GET /me`.
    public static func currentUser(config: FrameioConfiguration) throws -> FrameioAPIRequest {
        try currentUser(apiBaseURL: config.apiBaseURL)
    }

    /// Plans `GET /me` for the supplied V4 base URL.
    public static func currentUser(apiBaseURL: URL = defaultBaseURL) throws -> FrameioAPIRequest {
        FrameioAPIRequest(url: endpoint(apiBaseURL, ["me"]), method: .get)
    }

    /// Plans `GET /accounts`.
    public static func accounts(config: FrameioConfiguration) throws -> FrameioAPIRequest {
        try accounts(apiBaseURL: config.apiBaseURL)
    }

    /// Plans `GET /accounts` for the supplied V4 base URL.
    public static func accounts(apiBaseURL: URL = defaultBaseURL) throws -> FrameioAPIRequest {
        FrameioAPIRequest(url: endpoint(apiBaseURL, ["accounts"]), method: .get)
    }

    /// Plans `GET /accounts/{account}/workspaces`.
    public static func workspaces(config: FrameioConfiguration, accountID: String) throws
        -> FrameioAPIRequest
    {
        try workspaces(apiBaseURL: config.apiBaseURL, accountID: accountID)
    }

    /// Plans `GET /accounts/{account}/workspaces` for the supplied V4 base URL.
    public static func workspaces(apiBaseURL: URL = defaultBaseURL, accountID: String) throws
        -> FrameioAPIRequest
    {
        FrameioAPIRequest(
            url: endpoint(apiBaseURL, ["accounts", try identifier(accountID), "workspaces"]),
            method: .get)
    }

    /// Plans `GET /accounts/{account}/workspaces/{workspace}/projects`.
    public static func projects(
        config: FrameioConfiguration, accountID: String, workspaceID: String
    ) throws -> FrameioAPIRequest {
        try projects(
            apiBaseURL: config.apiBaseURL, accountID: accountID, workspaceID: workspaceID)
    }

    /// Plans `GET /accounts/{account}/workspaces/{workspace}/projects` for the supplied V4 base URL.
    public static func projects(
        apiBaseURL: URL = defaultBaseURL, accountID: String, workspaceID: String
    ) throws -> FrameioAPIRequest {
        FrameioAPIRequest(
            url: endpoint(
                apiBaseURL,
                [
                    "accounts", try identifier(accountID), "workspaces",
                    try identifier(workspaceID),
                    "projects",
                ]),
            method: .get)
    }

    /// Plans `POST /accounts/{account}/workspaces/{workspace}/projects`.
    public static func createProject(
        config: FrameioConfiguration, accountID: String, workspaceID: String, name: String
    ) throws -> FrameioAPIRequest {
        try createProject(
            apiBaseURL: config.apiBaseURL, accountID: accountID, workspaceID: workspaceID,
            name: name)
    }

    /// Plans `POST /accounts/{account}/workspaces/{workspace}/projects` for the supplied V4 base URL.
    public static func createProject(
        apiBaseURL: URL = defaultBaseURL, accountID: String, workspaceID: String, name: String
    ) throws -> FrameioAPIRequest {
        let projectName = try validatedProjectName(name)
        return FrameioAPIRequest(
            url: endpoint(
                apiBaseURL,
                [
                    "accounts", try identifier(accountID), "workspaces",
                    try identifier(workspaceID),
                    "projects",
                ]),
            method: .post,
            body: try JSONEncoder().encode(FrameioCreateProjectRequest(name: projectName)))
    }

    /// Plans `POST /accounts/{account}/folders/{folder}/files/local_upload`.
    public static func createFile(
        config: FrameioConfiguration, accountID: String, folderID: String, name: String,
        fileSize: Int
    ) throws -> FrameioAPIRequest {
        try createFile(
            apiBaseURL: config.apiBaseURL, accountID: accountID, folderID: folderID, name: name,
            fileSize: fileSize)
    }

    /// Plans a local-upload file request for the supplied V4 base URL.
    public static func createFile(
        apiBaseURL: URL = defaultBaseURL, accountID: String, folderID: String, name: String,
        fileSize: Int
    ) throws -> FrameioAPIRequest {
        let filename = try validatedFilename(name)
        guard fileSize > 0 else { throw FrameioAPIError.invalidFileSize }
        return FrameioAPIRequest(
            url: endpoint(
                apiBaseURL,
                [
                    "accounts", try identifier(accountID), "folders", try identifier(folderID),
                    "files",
                    "local_upload",
                ]),
            method: .post,
            body: try JSONEncoder().encode(
                FrameioCreateFileRequest(name: filename, fileSize: fileSize)))
    }

    /// Plans `GET /accounts/{account}/files/{file}/status`.
    public static func uploadStatus(
        config: FrameioConfiguration, accountID: String, fileID: String
    ) throws -> FrameioAPIRequest {
        try uploadStatus(apiBaseURL: config.apiBaseURL, accountID: accountID, fileID: fileID)
    }

    /// Plans `GET /accounts/{account}/files/{file}/status` for the supplied V4 base URL.
    public static func uploadStatus(
        apiBaseURL: URL = defaultBaseURL, accountID: String, fileID: String
    ) throws -> FrameioAPIRequest {
        FrameioAPIRequest(
            url: endpoint(
                apiBaseURL,
                ["accounts", try identifier(accountID), "files", try identifier(fileID), "status"]),
            method: .get)
    }

    private static func endpoint(_ baseURL: URL, _ components: [String]) -> URL {
        components.reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private static func identifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed == value,
            !value.contains("/"),
            !value.contains("\\"),
            !value.contains("?"),
            !value.contains("#"),
            !containsControlCharacter(value)
        else {
            throw FrameioAPIError.invalidIdentifier(value)
        }
        return value
    }

    private static func validatedProjectName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !containsControlCharacter(trimmed) else {
            throw FrameioAPIError.invalidProjectName
        }
        return trimmed
    }

    private static func validatedFilename(_ value: String) throws -> String {
        guard
            !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.contains("/"),
            !value.contains("\\"),
            !containsControlCharacter(value)
        else {
            throw FrameioAPIError.invalidFilename
        }
        return value
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}
