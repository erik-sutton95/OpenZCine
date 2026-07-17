package com.opencapture.openzcine.diagnostics

import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DiagnosticEventStoreTest {
    @Test
    fun `event store enforces count and byte bounds`() {
        val file = temporaryEventFile()
        var timestamp = 0L
        val store =
            DiagnosticEventStore(
                eventFile = file,
                maximumEventCount = 5,
                maximumEventBytes = 180,
                nowMillis = { ++timestamp },
            )

        repeat(20) { store.record(AndroidDiagnosticEvent.APP_FOREGROUND) }

        assertEquals(5, store.recentEvents().size)
        assertTrue(file.length() <= 180)
        assertEquals((16L..20L).toList(), store.recentEvents().map { it.timestampMillis })
    }

    @Test
    fun `concurrent writers remain bounded and retain only closed events`() {
        val file = temporaryEventFile()
        val store =
            DiagnosticEventStore(
                eventFile = file,
                maximumEventCount = 64,
                maximumEventBytes = 8_192,
            )
        val executor = Executors.newFixedThreadPool(8)

        repeat(400) { index ->
            executor.submit {
                store.record(
                    if (index % 2 == 0) {
                        AndroidDiagnosticEvent.CONNECTION_CONNECTING
                    } else {
                        AndroidDiagnosticEvent.CONNECTION_CONNECTED
                    },
                )
            }
        }
        executor.shutdown()
        assertTrue(executor.awaitTermination(20, TimeUnit.SECONDS))

        val events = store.recentEvents()
        assertEquals(64, events.size)
        assertTrue(
            events.all {
                it.event in
                    setOf(
                        AndroidDiagnosticEvent.CONNECTION_CONNECTING,
                        AndroidDiagnosticEvent.CONNECTION_CONNECTED,
                    )
            },
        )
    }

    @Test
    fun `corrupt free-form lines never enter events or reports`() {
        val file = temporaryEventFile()
        file.parentFile?.mkdirs()
        file.writeText(
            "1|app.launched\n" +
                "2|camera.serial=SECRET-SERIAL\n" +
                "3|ssid=PRIVATE-NETWORK\n" +
                "4|exception=/private/media/clip.mov\n",
        )
        val store = DiagnosticEventStore(file)

        val report =
            DiagnosticReportRenderer.render(
                metadata =
                    DiagnosticReportMetadata(
                        generatedAtMillis = 5,
                        appVersion = "0.1.117",
                        buildNumber = 117,
                        androidApi = 33,
                        deviceClass = DiagnosticDeviceClass.PHONE,
                    ),
                events = store.recentEvents(),
                historicalExits = emptyList(),
            )

        assertEquals(listOf(AndroidDiagnosticEvent.APP_LAUNCHED), store.recentEvents().map { it.event })
        assertTrue(report.contains("app.launched"))
        assertFalse(report.contains("SECRET-SERIAL"))
        assertFalse(report.contains("PRIVATE-NETWORK"))
        assertFalse(report.contains("clip.mov"))
    }

    @Test
    fun `anonymous activity log retains only closed event names without timestamps or device text`() {
        val file = temporaryEventFile()
        file.parentFile?.mkdirs()
        file.writeText(
            "1|app.launched\n" +
                "2|Bob's iPhone\n" +
                "3|app.foreground|name=Bob's iPhone\n" +
                "4|live-view.started\n",
        )
        val store = DiagnosticEventStore(file)

        val activityLog = store.privacyFilteredActivityLog()

        assertEquals(listOf("app.launched", "live-view.started"), activityLog)
        assertFalse(activityLog.joinToString().contains("Bob's iPhone"))
        assertFalse(activityLog.any { it.contains('|') || it.any(Char::isDigit) })
        assertTrue(isPrivacyFilteredActivityLog(activityLog))
    }

    @Test
    fun `closed failure phases become privacy-safe incident codes`() {
        assertEquals(
            AndroidDiagnosticEvent.CONNECTION_FAILED,
            AndroidDiagnosticEvent.fromFailurePhase("failed"),
        )
        assertEquals(
            AndroidDiagnosticEvent.CONNECTION_EVENT_CHANNEL_ENDED,
            AndroidDiagnosticEvent.fromFailurePhase("eventChannelEnded"),
        )
        assertEquals(
            AndroidDiagnosticEvent.LIVE_VIEW_STALLED,
            AndroidDiagnosticEvent.fromFailurePhase("liveViewStalled"),
        )
        assertEquals(null, AndroidDiagnosticEvent.fromFailurePhase("Bob's iPhone"))
    }

    @Test
    fun `report includes only coarse process exits and explicit privacy notice`() {
        val report =
            DiagnosticReportRenderer.render(
                metadata =
                    DiagnosticReportMetadata(
                        generatedAtMillis = 1_000,
                        appVersion = "0.1.117 beta!",
                        buildNumber = 117,
                        androidApi = 33,
                        deviceClass = DiagnosticDeviceClass.PHONE,
                    ),
                events =
                    listOf(
                        DiagnosticBreadcrumb(900, AndroidDiagnosticEvent.LIVE_VIEW_STARTED),
                    ),
                historicalExits =
                    listOf(
                        DiagnosticHistoricalExit(
                            timestampMillis = 800,
                            reason = DiagnosticExitReason.ANR,
                            importance = DiagnosticExitImportance.FOREGROUND,
                        ),
                    ),
            )

        assertTrue(report.contains("Android API 33, phone"))
        assertTrue(report.contains("ANR  foreground"))
        assertTrue(report.contains("No diagnostics are uploaded"))
        assertTrue(report.contains("arbitrary exception text"))
        assertFalse(report.contains("beta!"))
    }

    @Test
    fun `manifest exposes only the dedicated diagnostics ready cache path`() {
        val root = File(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
        val manifest = File(root, "Apps/Android/app/src/main/AndroidManifest.xml").readText()
        val paths =
            File(
                root,
                "Apps/Android/app/src/main/res/xml/diagnostics_share_paths.xml",
            ).readText()

        assertTrue(manifest.contains("\${applicationId}.diagnostics-share"))
        assertTrue(manifest.contains("@xml/diagnostics_share_paths"))
        assertTrue(paths.contains("path=\"$DIAGNOSTICS_READY_RELATIVE_PATH/\""))
        assertFalse(paths.contains("path=\".\""))
        assertFalse(paths.contains("files-path"))
    }

    private fun temporaryEventFile(): File =
        Files.createTempDirectory("openzcine-diagnostics-test").resolve("events.log").toFile()
}
