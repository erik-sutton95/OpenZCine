package com.opencapture.openzcine.frameio

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Host-side tests for fail-closed Android Frame.io configuration and storage policy. */
class FrameioStateTest {
    @Test
    fun `build configuration rejects absent malformed and fallback redirects`() {
        assertNull(
            FrameioBuildConfiguration.from(
                clientID = "",
                redirectURI = "openzcine://oauth/callback",
                registeredScheme = "openzcine",
            ),
        )
        assertNull(
            FrameioBuildConfiguration.from(
                clientID = "unit-client",
                redirectURI = "not a uri",
                registeredScheme = "openzcine",
            ),
        )
        assertNull(
            FrameioBuildConfiguration.from(
                clientID = "unit-client",
                redirectURI = "https://example.invalid/oauth/callback",
                registeredScheme = "https",
            ),
        )
        assertNull(
            FrameioBuildConfiguration.from(
                clientID = "unit-client",
                redirectURI = "openzcine-frameio-unconfigured://unconfigured",
                registeredScheme = "openzcine-frameio-unconfigured",
            ),
        )

        val configuration =
            FrameioBuildConfiguration.from(
                clientID = "unit-client",
                redirectURI = "openzcine-unit://oauth/callback",
                registeredScheme = "openzcine-unit",
            )

        assertNotNull(configuration)
        assertEquals("unit-client", configuration.clientID)
        assertEquals("openzcine-unit://oauth/callback", configuration.redirectURI)
    }

    @Test
    fun `secret codec round trips token and pending transaction without accepting malformed state`() {
        val source =
            FrameioSecretState(
                token = FrameioStoredToken("unit-access", "unit-refresh", 123_000L, "Bearer"),
                pendingAuthorization =
                    FrameioPendingAuthorization(
                        redirectURI = "openzcine-unit://oauth/callback",
                        state = "state-value",
                        verifier = "v".repeat(43),
                        createdAtEpochMillis = 100_000L,
                    ),
            )

        val decoded = FrameioSecretCodec.decode(FrameioSecretCodec.encode(source))

        assertNotNull(decoded)
        assertEquals("unit-access", decoded.token?.accessToken)
        assertEquals("unit-refresh", decoded.token?.refreshToken)
        assertEquals("state-value", decoded.pendingAuthorization?.state)
        assertEquals("FrameioSecretState(redacted)", decoded.toString())
        assertNull(FrameioSecretCodec.decode("{\"token\":{\"access_token\":\"x\"}}"))
        assertNull(FrameioSecretCodec.decode("not json"))
    }

    @Test
    fun `oauth and presigned values redact diagnostic descriptions`() {
        val accessToken = "unit-access-token"
        val refreshToken = "unit-refresh-token"
        val verifier = "v".repeat(43)
        val authorizationCode = "unit-code"
        val authorizationURL = "https://auth.example.invalid/authorize?state=unit-state"
        val uploadURL = "https://uploads.example.invalid/part?signature=unit-signature"
        val callbackURI = "openzcine-unit://oauth/callback?code=$authorizationCode&state=unit-state"
        val token = FrameioStoredToken(accessToken, refreshToken, 123_000L, "Bearer")
        val pending =
            FrameioPendingAuthorization(
                redirectURI = "openzcine-unit://oauth/callback",
                state = "unit-state",
                verifier = verifier,
                createdAtEpochMillis = 100_000L,
            )
        val descriptions =
            listOf(
                FrameioPublicConfiguration("unit-client", "openzcine-unit://oauth/callback").toString(),
                FrameioAuthorizationTransaction(authorizationURL, "unit-state", verifier, 100_000L).toString(),
                FrameioRedirectCallback(callbackURI).toString(),
                FrameioHttpRequest(authorizationURL, "POST", "code=$authorizationCode&code_verifier=$verifier").toString(),
                FrameioHttpResponse(200, "{\"access_token\":\"$accessToken\"}").toString(),
                FrameioAccessToken(accessToken, refreshToken, 3600, "Bearer").toString(),
                token.toString(),
                pending.toString(),
                FrameioSecretState(token, pending).toString(),
                FrameioUploadPart(4, uploadURL).toString(),
                FrameioUploadPlan("file", "video/quicktime", listOf(FrameioUploadPart(4, uploadURL))).toString(),
            )

        descriptions.forEach { description ->
            assertFalse(description.contains(accessToken))
            assertFalse(description.contains(refreshToken))
            assertFalse(description.contains(verifier))
            assertFalse(description.contains(authorizationCode))
            assertFalse(description.contains(authorizationURL))
            assertFalse(description.contains(callbackURI))
            assertFalse(description.contains(uploadURL))
        }
    }

    @Test
    fun `destination codec is non-secret but rejects incomplete records`() {
        val destination =
            FrameioDestination(
                accountID = "account",
                workspaceID = "workspace",
                projectID = "project",
                projectName = "Dailies",
                folderID = "folder",
            )

        val decoded = FrameioDestinationCodec.decode(FrameioDestinationCodec.encode(destination))

        assertEquals(destination, decoded)
        assertNull(FrameioDestinationCodec.decode("{\"account_id\":\"account\"}"))
    }

    @Test
    fun `reachability refuses to release camera access point binding`() {
        assertEquals(
            FrameioNetworkState.CAMERA_ACCESS_POINT,
            FrameioReachabilityPolicy.state(
                FrameioNetworkSnapshot(
                    processBound = true,
                    boundNetworkHasValidatedInternet = false,
                    activeNetworkHasValidatedInternet = true,
                ),
            ),
        )
        assertEquals(
            FrameioNetworkState.ONLINE,
            FrameioReachabilityPolicy.state(
                FrameioNetworkSnapshot(
                    processBound = false,
                    boundNetworkHasValidatedInternet = false,
                    activeNetworkHasValidatedInternet = true,
                ),
            ),
        )
        assertEquals(
            FrameioNetworkState.OFFLINE,
            FrameioReachabilityPolicy.state(
                FrameioNetworkSnapshot(
                    processBound = false,
                    boundNetworkHasValidatedInternet = false,
                    activeNetworkHasValidatedInternet = false,
                ),
            ),
        )
        assertTrue(FrameioReachabilityPolicy.operatorMessage(FrameioNetworkState.CAMERA_ACCESS_POINT).contains("will not interrupt"))
        assertFalse(FrameioReachabilityPolicy.operatorMessage(FrameioNetworkState.ONLINE).isNotEmpty())
    }

    @Test
    fun `network boundary accepts only absolute non-credentialed fragment-free HTTPS URLs`() {
        assertTrue("https://uploads.example.invalid/part?signature=value".isHTTPS())
        assertFalse("http://uploads.example.invalid/part".isHTTPS())
        assertFalse("https:opaque-upload".isHTTPS())
        assertFalse("https:///missing-host".isHTTPS())
        assertFalse("https://user@uploads.example.invalid/part".isHTTPS())
        assertFalse("https://uploads.example.invalid/part#fragment".isHTTPS())
    }

    @Test
    fun `upload media type is a single safe MIME token`() {
        assertTrue("video/quicktime".isSafeMediaType())
        assertTrue("application/octet-stream".isSafeMediaType())
        assertFalse("video/quicktime; charset=utf-8".isSafeMediaType())
        assertFalse("video/quicktime\r\nX-Injected: yes".isSafeMediaType())
    }

    @Test
    fun `oauth header values reject whitespace and control characters`() {
        assertTrue("eyJhbGciOiJIUzI1NiJ9.payload.signature".isSafeHeaderValue())
        assertFalse("bearer token".isSafeHeaderValue())
        assertFalse("bearer\r\nX-Injected: yes".isSafeHeaderValue())
    }
}
