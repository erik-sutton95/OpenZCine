package com.opencapture.openzcine.diagnostics

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URL
import java.security.cert.Certificate
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class AndroidBugReportClientTest {
    @Test
    fun `201 sends the exact public JSON contract and caller idempotency key`() = runBlocking {
        val connection = FakeHttpsConnection(statusCode = 201)
        val client = client { connection }
        val submission = sampleSubmission()

        assertEquals(BugReportSubmissionResult.Submitted, client.submit(submission))
        assertEquals("POST", connection.requestMethod)
        assertEquals("application/json", connection.header("Content-Type"))
        assertEquals("application/json", connection.header("Accept"))
        assertEquals(submission.idempotencyKey, connection.header("Idempotency-Key"))
        assertFalse(connection.instanceFollowRedirects)

        assertEquals(
            "{\"schemaVersion\":1,\"summary\":\"Preview freezes\"," +
                "\"whatHappened\":\"The preview stops after reconnecting.\"," +
                "\"stepsToReproduce\":\"Reconnect, then open Live View.\"," +
                "\"frequency\":\"sometimes\",\"context\":{" +
                "\"platform\":\"android\",\"appVersion\":\"0.1.117\"," +
                "\"buildNumber\":\"117\",\"osVersion\":\"Android 16 (API 36)\"," +
                "\"deviceClass\":\"phone\",\"connection\":\"wifi\"}}",
            connection.requestBody(),
        )
        assertFalse(connection.requestBody().contains("serial", ignoreCase = true))
        assertFalse(connection.requestBody().contains("ssid", ignoreCase = true))
    }

    @Test
    fun `v2 multipart uses only generated screenshot names and preserves an unchanged key`() = runBlocking {
        val first = FakeHttpsConnection(statusCode = 429, headers = mapOf("Retry-After" to "30"))
        val second = FakeHttpsConnection(statusCode = 201)
        val connections = ArrayDeque(listOf(first, second))
        val requestedEndpoints = mutableListOf<String>()
        val client =
            client { requestedEndpoint ->
                requestedEndpoints += requestedEndpoint
                connections.removeFirst()
            }
        val screenshot = requireNotNull(BugReportScreenshot.fromSanitizedPng(tinyPng()))
        val submission =
            sampleSubmission().copy(
                includeActivityLog = true,
                activityLog = listOf("app.launched", "live-view.started"),
                screenshots = listOf(screenshot),
            )

        assertEquals(
            BugReportSubmissionResult.Failed(
                reason = BugReportSubmissionFailure.RATE_LIMITED,
                retryAfterSeconds = 30,
            ),
            client.submit(submission),
        )
        assertEquals(BugReportSubmissionResult.Submitted, client.submit(submission))

        assertEquals(
            listOf(
                "https://reports.openzcine.app/v2/bug-reports",
                "https://reports.openzcine.app/v2/bug-reports",
            ),
            requestedEndpoints,
        )
        assertTrue(first.header("Content-Type").orEmpty().startsWith("multipart/form-data; boundary="))
        assertEquals(submission.idempotencyKey, first.header("Idempotency-Key"))
        assertEquals(submission.idempotencyKey, second.header("Idempotency-Key"))
        val body = first.requestBody()
        assertTrue(body.contains("name=\"report\""))
        assertTrue(body.contains("\"schemaVersion\":2"))
        assertTrue(body.contains("\"activityLog\":[\"app.launched\",\"live-view.started\"]"))
        assertTrue(body.contains("name=\"screenshot\"; filename=\"screenshot-1.png\""))
        assertFalse(body.contains("original-screenshot", ignoreCase = true))
        assertFalse(body.contains("Bob's iPhone"))
    }

    @Test
    fun `untrusted activity text is rejected before a v2 connection opens`() = runBlocking {
        var factoryCalls = 0
        val client =
            client {
                factoryCalls += 1
                FakeHttpsConnection(statusCode = 201)
            }

        val result =
            client.submit(
                sampleSubmission().copy(
                    includeActivityLog = true,
                    activityLog = listOf("Bob's iPhone"),
                ),
            )

        val invalid = assertIs<BugReportSubmissionResult.Invalid>(result)
        assertEquals(BugReportPayloadError.INVALID_ATTACHMENTS, invalid.validation.payload)
        assertEquals(0, factoryCalls)
    }

    @Test
    fun `200 and 201 are the only successful relay response contracts`() = runBlocking {
        listOf(200, 201).forEach { statusCode ->
            assertEquals(
                BugReportSubmissionResult.Submitted,
                client { FakeHttpsConnection(statusCode = statusCode) }.submit(sampleSubmission()),
            )
        }

        val accepted = client { FakeHttpsConnection(statusCode = 202) }.submit(sampleSubmission())
        assertEquals(
            BugReportSubmissionResult.Failed(BugReportSubmissionFailure.SERVICE),
            accepted,
        )
    }

    @Test
    fun `retry uses the unchanged caller key and rate limits respect Retry-After`() = runBlocking {
        val first = FakeHttpsConnection(statusCode = 429, headers = mapOf("Retry-After" to "120"))
        val second = FakeHttpsConnection(statusCode = 201)
        val connections = ArrayDeque(listOf(first, second))
        val client = client { connections.removeFirst() }
        val submission = sampleSubmission()

        assertEquals(
            BugReportSubmissionResult.Failed(
                reason = BugReportSubmissionFailure.RATE_LIMITED,
                retryAfterSeconds = 120,
            ),
            client.submit(submission),
        )
        assertEquals(BugReportSubmissionResult.Submitted, client.submit(submission))
        assertEquals(submission.idempotencyKey, first.header("Idempotency-Key"))
        assertEquals(submission.idempotencyKey, second.header("Idempotency-Key"))
    }

    @Test
    fun `invalid endpoint key and bounded failures never expose request data`() = runBlocking {
        var factoryCalls = 0
        val invalidEndpoint =
            AndroidBugReportClient(
                endpoint = "http://reports.openzcine.app/v1/bug-reports",
                contextProvider = BugReportContextProvider { sampleContext(it) },
                connectionFactory = {
                    factoryCalls += 1
                    FakeHttpsConnection(statusCode = 201)
                },
            )
        assertEquals(
            BugReportSubmissionResult.Failed(BugReportSubmissionFailure.CONFIGURATION),
            invalidEndpoint.submit(sampleSubmission()),
        )
        assertEquals(0, factoryCalls)

        val malformedKey = sampleSubmission().copy(idempotencyKey = "not-a-uuid")
        assertEquals(
            BugReportSubmissionResult.Failed(BugReportSubmissionFailure.CONFIGURATION),
            client { FakeHttpsConnection(statusCode = 201) }.submit(malformedKey),
        )

        val privateValue = "ssid=private-network"
        val networkFailure =
            client { FakeHttpsConnection(responseFailure = IOException(privateValue)) }
                .submit(sampleSubmission())
        val failure = assertIs<BugReportSubmissionResult.Failed>(networkFailure)
        assertEquals(BugReportSubmissionFailure.NETWORK, failure.reason)
        assertFalse(failure.toString().contains(privateValue))

        val oversizedBody =
            client { FakeHttpsConnection(statusCode = 201, body = ByteArray(8 * 1_024 + 1)) }
                .submit(sampleSubmission())
        assertEquals(
            BugReportSubmissionResult.Failed(BugReportSubmissionFailure.NETWORK),
            oversizedBody,
        )
    }

    @Test
    fun `aggregate UTF-8 payloads over twelve KiB are rejected before opening a connection`() = runBlocking {
        var factoryCalls = 0
        val oversizedDraft =
            sampleSubmission().draft.copy(
                whatHappened = "é".repeat(BugReportDraft.MAXIMUM_DESCRIPTION_LENGTH),
                stepsToReproduce = "é".repeat(BugReportDraft.MAXIMUM_STEPS_LENGTH),
            )
        val result =
            client {
                factoryCalls += 1
                FakeHttpsConnection(statusCode = 201)
            }.submit(sampleSubmission().copy(draft = oversizedDraft))

        val invalid = assertIs<BugReportSubmissionResult.Invalid>(result)
        assertEquals(BugReportPayloadError.TOO_LARGE, invalid.validation.payload)
        assertEquals(0, factoryCalls)
    }

    @Test
    fun `endpoint validation requires a clean absolute HTTPS endpoint`() {
        assertTrue(isValidBugReportEndpoint(ENDPOINT))
        assertFalse(isValidBugReportEndpoint("http://reports.openzcine.app/v1/bug-reports"))
        assertFalse(isValidBugReportEndpoint("https://reports.openzcine.app/v1/bug-reports?debug=1"))
        assertFalse(isValidBugReportEndpoint("https://token@reports.openzcine.app/v1/bug-reports"))
        assertFalse(isValidBugReportEndpoint("https://reports.openzcine.app/v1/bug-reports#fragment"))
    }

    private fun client(
        factory: (String) -> HttpsURLConnection,
    ): AndroidBugReportClient =
        AndroidBugReportClient(
            endpoint = ENDPOINT,
            contextProvider = BugReportContextProvider(::sampleContext),
            connectionFactory = factory,
        )

    private fun sampleSubmission(): BugReportSubmission =
        BugReportSubmission(
            draft =
                BugReportDraft(
                    summary = "Preview freezes",
                    whatHappened = "The preview stops after reconnecting.",
                    stepsToReproduce = "Reconnect, then open Live View.",
                    frequency = BugReportFrequency.SOMETIMES,
                    connection = BugReportConnection.WIFI,
                ),
            idempotencyKey = "00000000-0000-4000-8000-000000000000",
        )

    private fun sampleContext(connection: BugReportConnection): BugReportContext =
        BugReportContext(
            appVersion = "0.1.117",
            buildNumber = "117",
            osVersion = "Android 16 (API 36)",
            deviceClass = BugReportDeviceClass.PHONE,
            connection = connection,
        )

    private fun tinyPng(): ByteArray =
        byteArrayOf(
            0x89.toByte(),
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
        )

    private class FakeHttpsConnection(
        private val statusCode: Int = 201,
        private val body: ByteArray = ByteArray(0),
        private val headers: Map<String, String> = emptyMap(),
        private val responseFailure: IOException? = null,
    ) : HttpsURLConnection(URL(ENDPOINT)) {
        private val output = ByteArrayOutputStream()
        private val requestHeaders = mutableMapOf<String, String>()

        override fun connect() = Unit

        override fun disconnect() = Unit

        override fun usingProxy(): Boolean = false

        override fun getOutputStream() = output

        override fun getResponseCode(): Int = responseFailure?.let { throw it } ?: statusCode

        override fun getInputStream() = ByteArrayInputStream(body)

        override fun getErrorStream() = ByteArrayInputStream(body)

        override fun setRequestProperty(key: String, value: String) {
            requestHeaders[key] = value
        }

        override fun getHeaderField(name: String): String? = headers[name]

        override fun setFixedLengthStreamingMode(contentLength: Int) = Unit

        override fun setFixedLengthStreamingMode(contentLength: Long) = Unit

        override fun getCipherSuite(): String = "TLS_UNIT"

        override fun getLocalCertificates(): Array<Certificate>? = null

        override fun getServerCertificates(): Array<Certificate> = emptyArray()

        fun header(name: String): String? = requestHeaders[name]

        fun requestBody(): String = output.toString(Charsets.UTF_8.name())
    }

    private companion object {
        const val ENDPOINT: String = "https://reports.openzcine.app/v1/bug-reports"
    }
}
