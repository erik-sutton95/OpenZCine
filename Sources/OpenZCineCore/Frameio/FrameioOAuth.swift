import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    // Non-Darwin platforms (e.g. Android): swift-crypto provides an API-compatible SHA256.
    import Crypto
#endif

/// Configuration for the Frame.io V4 OAuth + API integration.
///
/// This is an **external-service module** (not camera protocol); it lives in the portable core so the
/// OAuth/PKCE logic stays UI-free and unit-testable. The `clientID` and `redirectURI` come from the
/// app's Info.plist — register an OAuth **Native App** credential in the **Adobe Developer Console**
/// (with the Frame.io API added to the project). Adobe assigns a unique custom-scheme redirect URI
/// per credential; copy it verbatim into `Frameio.local.xcconfig`. Auth endpoints default to Adobe
/// IMS and the API to Frame.io V4; all are overridable for tests.
public struct FrameioConfiguration: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: String
    public var scope: String
    public var authorizeEndpoint: URL
    public var tokenEndpoint: URL
    public var apiBaseURL: URL

    /// Adobe IMS scopes for Frame.io V4 user authentication (PKCE). `offline_access` is required for
    /// a refresh token. Legacy Frame.io portal scopes (`account.read`, etc.) do not work with V4.
    public static let defaultScope = "openid email profile offline_access additional_info.roles"

    // SAFETY: these are compile-time-constant valid absolute URLs.
    public static let frameioAuthorizeEndpoint = URL(
        string: "https://ims-na1.adobelogin.com/ims/authorize/v2")!
    public static let frameioTokenEndpoint = URL(
        string: "https://ims-na1.adobelogin.com/ims/token/v3")!
    public static let frameioAPIBaseURL = URL(string: "https://api.frame.io/v4")!

    public init(
        clientID: String,
        redirectURI: String,
        scope: String = FrameioConfiguration.defaultScope,
        authorizeEndpoint: URL = FrameioConfiguration.frameioAuthorizeEndpoint,
        tokenEndpoint: URL = FrameioConfiguration.frameioTokenEndpoint,
        apiBaseURL: URL = FrameioConfiguration.frameioAPIBaseURL
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.authorizeEndpoint = authorizeEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.apiBaseURL = apiBaseURL
    }
}

/// A PKCE (RFC 7636) verifier/challenge pair for the OAuth authorization-code flow.
public struct PKCE: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let verifier: String
    /// The S256 code challenge: `base64url(SHA256(verifier))`.
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// Generates a fresh pair with a 43-char base64url verifier (32 random bytes).
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return PKCE(verifier: base64URL(Data(bytes)))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url (RFC 4648 §5) without padding.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Avoids exposing the one-time verifier in diagnostics.
    public var description: String { "PKCE(redacted)" }

    /// Avoids exposing the one-time verifier in debugger/reflection output.
    public var debugDescription: String { description }
}

/// Errors from OAuth redirect handling.
public enum FrameioOAuthError: LocalizedError, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case stateMismatch
    case authorizationDenied(String)
    case missingCode

    public var errorDescription: String? {
        switch self {
        case .stateMismatch:
            "The Frame.io sign-in response didn't match this request (possible tampering)."
        case .authorizationDenied:
            "Frame.io sign-in was denied. Check the Adobe account and try again."
        case .missingCode:
            "The Frame.io sign-in response was missing an authorization code."
        }
    }

    /// OAuth error descriptions can originate in a redirect query; keep them out of diagnostics.
    public var description: String { "FrameioOAuthError(redacted)" }

    /// OAuth error descriptions can originate in a redirect query; keep them out of diagnostics.
    public var debugDescription: String { description }
}

/// A platform-neutral form POST assembled by the shared OAuth policy.
///
/// Platform shells own the actual HTTP client: iOS turns this into a
/// `URLRequest`, while Android forwards the exact URL and form body through
/// its HTTPS adapter. Keeping the grant fields and RFC 3986 escaping here
/// prevents the two shells from drifting on PKCE or refresh semantics.
public struct FrameioFormRequest: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// Adobe IMS token endpoint, including the public client-id query item.
    public let url: URL
    /// UTF-8 `application/x-www-form-urlencoded` body.
    public let formBody: String

    public init(url: URL, formBody: String) {
        self.url = url
        self.formBody = formBody
    }

    /// Form bodies can contain an authorization code or refresh token.
    public var description: String { "FrameioFormRequest(redacted)" }

    /// Form bodies can contain an authorization code or refresh token.
    public var debugDescription: String { description }
}

/// Pure builders for the Adobe IMS OAuth 2.0 (PKCE) authorization-code flow used by Frame.io V4.
public enum FrameioOAuth {
    /// The URL scheme to register in `Info.plist` (`CFBundleURLSchemes`) for a custom-scheme redirect.
    /// For Adobe Native App credentials this is typically `adobe+{unique}` — everything before `://`.
    public static func urlScheme(from redirectURI: String) -> String? {
        URL(string: redirectURI)?.scheme
    }

    /// The IMS authorize URL to present in `ASWebAuthenticationSession`.
    public static func authorizeURL(config: FrameioConfiguration, pkce: PKCE, state: String) -> URL
    {
        // SAFETY: config.authorizeEndpoint is a valid absolute URL, so components/url cannot be nil.
        var comps = URLComponents(url: config.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Token endpoint URL for a public (PKCE) client — Adobe expects `client_id` as a query param.
    static func publicClientTokenURL(config: FrameioConfiguration) -> URL {
        var comps = URLComponents(url: config.tokenEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "client_id", value: config.clientID)]
        return comps.url!
    }

    /// The token-exchange POST fields for a public PKCE client.
    ///
    /// This remains available on Android even though the platform-native
    /// `URLRequest` builder below is Darwin-only.
    public static func tokenExchangeForm(
        config: FrameioConfiguration, code: String, verifier: String
    ) -> FrameioFormRequest {
        FrameioFormRequest(
            url: publicClientTokenURL(config: config),
            formBody: formEncoded([
                ("grant_type", "authorization_code"),
                ("client_id", config.clientID),
                ("code", code),
                ("code_verifier", verifier),
                ("redirect_uri", config.redirectURI),
            ]))
    }

    /// The refresh-token POST fields for a public Adobe IMS client.
    public static func refreshForm(
        config: FrameioConfiguration, refreshToken: String
    ) -> FrameioFormRequest {
        FrameioFormRequest(
            url: publicClientTokenURL(config: config),
            formBody: formEncoded([
                ("grant_type", "refresh_token"),
                ("client_id", config.clientID),
                ("refresh_token", refreshToken),
            ]))
    }

    /// Extracts the authorization `code` from the IMS redirect, validating `state` and surfacing
    /// `error` responses.
    public static func parseRedirect(_ url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw FrameioOAuthError.authorizationDenied(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw FrameioOAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw FrameioOAuthError.missingCode }
        return code
    }

    // On Android `URLRequest` lives in FoundationNetworking, which drags libcurl/ICU into the
    // packaged app; the Android shell owns HTTP and builds its own requests, so the
    // URLRequest builders are Darwin-only. The pure pieces above compile everywhere.
    #if !os(Android)
        /// The token-exchange POST that trades the authorization `code` (+ PKCE verifier) for tokens.
        public static func tokenExchangeRequest(
            config: FrameioConfiguration, code: String, verifier: String
        ) -> URLRequest {
            urlRequest(tokenExchangeForm(config: config, code: code, verifier: verifier))
        }

        /// The refresh POST that trades a refresh token for a new access token.
        public static func refreshRequest(config: FrameioConfiguration, refreshToken: String)
            -> URLRequest
        {
            urlRequest(refreshForm(config: config, refreshToken: refreshToken))
        }

        /// Turns the platform-neutral form shape into iOS's native request.
        private static func urlRequest(_ form: FrameioFormRequest) -> URLRequest {
            var request = URLRequest(url: form.url)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.formBody.utf8)
            return request
        }
    #endif

    /// Builds an `application/x-www-form-urlencoded` body with RFC 3986
    /// unreserved-set escaping, so `:`, `/`, and `+` in OAuth values are
    /// never treated as delimiters by Adobe IMS.
    private static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}

/// A decoded OAuth token response from Adobe IMS. The absolute expiry is computed by the shell when
/// the token is stored (the core stays free of wall-clock reads).
public struct FrameioToken: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int
    public let tokenType: String

    public init(accessToken: String, refreshToken: String?, expiresIn: Int, tokenType: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }

    /// Avoids exposing bearer material in diagnostics.
    public var description: String { "FrameioToken(redacted)" }

    /// Avoids exposing bearer material in debugger/reflection output.
    public var debugDescription: String { description }
}
