package com.opencapture.openzcine.diagnostics

/** The intentionally small set of report-frequency values accepted by the public endpoint. */
internal enum class BugReportFrequency(val wireValue: String) {
    ALWAYS("always"),
    SOMETIMES("sometimes"),
    ONCE("once"),
    UNKNOWN("unknown"),
}

/** The connection category an operator deliberately selects for a report. */
internal enum class BugReportConnection(val wireValue: String) {
    WIFI("wifi"),
    USB("usb"),
    UNKNOWN("unknown"),
}

/** Coarse screen-size category that never identifies the operator's device. */
internal enum class BugReportDeviceClass(val wireValue: String) {
    PHONE("phone"),
    TABLET("tablet"),
    UNKNOWN("unknown"),
}

/**
 * Operator-entered report fields. This value is never persisted or queued by
 * OpenZCine; it exists only while the report screen is visible and sending.
 */
internal data class BugReportDraft(
    val summary: String,
    val whatHappened: String,
    val stepsToReproduce: String,
    val frequency: BugReportFrequency,
    val connection: BugReportConnection,
) {
    fun validation(): BugReportValidation =
        BugReportValidation(
            summary = validationError(summary, MAXIMUM_SUMMARY_LENGTH),
            whatHappened = validationError(whatHappened, MAXIMUM_DESCRIPTION_LENGTH),
            stepsToReproduce = optionalValidationError(stepsToReproduce, MAXIMUM_STEPS_LENGTH),
        )

    internal fun normalized(): BugReportDraft =
        copy(
            summary = summary.trim(),
            whatHappened = whatHappened.trim(),
            stepsToReproduce = stepsToReproduce.trim(),
        )

    private fun validationError(value: String, maximumLength: Int): BugReportFieldError? {
        val normalized = value.trim()
        return when {
            normalized.isEmpty() -> BugReportFieldError.REQUIRED
            normalized.length > maximumLength -> BugReportFieldError.TOO_LONG
            else -> null
        }
    }

    private fun optionalValidationError(value: String, maximumLength: Int): BugReportFieldError? =
        if (value.trim().length > maximumLength) BugReportFieldError.TOO_LONG else null

    internal companion object {
        const val MAXIMUM_SUMMARY_LENGTH: Int = 120
        const val MAXIMUM_DESCRIPTION_LENGTH: Int = 4_000
        const val MAXIMUM_STEPS_LENGTH: Int = 4_000
    }
}

/** One field-level validation state suitable for accessible UI feedback. */
internal enum class BugReportFieldError {
    REQUIRED,
    TOO_LONG,
}

/** Validation results for a [BugReportDraft]. */
internal data class BugReportValidation(
    val summary: BugReportFieldError?,
    val whatHappened: BugReportFieldError?,
    val stepsToReproduce: BugReportFieldError?,
    val payload: BugReportPayloadError? = null,
) {
    val isValid: Boolean
        get() =
            summary == null &&
                whatHappened == null &&
                stepsToReproduce == null &&
                payload == null
}

/** A relay-wide validation error that does not belong to one text field. */
internal enum class BugReportPayloadError {
    TOO_LARGE,
    INVALID_ATTACHMENTS,
}

/** Shared bounds for the deliberately narrow anonymous-attachment contract. */
internal object BugReportAttachmentLimits {
    const val MAXIMUM_ACTIVITY_EVENTS: Int = 200
    const val MAXIMUM_SCREENSHOTS: Int = 3
    const val MAXIMUM_SCREENSHOT_BYTES: Int = 1_024 * 1_024
    const val MAXIMUM_V2_REPORT_BYTES: Int = 16 * 1_024
    const val MAXIMUM_MULTIPART_BYTES: Int =
        MAXIMUM_SCREENSHOTS * MAXIMUM_SCREENSHOT_BYTES + 64 * 1_024
    const val MAXIMUM_IMAGE_DIMENSION: Int = 2_560
}

/**
 * Closed, non-identifying technical context appended to every Android report.
 * It deliberately contains no device, camera, network, media, account, or
 * persistent-install identity.
 */
internal data class BugReportContext(
    val appVersion: String,
    val buildNumber: String,
    val osVersion: String,
    val deviceClass: BugReportDeviceClass,
    val connection: BugReportConnection,
) {
    internal fun isValid(): Boolean =
        appVersion.trim().length in 1..MAXIMUM_APP_VERSION_LENGTH &&
            buildNumber.trim().length in 1..MAXIMUM_BUILD_NUMBER_LENGTH &&
            osVersion.trim().length in 1..MAXIMUM_OS_VERSION_LENGTH

    internal fun normalized(): BugReportContext =
        copy(
            appVersion = appVersion.trim(),
            buildNumber = buildNumber.trim(),
            osVersion = osVersion.trim(),
        )

    internal companion object {
        const val MAXIMUM_APP_VERSION_LENGTH: Int = 64
        const val MAXIMUM_BUILD_NUMBER_LENGTH: Int = 64
        const val MAXIMUM_OS_VERSION_LENGTH: Int = 128
    }
}

/** Supplies the closed Android context at the moment an operator sends a report. */
internal fun interface BugReportContextProvider {
    fun context(connection: BugReportConnection): BugReportContext
}

/**
 * Exact v1 payload for the anonymous-report relay. The relay, not the app,
 * owns GitHub credentials and issue creation.
 */
internal data class BugReportPayload(
    val summary: String,
    val whatHappened: String,
    val stepsToReproduce: String?,
    val frequency: BugReportFrequency,
    val context: BugReportContext,
) {
    fun toJson(): String =
        buildString {
            append('{')
            appendJsonNumberField("schemaVersion", SCHEMA_VERSION)
            append(',')
            appendJsonStringField("summary", summary)
            append(',')
            appendJsonStringField("whatHappened", whatHappened)
            stepsToReproduce?.let { value ->
                append(',')
                appendJsonStringField("stepsToReproduce", value)
            }
            append(',')
            appendJsonStringField("frequency", frequency.wireValue)
            append(",\"context\":{")
            appendJsonStringField("platform", PLATFORM)
            append(',')
            appendJsonStringField("appVersion", context.appVersion)
            append(',')
            appendJsonStringField("buildNumber", context.buildNumber)
            append(',')
            appendJsonStringField("osVersion", context.osVersion)
            append(',')
            appendJsonStringField("deviceClass", context.deviceClass.wireValue)
            append(',')
            appendJsonStringField("connection", context.connection.wireValue)
            append("}}")
        }

    /** UTF-8 request bytes used for the relay's aggregate body-size guard. */
    internal fun utf8Bytes(): ByteArray = toJson().toByteArray(Charsets.UTF_8)

    internal companion object {
        const val SCHEMA_VERSION: Int = 1
        const val PLATFORM: String = "android"
        const val MAXIMUM_UTF8_BYTES: Int = 12 * 1_024

        fun from(draft: BugReportDraft, context: BugReportContext): BugReportPayload {
            val normalizedDraft = draft.normalized()
            val normalizedContext = context.normalized()
            return BugReportPayload(
                summary = normalizedDraft.summary,
                whatHappened = normalizedDraft.whatHappened,
                stepsToReproduce = normalizedDraft.stepsToReproduce.ifBlank { null },
                frequency = normalizedDraft.frequency,
                context = normalizedContext,
            )
        }
    }
}

/**
 * Exact v2 JSON part for an anonymous report with optional attachments.
 *
 * The activity log is intentionally only a closed list of event names. It
 * never includes the timestamped local diagnostics report, free-form values,
 * device names, or Android process metadata.
 */
internal data class BugReportAttachmentPayload(
    val summary: String,
    val whatHappened: String,
    val stepsToReproduce: String?,
    val frequency: BugReportFrequency,
    val context: BugReportContext,
    val activityLog: List<String>?,
) {
    fun toJson(): String =
        buildString {
            append('{')
            appendJsonNumberField("schemaVersion", SCHEMA_VERSION)
            append(',')
            appendJsonStringField("summary", summary)
            append(',')
            appendJsonStringField("whatHappened", whatHappened)
            stepsToReproduce?.let { value ->
                append(',')
                appendJsonStringField("stepsToReproduce", value)
            }
            append(',')
            appendJsonStringField("frequency", frequency.wireValue)
            append(",\"context\":{")
            appendJsonStringField("platform", PLATFORM)
            append(',')
            appendJsonStringField("appVersion", context.appVersion)
            append(',')
            appendJsonStringField("buildNumber", context.buildNumber)
            append(',')
            appendJsonStringField("osVersion", context.osVersion)
            append(',')
            appendJsonStringField("deviceClass", context.deviceClass.wireValue)
            append(',')
            appendJsonStringField("connection", context.connection.wireValue)
            append('}')
            activityLog?.let { events ->
                append(',')
                appendJsonStringArrayField("activityLog", events)
            }
            append('}')
        }

    /** UTF-8 report-part bytes used for the v2 body-size guard. */
    internal fun utf8Bytes(): ByteArray = toJson().toByteArray(Charsets.UTF_8)

    internal companion object {
        const val SCHEMA_VERSION: Int = 2
        const val PLATFORM: String = "android"

        fun from(
            draft: BugReportDraft,
            context: BugReportContext,
            activityLog: List<String>?,
        ): BugReportAttachmentPayload {
            val normalizedDraft = draft.normalized()
            val normalizedContext = context.normalized()
            return BugReportAttachmentPayload(
                summary = normalizedDraft.summary,
                whatHappened = normalizedDraft.whatHappened,
                stepsToReproduce = normalizedDraft.stepsToReproduce.ifBlank { null },
                frequency = normalizedDraft.frequency,
                context = normalizedContext,
                activityLog = activityLog,
            )
        }
    }
}

private fun StringBuilder.appendJsonNumberField(name: String, value: Int) {
    append(bugReportJsonString(name))
    append(':')
    append(value)
}

private fun StringBuilder.appendJsonStringField(name: String, value: String) {
    append(bugReportJsonString(name))
    append(':')
    append(bugReportJsonString(value))
}

private fun StringBuilder.appendJsonStringArrayField(name: String, values: List<String>) {
    append(bugReportJsonString(name))
    append(":[")
    values.forEachIndexed { index, value ->
        if (index > 0) append(',')
        append(bugReportJsonString(value))
    }
    append(']')
}

/** Escapes an operator string without pulling Android-only JSON stubs into JVM tests. */
private fun bugReportJsonString(value: String): String =
    buildString {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else ->
                    if (character.code < 0x20) {
                        append("\\u")
                        append(character.code.toString(16).padStart(4, '0'))
                    } else {
                        append(character)
                    }
            }
        }
        append('"')
    }

/**
 * One explicitly initiated anonymous report and its caller-owned idempotency
 * key. The form retains the key only while an unchanged draft can be retried.
 */
internal data class BugReportSubmission(
    val draft: BugReportDraft,
    val idempotencyKey: String,
    val includeActivityLog: Boolean = false,
    val activityLog: List<String> = emptyList(),
    val screenshots: List<BugReportScreenshot> = emptyList(),
) {
    /** Whether this submission must use the v2 multipart relay endpoint. */
    internal fun usesAttachments(): Boolean =
        includeActivityLog || activityLog.isNotEmpty() || screenshots.isNotEmpty()
}

/**
 * A freshly re-rendered screenshot held only in memory for one send attempt.
 * The type deliberately owns a copy of PNG bytes and exposes no source URI or
 * original filename.
 */
internal class BugReportScreenshot private constructor(private val pngBytes: ByteArray) {
    val byteCount: Int
        get() = pngBytes.size

    internal fun copyPngBytes(): ByteArray = pngBytes.copyOf()

    internal companion object {
        fun fromSanitizedPng(bytes: ByteArray): BugReportScreenshot? =
            if (isPng(bytes)) BugReportScreenshot(bytes.copyOf()) else null
    }
}

/** A lightweight client-side guard; the relay performs full PNG validation. */
internal fun isPng(bytes: ByteArray): Boolean =
    bytes.size >= PNG_SIGNATURE.size && PNG_SIGNATURE.indices.all { bytes[it] == PNG_SIGNATURE[it] }

private val PNG_SIGNATURE: ByteArray =
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

/** Only closed event names can be placed in a public anonymous attachment. */
internal fun isPrivacyFilteredActivityLog(events: List<String>): Boolean =
    events.size <= BugReportAttachmentLimits.MAXIMUM_ACTIVITY_EVENTS &&
        events.all { event -> AndroidDiagnosticEvent.fromWireValue(event) != null }

/** Sends one explicitly initiated anonymous bug report without persistence or automatic retries. */
internal fun interface BugReportSubmitter {
    suspend fun submit(submission: BugReportSubmission): BugReportSubmissionResult
}

/** Non-sensitive result states exposed to the report screen. */
internal sealed interface BugReportSubmissionResult {
    data object Submitted : BugReportSubmissionResult

    data class Invalid(val validation: BugReportValidation) : BugReportSubmissionResult

    data class Failed(
        val reason: BugReportSubmissionFailure,
        val retryAfterSeconds: Long? = null,
    ) : BugReportSubmissionResult
}

/** Generic failure categories that never include a request, response, or endpoint body. */
internal enum class BugReportSubmissionFailure {
    CONFIGURATION,
    NETWORK,
    SERVICE,
    RATE_LIMITED,
}
