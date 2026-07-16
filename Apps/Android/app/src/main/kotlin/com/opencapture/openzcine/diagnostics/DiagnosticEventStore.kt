package com.opencapture.openzcine.diagnostics

import java.io.File
import java.time.Instant

/** Closed, privacy-reviewed breadcrumbs retained for local operator support. */
internal enum class AndroidDiagnosticEvent(val wireValue: String) {
    APP_LAUNCHED("app.launched"),
    APP_FOREGROUND("app.foreground"),
    APP_BACKGROUND("app.background"),
    CONNECTION_DISCONNECTED("connection.disconnected"),
    CONNECTION_CONNECTING("connection.connecting"),
    CONNECTION_CONNECTED("connection.connected"),
    MONITOR_PRESENTED("monitor.presented"),
    MONITOR_DISMISSED("monitor.dismissed"),
    LIVE_VIEW_STARTED("live-view.started"),
    GUIDE_PRESENTED("live-guide.presented"),
    GUIDE_COMPLETED("live-guide.completed"),
    GUIDE_SKIPPED("live-guide.skipped"),
    DIAGNOSTICS_EXPORTED("diagnostics.exported"),
    ;

    companion object {
        fun fromWireValue(value: String): AndroidDiagnosticEvent? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** One timestamped event. No free-form value can cross this boundary. */
internal data class DiagnosticBreadcrumb(
    val timestampMillis: Long,
    val event: AndroidDiagnosticEvent,
)

/** Coarse device category used in reports without manufacturer or model identity. */
internal enum class DiagnosticDeviceClass(val label: String) {
    PHONE("phone"),
    TABLET("tablet"),
}

/** Closed Android process-exit reason retained without process names or descriptions. */
internal enum class DiagnosticExitReason(val label: String) {
    ANR("ANR"),
    CRASH("crash"),
    CRASH_NATIVE("native crash"),
    DEPENDENCY_DIED("dependency died"),
    EXCESSIVE_RESOURCE_USAGE("excessive resource use"),
    INITIALIZATION_FAILURE("initialization failure"),
    LOW_MEMORY("low memory"),
    PACKAGE_STATE_CHANGE("package state change"),
    PACKAGE_UPDATED("package updated"),
    PERMISSION_CHANGE("permission change"),
    SIGNALED("signal"),
    USER_REQUESTED("user requested"),
    USER_STOPPED("user stopped"),
    UNKNOWN("unknown"),
    OTHER("other"),
}

/** Coarse process importance, deliberately excluding raw Android numeric values. */
internal enum class DiagnosticExitImportance(val label: String) {
    FOREGROUND("foreground"),
    VISIBLE("visible"),
    SERVICE("service"),
    BACKGROUND("background"),
    CACHED("cached"),
    UNKNOWN("unknown"),
}

/** Privacy-reduced Android 11+ historical process exit. */
internal data class DiagnosticHistoricalExit(
    val timestampMillis: Long,
    val reason: DiagnosticExitReason,
    val importance: DiagnosticExitImportance,
)

/** Closed report metadata. Version text is normalized before rendering. */
internal data class DiagnosticReportMetadata(
    val generatedAtMillis: Long,
    val appVersion: String,
    val buildNumber: Int,
    val androidApi: Int,
    val deviceClass: DiagnosticDeviceClass,
)

/**
 * Thread-safe, fixed-count and fixed-byte file store for closed diagnostic events.
 *
 * Corrupt or hand-edited lines are ignored instead of entering the report. Every
 * successful write atomically rewrites the already-bounded event set, so the
 * store cannot grow without limit across beta sessions.
 */
internal class DiagnosticEventStore(
    private val eventFile: File,
    private val maximumEventCount: Int = DEFAULT_MAXIMUM_EVENT_COUNT,
    private val maximumEventBytes: Int = DEFAULT_MAXIMUM_EVENT_BYTES,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    init {
        require(maximumEventCount > 0) { "maximumEventCount must be positive" }
        require(maximumEventBytes >= MINIMUM_EVENT_BYTES) {
            "maximumEventBytes must be at least $MINIMUM_EVENT_BYTES"
        }
    }

    @Synchronized
    fun record(event: AndroidDiagnosticEvent) {
        val next = recentEvents() + DiagnosticBreadcrumb(nowMillis(), event)
        writeEvents(bounded(next))
    }

    @Synchronized
    fun recentEvents(): List<DiagnosticBreadcrumb> {
        if (!eventFile.isFile) return emptyList()
        return eventFile.useLines { lines ->
            lines.mapNotNull(::decodeLine).toList()
        }
    }

    /**
     * Returns the sole activity-log shape allowed in an anonymous report.
     *
     * Timestamps, raw local file lines, and every diagnostic-report field are
     * deliberately left behind. A hand-edited value such as "Bob's iPhone"
     * cannot enter because [recentEvents] accepts only [AndroidDiagnosticEvent]
     * wire values.
     */
    @Synchronized
    fun privacyFilteredActivityLog(): List<String> =
        recentEvents()
            .takeLast(BugReportAttachmentLimits.MAXIMUM_ACTIVITY_EVENTS)
            .map { event -> event.event.wireValue }

    private fun bounded(events: List<DiagnosticBreadcrumb>): List<DiagnosticBreadcrumb> {
        val countBounded = events.takeLast(maximumEventCount)
        val retained = ArrayDeque<DiagnosticBreadcrumb>()
        var retainedBytes = 0
        for (event in countBounded.asReversed()) {
            val lineBytes = encodeLine(event).toByteArray(Charsets.UTF_8).size + 1
            if (retained.isNotEmpty() && retainedBytes + lineBytes > maximumEventBytes) break
            if (lineBytes > maximumEventBytes) continue
            retained.addFirst(event)
            retainedBytes += lineBytes
        }
        return retained.toList()
    }

    private fun writeEvents(events: List<DiagnosticBreadcrumb>) {
        eventFile.parentFile?.mkdirs()
        val payload = events.joinToString(separator = "\n", postfix = if (events.isEmpty()) "" else "\n", transform = ::encodeLine)
        val temporary = File(eventFile.parentFile, "${eventFile.name}.tmp")
        temporary.writeText(payload, Charsets.UTF_8)
        if (!temporary.renameTo(eventFile)) {
            temporary.copyTo(eventFile, overwrite = true)
            temporary.delete()
        }
    }

    private fun encodeLine(event: DiagnosticBreadcrumb): String =
        "${event.timestampMillis}|${event.event.wireValue}"

    private fun decodeLine(line: String): DiagnosticBreadcrumb? {
        val delimiter = line.indexOf('|')
        if (delimiter <= 0 || delimiter == line.lastIndex) return null
        val timestamp = line.substring(0, delimiter).toLongOrNull()?.takeIf { it >= 0 } ?: return null
        val event = AndroidDiagnosticEvent.fromWireValue(line.substring(delimiter + 1)) ?: return null
        return DiagnosticBreadcrumb(timestamp, event)
    }

    internal companion object {
        const val DEFAULT_MAXIMUM_EVENT_COUNT: Int = 500
        const val DEFAULT_MAXIMUM_EVENT_BYTES: Int = 256 * 1_024
        private const val MINIMUM_EVENT_BYTES: Int = 128
    }
}

/** Pure, operator-readable renderer for the privacy-bounded report. */
internal object DiagnosticReportRenderer {
    fun render(
        metadata: DiagnosticReportMetadata,
        events: List<DiagnosticBreadcrumb>,
        historicalExits: List<DiagnosticHistoricalExit>,
    ): String {
        val version = normalizedVersion(metadata.appVersion)
        val lines =
            mutableListOf(
                "OpenZCine Android Diagnostics",
                "============================",
                "",
                "Review this file before sharing it publicly.",
                "This local report intentionally excludes camera identities and serials, Wi-Fi",
                "names and network addresses, media names and paths, account identities and tokens,",
                "credentials, camera frames, arbitrary exception text, and user-entered text.",
                "No diagnostics are uploaded automatically by OpenZCine.",
                "Anonymous reports can include only a separately selected privacy-filtered list of app-event names.",
                "",
                "Generated: ${isoTimestamp(metadata.generatedAtMillis)}",
                "App: OpenZCine $version (build ${metadata.buildNumber.coerceAtLeast(0)})",
                "Platform: Android API ${metadata.androidApi.coerceAtLeast(0)}, ${metadata.deviceClass.label}",
                "",
                "Recent app events",
                "-----------------",
            )
        if (events.isEmpty()) {
            lines += "No retained app events."
        } else {
            events.takeLast(DiagnosticEventStore.DEFAULT_MAXIMUM_EVENT_COUNT).forEach { event ->
                lines += "${isoTimestamp(event.timestampMillis)}  ${event.event.wireValue}"
            }
        }
        lines += ""
        lines += "Historical process exits (Android 11+)"
        lines += "--------------------------------------"
        if (historicalExits.isEmpty()) {
            lines += "No privacy-safe historical exit summaries are available."
        } else {
            historicalExits.takeLast(MAXIMUM_HISTORICAL_EXITS).forEach { exit ->
                lines +=
                    "${isoTimestamp(exit.timestampMillis)}  ${exit.reason.label}  ${exit.importance.label}"
            }
        }
        lines += ""
        return lines.joinToString("\n")
    }

    private fun normalizedVersion(value: String): String =
        value.filter { character ->
            character.isLetterOrDigit() || character in setOf('.', '+', '_', '-')
        }.take(MAXIMUM_VERSION_LENGTH).ifEmpty { "unknown" }

    private fun isoTimestamp(timestampMillis: Long): String =
        runCatching { Instant.ofEpochMilli(timestampMillis.coerceAtLeast(0)).toString() }
            .getOrDefault("unknown")

    internal const val MAXIMUM_HISTORICAL_EXITS: Int = 8
    private const val MAXIMUM_VERSION_LENGTH: Int = 32
}
