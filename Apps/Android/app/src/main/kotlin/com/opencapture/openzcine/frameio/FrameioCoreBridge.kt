package com.opencapture.openzcine.frameio

import com.opencapture.openzcine.BuildConfig
import com.opencapture.openzcine.bridge.SwiftCore
import java.net.URI
import org.json.JSONArray
import org.json.JSONObject

/**
 * Public PKCE client configuration injected only at build time.
 *
 * This intentionally carries no client secret: Adobe Native App OAuth uses
 * PKCE. A fresh clone has no configuration and must fail closed instead of
 * presenting a pretend sign-in flow.
 */
internal data class FrameioPublicConfiguration(
    val clientID: String,
    val redirectURI: String,
) {
    override fun toString(): String = "FrameioPublicConfiguration(redacted)"
}

/** Reads and validates the deliberately optional Android Frame.io configuration. */
internal object FrameioBuildConfiguration {
    private const val UNCONFIGURED_SCHEME = "openzcine-frameio-unconfigured"

    fun current(): FrameioPublicConfiguration? =
        from(
            clientID = BuildConfig.FRAMEIO_CLIENT_ID,
            redirectURI = BuildConfig.FRAMEIO_REDIRECT_URI,
            registeredScheme = BuildConfig.FRAMEIO_REDIRECT_SCHEME,
        )

    /** Pure parsing seam for tests and non-Android callers. */
    fun from(
        clientID: String,
        redirectURI: String,
        registeredScheme: String,
    ): FrameioPublicConfiguration? {
        if (clientID.isBlank() || clientID != clientID.trim()) return null
        if (redirectURI.isBlank() || redirectURI != redirectURI.trim()) return null
        if (registeredScheme == UNCONFIGURED_SCHEME) return null
        val redirect = runCatching { URI(redirectURI) }.getOrNull() ?: return null
        if (redirect.scheme.isNullOrBlank() || redirect.host.isNullOrBlank()) return null
        if (
            redirect.scheme.equals("http", ignoreCase = true) ||
                redirect.scheme.equals("https", ignoreCase = true) ||
                redirect.rawQuery != null ||
                redirect.rawFragment != null ||
                redirect.userInfo != null
        ) {
            return null
        }
        if (!redirect.scheme.equals(registeredScheme, ignoreCase = true)) return null
        return FrameioPublicConfiguration(clientID, redirectURI)
    }
}

/** A shared-core PKCE request the Android shell may persist only encrypted. */
internal class FrameioAuthorizationTransaction(
    val authorizationURL: String,
    val state: String,
    val verifier: String,
    val createdAtEpochMillis: Long,
) {
    override fun toString(): String = "FrameioAuthorizationTransaction(redacted)"
}

/**
 * A callback held only while Compose hands it to the shared-core verifier.
 *
 * The URI can include an OAuth authorization code, so diagnostics redact it
 * even though the activity clears the originating intent immediately.
 */
internal class FrameioRedirectCallback(val uri: String) {
    override fun toString(): String = "FrameioRedirectCallback(redacted)"
}

/** One HTTPS request planned by the shared Swift Frame.io policy. */
internal class FrameioHttpRequest(
    val url: String,
    val method: String,
    val body: String?,
) {
    override fun toString(): String = "FrameioHttpRequest(method=$method, body=redacted)"
}

/** Decoded Adobe access-token response, redacted from diagnostic text by default. */
internal class FrameioAccessToken(
    val accessToken: String,
    val refreshToken: String?,
    val expiresInSeconds: Long,
    val tokenType: String,
) {
    override fun toString(): String = "FrameioAccessToken(redacted)"
}

/** A project eligible for upload because Frame.io reported a root folder. */
internal data class FrameioProject(
    val id: String,
    val name: String,
    val rootFolderID: String?,
)

/** The account/workspace context needed to persist a selected project destination. */
internal data class FrameioProjectListing(
    val accountID: String,
    val workspaceID: String,
    val workspaceName: String,
    val projects: List<FrameioProject>,
)

/** One Frame.io-issued pre-signed upload part. */
internal class FrameioUploadPart(val sizeBytes: Long, val url: String) {
    // Pre-signed URLs contain a short-lived authorization signature.
    override fun toString(): String = "FrameioUploadPart(redacted)"
}

/** Shared-model decoded create-file response used by the Android I/O adapter. */
internal class FrameioUploadPlan(
    val fileID: String,
    val mediaType: String?,
    val parts: List<FrameioUploadPart>,
) {
    override fun toString(): String = "FrameioUploadPlan(redacted)"
}

/** Kotlin names for the stable Android-to-Swift Frame.io wire operations. */
internal object FrameioCoreOperation {
    const val ACCOUNTS = "accounts"
    const val WORKSPACES = "workspaces"
    const val PROJECTS = "projects"
    const val CREATE_PROJECT = "create_project"
    const val CREATE_FILE = "create_file"
    const val UPLOAD_STATUS = "upload_status"
    const val TOKEN = "token"
}

/**
 * Small interface around the Swift bridge so Android session and delivery
 * policy can be unit-tested without a native runtime.
 */
internal interface FrameioCoreBridge {
    fun beginAuthorization(config: FrameioPublicConfiguration, nowEpochMillis: Long): FrameioAuthorizationTransaction?

    fun parseRedirect(
        config: FrameioPublicConfiguration,
        callbackURI: String,
        expectedState: String,
    ): String?

    fun tokenRequest(
        kind: String,
        config: FrameioPublicConfiguration,
        code: String? = null,
        verifier: String? = null,
        refreshToken: String? = null,
    ): FrameioHttpRequest?

    fun apiRequest(
        operation: String,
        accountID: String? = null,
        workspaceID: String? = null,
        folderID: String? = null,
        fileID: String? = null,
        name: String? = null,
        fileSize: Long = 0,
    ): FrameioHttpRequest?

    fun decodeToken(response: String): FrameioAccessToken?

    fun decodeProjects(response: String): List<FrameioProject>?

    fun decodeProject(response: String): FrameioProject?

    fun decodeAccounts(response: String): List<FrameioAccount>?

    fun decodeWorkspaces(response: String): List<FrameioWorkspace>?

    fun decodeUploadPlan(response: String): FrameioUploadPlan?

    fun decodeUploadComplete(response: String): Boolean?

    fun mediaTypeFor(filename: String): String?
}

/** Lightweight presentation records decoded only after Swift validates the V4 payload. */
internal data class FrameioAccount(val id: String, val displayName: String?)

/** Lightweight presentation record decoded only after Swift validates the V4 payload. */
internal data class FrameioWorkspace(val id: String, val name: String)

/** Production bridge: every OAuth/API policy call crosses to Swift first. */
internal object SwiftFrameioCoreBridge : FrameioCoreBridge {
    override fun beginAuthorization(
        config: FrameioPublicConfiguration,
        nowEpochMillis: Long,
    ): FrameioAuthorizationTransaction? {
        if (!SwiftCore.isAvailable) return null
        val wire = SwiftCore.frameioBeginAuthorization(config.clientID, config.redirectURI) ?: return null
        val value = runCatching { JSONObject(wire) }.getOrNull() ?: return null
        val authorizationURL = value.optRequiredString("authorizationURL") ?: return null
        val state = value.optRequiredString("state") ?: return null
        val verifier = value.optRequiredString("verifier") ?: return null
        if (!authorizationURL.isHTTPS() || verifier.length !in 43..128) return null
        return FrameioAuthorizationTransaction(authorizationURL, state, verifier, nowEpochMillis)
    }

    override fun parseRedirect(
        config: FrameioPublicConfiguration,
        callbackURI: String,
        expectedState: String,
    ): String? =
        if (SwiftCore.isAvailable) {
            SwiftCore.frameioParseRedirect(config.redirectURI, callbackURI, expectedState)
        } else {
            null
        }

    override fun tokenRequest(
        kind: String,
        config: FrameioPublicConfiguration,
        code: String?,
        verifier: String?,
        refreshToken: String?,
    ): FrameioHttpRequest? =
        if (SwiftCore.isAvailable) {
            SwiftCore.frameioTokenRequest(
                kind,
                config.clientID,
                config.redirectURI,
                code,
                verifier,
                refreshToken,
            )?.let(::parseRequest)
        } else {
            null
        }

    override fun apiRequest(
        operation: String,
        accountID: String?,
        workspaceID: String?,
        folderID: String?,
        fileID: String?,
        name: String?,
        fileSize: Long,
    ): FrameioHttpRequest? =
        if (SwiftCore.isAvailable) {
            SwiftCore.frameioAPIRequest(
                operation,
                accountID,
                workspaceID,
                folderID,
                fileID,
                name,
                fileSize,
            )?.let(::parseRequest)
        } else {
            null
        }

    override fun decodeToken(response: String): FrameioAccessToken? {
        val value = decodedObject(FrameioCoreOperation.TOKEN, response) ?: return null
        val accessToken = value.optRequiredString("access_token") ?: return null
        if (!accessToken.isSafeHeaderValue()) return null
        val refreshToken = value.optNullableString("refresh_token")
        if (refreshToken != null && !refreshToken.isSafeHeaderValue()) return null
        val expiresIn = value.optLong("expires_in", -1)
        val tokenType = value.optRequiredString("token_type") ?: return null
        if (expiresIn <= 0 || !tokenType.equals("bearer", ignoreCase = true)) return null
        return FrameioAccessToken(
            accessToken = accessToken,
            refreshToken = refreshToken,
            expiresInSeconds = expiresIn,
            tokenType = tokenType,
        )
    }

    override fun decodeProjects(response: String): List<FrameioProject>? {
        val values = decodedDataArray(FrameioCoreOperation.PROJECTS, response) ?: return null
        val projects = mutableListOf<FrameioProject>()
        for (value in values) {
            projects += projectFromJson(value) ?: return null
        }
        return projects
    }

    override fun decodeProject(response: String): FrameioProject? =
        decodedObject(FrameioCoreOperation.CREATE_PROJECT, response)
            ?.optJSONObject("data")
            ?.let(::projectFromJson)

    override fun decodeAccounts(response: String): List<FrameioAccount>? {
        val values = decodedDataArray(FrameioCoreOperation.ACCOUNTS, response) ?: return null
        val accounts = mutableListOf<FrameioAccount>()
        for (value in values) {
            val id = value.optRequiredString("id") ?: return null
            accounts += FrameioAccount(id, value.optNullableString("display_name"))
        }
        return accounts
    }

    override fun decodeWorkspaces(response: String): List<FrameioWorkspace>? {
        val values = decodedDataArray(FrameioCoreOperation.WORKSPACES, response) ?: return null
        val workspaces = mutableListOf<FrameioWorkspace>()
        for (value in values) {
            val id = value.optRequiredString("id") ?: return null
            val name = value.optRequiredString("name") ?: return null
            workspaces += FrameioWorkspace(id, name)
        }
        return workspaces
    }

    override fun decodeUploadPlan(response: String): FrameioUploadPlan? {
        val body = decodedObject(FrameioCoreOperation.CREATE_FILE, response)?.optJSONObject("data") ?: return null
        val fileID = body.optRequiredString("id") ?: return null
        val uploadURLs = body.optJSONArray("upload_urls") ?: return null
        if (uploadURLs.length() == 0) return null
        val parts = mutableListOf<FrameioUploadPart>()
        repeat(uploadURLs.length()) { index ->
            val value = uploadURLs.optJSONObject(index) ?: return null
            val size = value.optLong("size", -1)
            val url = value.optRequiredString("url") ?: return null
            if (size <= 0 || !url.isHTTPS()) return null
            parts += FrameioUploadPart(size, url)
        }
        val mediaType = body.optNullableString("media_type")
        if (mediaType != null && !mediaType.isSafeMediaType()) return null
        return FrameioUploadPlan(fileID, mediaType, parts)
    }

    override fun decodeUploadComplete(response: String): Boolean? =
        decodedObject(FrameioCoreOperation.UPLOAD_STATUS, response)
            ?.optJSONObject("data")
            ?.takeIf { value -> value.optRequiredString("id") != null }
            ?.takeIf { value -> value.has("upload_complete") }
            ?.optBoolean("upload_complete")

    override fun mediaTypeFor(filename: String): String? =
        if (SwiftCore.isAvailable) SwiftCore.frameioMediaTypeForFilename(filename) else null

    private fun parseRequest(wire: String): FrameioHttpRequest? {
        val value = runCatching { JSONObject(wire) }.getOrNull() ?: return null
        val url = value.optRequiredString("url") ?: return null
        val method = value.optRequiredString("method") ?: return null
        if (!url.isHTTPS() || method !in setOf("GET", "POST")) return null
        return FrameioHttpRequest(url, method, value.optNullableString("body"))
    }

    private fun decodedObject(operation: String, response: String): JSONObject? {
        if (!SwiftCore.isAvailable) return null
        val canonical = SwiftCore.frameioDecodeResponse(operation, response) ?: return null
        return runCatching { JSONObject(canonical) }.getOrNull()
    }

    private fun decodedDataArray(operation: String, response: String): List<JSONObject>? =
        decodedObject(operation, response)?.optJSONArray("data")?.toObjects()

    private fun projectFromJson(value: JSONObject): FrameioProject? {
        val id = value.optRequiredString("id") ?: return null
        val name = value.optRequiredString("name") ?: return null
        return FrameioProject(id, name, value.optNullableString("root_folder_id"))
    }
}

private fun JSONObject.optRequiredString(name: String): String? =
    optString(name, "").takeIf { value -> value.isNotBlank() }

private fun JSONObject.optNullableString(name: String): String? =
    if (isNull(name)) null else optRequiredString(name)

private fun JSONArray.toObjects(): List<JSONObject>? {
    val objects = mutableListOf<JSONObject>()
    repeat(length()) { index ->
        objects += optJSONObject(index) ?: return null
    }
    return objects
}

/**
 * Accepts only an absolute, non-credentialed HTTPS endpoint.
 *
 * The shared Swift core plans Adobe and Frame.io API requests, while Frame.io
 * supplies pre-signed upload URLs. Both still cross this Android boundary, so
 * reject opaque `https:` values, host-less URLs, user-info, and fragments
 * before a bearer token or media stream can be sent.
 */
internal fun String.isHTTPS(): Boolean {
    val uri = runCatching { URI(this) }.getOrNull() ?: return false
    return uri.isAbsolute &&
        uri.scheme.equals("https", ignoreCase = true) &&
        !uri.host.isNullOrBlank() &&
        uri.rawUserInfo == null &&
        uri.rawFragment == null
}

/** Rejects media-type values that could turn a response field into a second HTTP header. */
internal fun String.isSafeMediaType(): Boolean = SAFE_MEDIA_TYPE.matches(this)

private val SAFE_MEDIA_TYPE = Regex("^[A-Za-z0-9._+-]+/[A-Za-z0-9._+-]+$")

/** OAuth bearer values never need whitespace or control characters in an HTTP header. */
internal fun String.isSafeHeaderValue(): Boolean =
    isNotBlank() && none { character -> character.code <= 0x20 || character.code == 0x7F }
