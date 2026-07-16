package com.opencapture.openzcine.diagnostics

import android.content.Context
import android.os.Build
import com.opencapture.openzcine.BuildConfig
import java.io.IOException
import java.net.URI
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Production source for the closed Android context included in a submitted report. */
internal class AndroidBugReportContextProvider(private val context: Context) : BugReportContextProvider {
    override fun context(connection: BugReportConnection): BugReportContext =
        BugReportContext(
            appVersion = BuildConfig.VERSION_NAME.take(BugReportContext.MAXIMUM_APP_VERSION_LENGTH),
            buildNumber =
                BuildConfig.VERSION_CODE.toString().take(BugReportContext.MAXIMUM_BUILD_NUMBER_LENGTH),
            osVersion = androidOsVersion(),
            deviceClass = deviceClass(context),
            connection = connection,
        )

    private fun androidOsVersion(): String {
        val release = Build.VERSION.RELEASE.orEmpty().trim().take(96)
        return if (release.isEmpty()) {
            "Android API ${Build.VERSION.SDK_INT}"
        } else {
            "Android $release (API ${Build.VERSION.SDK_INT})"
        }.take(BugReportContext.MAXIMUM_OS_VERSION_LENGTH)
    }

    private fun deviceClass(context: Context): BugReportDeviceClass =
        when (val smallestWidth = context.resources.configuration.smallestScreenWidthDp) {
            in 600..Int.MAX_VALUE -> BugReportDeviceClass.TABLET
            in 1..<600 -> BugReportDeviceClass.PHONE
            else -> BugReportDeviceClass.UNKNOWN
        }
}

/**
 * HTTPS-only client for explicitly submitted anonymous reports. It owns no
 * GitHub credential and retains neither drafts nor requests after a send.
 */
internal class AndroidBugReportClient(
    private val endpoint: String = BuildConfig.BUG_REPORT_ENDPOINT,
    private val contextProvider: BugReportContextProvider,
    private val connectionFactory: (String) -> HttpsURLConnection = ::openBugReportConnection,
) : BugReportSubmitter {
    constructor(
        context: Context,
        endpoint: String = BuildConfig.BUG_REPORT_ENDPOINT,
        connectionFactory: (String) -> HttpsURLConnection = ::openBugReportConnection,
    ) : this(
        endpoint = endpoint,
        contextProvider = AndroidBugReportContextProvider(context.applicationContext),
        connectionFactory = connectionFactory,
    )

    override suspend fun submit(submission: BugReportSubmission): BugReportSubmissionResult {
        val draft = submission.draft
        val validation = draft.validation()
        if (!validation.isValid) return BugReportSubmissionResult.Invalid(validation)
        val context =
            runCatching { contextProvider.context(draft.connection) }
                .getOrElse {
                    return BugReportSubmissionResult.Failed(BugReportSubmissionFailure.CONFIGURATION)
                }
        if (!context.isValid() || !isValidBugReportEndpoint(endpoint)) {
            return BugReportSubmissionResult.Failed(BugReportSubmissionFailure.CONFIGURATION)
        }
        val payload = BugReportPayload.from(draft, context).utf8Bytes()
        if (payload.size > BugReportPayload.MAXIMUM_UTF8_BYTES) {
            return BugReportSubmissionResult.Invalid(
                validation.copy(payload = BugReportPayloadError.TOO_LARGE),
            )
        }
        if (runCatching { UUID.fromString(submission.idempotencyKey) }.isFailure) {
            return BugReportSubmissionResult.Failed(BugReportSubmissionFailure.CONFIGURATION)
        }

        return withContext(Dispatchers.IO) {
            currentCoroutineContext().ensureActive()
            val connection =
                try {
                    connectionFactory(endpoint)
                } catch (_: IOException) {
                    return@withContext BugReportSubmissionResult.Failed(
                        BugReportSubmissionFailure.NETWORK,
                    )
                } catch (_: IllegalArgumentException) {
                    return@withContext BugReportSubmissionResult.Failed(
                        BugReportSubmissionFailure.CONFIGURATION,
                    )
                } catch (_: SecurityException) {
                    return@withContext BugReportSubmissionResult.Failed(
                        BugReportSubmissionFailure.NETWORK,
                    )
            }
            try {
                withTimeout(REQUEST_TIMEOUT_MILLIS.toLong()) {
                    connection.disconnectOnCancellation {
                        connection.instanceFollowRedirects = false
                        connection.requestMethod = "POST"
                        connection.doOutput = true
                        connection.setRequestProperty("Accept", "application/json")
                        connection.setRequestProperty("Content-Type", "application/json")
                        connection.setRequestProperty("Idempotency-Key", submission.idempotencyKey)
                        connection.connectTimeout = REQUEST_TIMEOUT_MILLIS
                        connection.readTimeout = REQUEST_TIMEOUT_MILLIS
                        connection.setFixedLengthStreamingMode(payload.size)
                        connection.outputStream.use { output -> output.write(payload) }
                        currentCoroutineContext().ensureActive()
                        val statusCode = connection.responseCode
                        connection.readBoundedBody(statusCode)
                        when {
                            statusCode == HTTP_OK || statusCode == HTTP_CREATED ->
                                BugReportSubmissionResult.Submitted
                            statusCode == TOO_MANY_REQUESTS ->
                                BugReportSubmissionResult.Failed(
                                    reason = BugReportSubmissionFailure.RATE_LIMITED,
                                    retryAfterSeconds = connection.retryAfterSeconds(),
                                )
                            else ->
                                BugReportSubmissionResult.Failed(BugReportSubmissionFailure.SERVICE)
                        }
                    }
                }
            } catch (_: TimeoutCancellationException) {
                BugReportSubmissionResult.Failed(BugReportSubmissionFailure.NETWORK)
            } catch (_: IOException) {
                currentCoroutineContext().ensureActive()
                BugReportSubmissionResult.Failed(BugReportSubmissionFailure.NETWORK)
            } catch (_: SecurityException) {
                BugReportSubmissionResult.Failed(BugReportSubmissionFailure.NETWORK)
            } finally {
                connection.disconnect()
            }
        }
    }

    private fun HttpsURLConnection.readBoundedBody(statusCode: Int) {
        val stream = if (statusCode in 200..299) inputStream else errorStream
        stream?.use { input ->
            val buffer = ByteArray(RESPONSE_BUFFER_BYTES)
            var totalBytes = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) return
                totalBytes += count
                if (totalBytes > MAXIMUM_RESPONSE_BYTES) {
                    throw IOException("Bug-report response exceeded its safe bound.")
                }
            }
        }
    }

    private fun HttpsURLConnection.retryAfterSeconds(): Long? =
        getHeaderField("Retry-After")
            ?.trim()
            ?.toLongOrNull()
            ?.takeIf { it > 0 }
            ?.coerceAtMost(MAXIMUM_RETRY_AFTER_SECONDS)

    private companion object {
        const val REQUEST_TIMEOUT_MILLIS: Int = 12_000
        const val HTTP_OK: Int = 200
        const val HTTP_CREATED: Int = 201
        const val TOO_MANY_REQUESTS: Int = 429
        const val RESPONSE_BUFFER_BYTES: Int = 1_024
        const val MAXIMUM_RESPONSE_BYTES: Int = 8 * 1_024
        const val MAXIMUM_RETRY_AFTER_SECONDS: Long = 86_400
    }
}

/** The relay endpoint must be an absolute HTTPS URL without credentials, query, or fragments. */
internal fun isValidBugReportEndpoint(value: String): Boolean =
    runCatching {
        val uri = URI(value)
        uri.isAbsolute &&
            uri.scheme.equals("https", ignoreCase = true) &&
            !uri.host.isNullOrBlank() &&
            uri.path == "/v1/bug-reports" &&
            uri.userInfo == null &&
            uri.query == null &&
            uri.fragment == null
    }.getOrDefault(false)

private fun openBugReportConnection(value: String): HttpsURLConnection {
    require(isValidBugReportEndpoint(value)) {
        "Bug-report endpoint must be an absolute HTTPS URL without credentials, query, or fragments."
    }
    return (URI(value).toURL().openConnection() as? HttpsURLConnection)
        ?.apply {
            connectTimeout = 12_000
            readTimeout = 12_000
            instanceFollowRedirects = false
        }
        ?: throw IOException("Bug-report endpoint did not open an HTTPS connection.")
}

private suspend fun <T> HttpsURLConnection.disconnectOnCancellation(block: suspend () -> T): T =
    coroutineScope {
        val completedNormally = AtomicBoolean(false)
        val watcher =
            launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    if (!completedNormally.get()) this@disconnectOnCancellation.disconnect()
                }
            }
        try {
            block().also { completedNormally.set(true) }
        } finally {
            withContext(NonCancellable) { watcher.cancelAndJoin() }
        }
    }
