import Foundation
import Testing

@testable import OpenZCineCore

private let config = FrameioConfiguration(
    clientID: "test-client-id",
    redirectURI: "adobe+abc123://adobeid/test-client-id")

@Test func pkceChallengeMatchesRFC7636Vector() {
    // RFC 7636 Appendix B test vector for S256.
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func generatedVerifierIsValidLengthAndCharset() {
    let pkce = PKCE.generate()
    #expect(pkce.verifier.count >= 43 && pkce.verifier.count <= 128)
    // base64url alphabet only — no '+', '/', or '=' padding.
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
    #expect(pkce.challenge == PKCE.challenge(for: pkce.verifier))
}

@Test func authorizeURLCarriesPKCEAndOAuthParams() throws {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let url = FrameioOAuth.authorizeURL(config: config, pkce: pkce, state: "xyz")
    let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
        uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(comps.host == "ims-na1.adobelogin.com")
    #expect(comps.path == "/ims/authorize/v2")
    #expect(items["client_id"] == "test-client-id")
    #expect(items["redirect_uri"] == "adobe+abc123://adobeid/test-client-id")
    #expect(items["response_type"] == "code")
    #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == "xyz")
    #expect(items["scope"]?.isEmpty == false)
}

@Test func tokenExchangeRequestIsFormPost() throws {
    let req = FrameioOAuth.tokenExchangeRequest(config: config, code: "auth-code", verifier: "v123")
    #expect(req.httpMethod == "POST")
    #expect(
        req.url?.absoluteString
            == "https://ims-na1.adobelogin.com/ims/token/v3?client_id=test-client-id")
    #expect(
        req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code=auth-code"))
    #expect(body.contains("code_verifier=v123"))
    #expect(body.contains("client_id=test-client-id"))
}

@Test func refreshRequestUsesRefreshGrant() throws {
    let req = FrameioOAuth.refreshRequest(config: config, refreshToken: "r456")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=refresh_token"))
    #expect(body.contains("refresh_token=r456"))
    #expect(body.contains("client_id=test-client-id"))
}

@Test func urlSchemeExtractsAdobeNativeAppRedirect() {
    let uri = "adobe+abc123://adobeid/727e9081b73a46b286d6f491ed0ff602"
    #expect(FrameioOAuth.urlScheme(from: uri) == "adobe+abc123")
}

@Test func parseRedirectExtractsCodeAndValidatesState() throws {
    let url = URL(string: "adobe+abc123://adobeid/test-client-id?code=abc123&state=xyz")!
    let code = try FrameioOAuth.parseRedirect(url, expectedState: "xyz")
    #expect(code == "abc123")
}

@Test func parseRedirectRejectsStateMismatchAndErrors() {
    let mismatch = URL(string: "adobe+abc123://adobeid/test-client-id?code=abc&state=nope")!
    #expect(throws: FrameioOAuthError.stateMismatch) {
        try FrameioOAuth.parseRedirect(mismatch, expectedState: "xyz")
    }
    let denied = URL(string: "adobe+abc123://adobeid/test-client-id?error=access_denied")!
    #expect(throws: (any Error).self) {
        try FrameioOAuth.parseRedirect(denied, expectedState: "xyz")
    }
}

@Test func tokenDecodesFromIMSResponse() throws {
    let json = """
        { "access_token": "AT", "refresh_token": "RT", "expires_in": 3600, "token_type": "bearer" }
        """
    let token = try JSONDecoder().decode(FrameioToken.self, from: Data(json.utf8))
    #expect(token.accessToken == "AT")
    #expect(token.refreshToken == "RT")
    #expect(token.expiresIn == 3600)
}
