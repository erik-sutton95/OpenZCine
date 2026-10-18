package com.opencapture.openzcine.diagnostics

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The store moved onto OpenCine's shared journal without changing what is on disk: files the
 * earlier synchronous store wrote load, export and persist again byte for byte.
 */
class DiagnosticEventStoreFormatTest {
    /** Exactly what the pre-journal store wrote: `<epoch millis>|<wire value>` and a final newline. */
    private val legacyEvents =
        "1760000000000|app.launched\n" +
            "1760000000250|connection.path.usb\n" +
            "1760000001000|usb.attached.no-serial\n" +
            "1760000002000|error.connection.usb.permission\n" +
            "1760000003000|connection.connected\n"

    /** Its connect-trace file: `<epoch millis> <line>`, newline-terminated, appended in order. */
    private val legacyConnectTrace =
        "1760000000500 event=connect.gate body=z6iii inferred=three ops=unknown\n" +
            "1760000000900 join=prefix ssid=NIKON_Z6III_1234\n"

    @Test
    fun `legacy files persist again byte for byte`() {
        val directory = legacyDirectory()
        val store = DiagnosticEventStore(File(directory, "events.log"))

        store.flush()

        assertContentEquals(legacyEvents.toByteArray(Charsets.UTF_8), File(directory, "events.log").readBytes())
        assertContentEquals(
            legacyConnectTrace.toByteArray(Charsets.UTF_8),
            File(directory, "connect-trace.log").readBytes(),
        )
    }

    @Test
    fun `new events append after legacy ones in the same line format`() {
        val directory = legacyDirectory()
        val store = DiagnosticEventStore(File(directory, "events.log"), nowMillis = { 1_760_000_004_000 })

        store.record(AndroidDiagnosticEvent.MONITOR_PRESENTED)
        store.recordConnectTrace("event=connect.gate body=z8 ops=known")
        store.flush()

        assertEquals(
            legacyEvents + "1760000004000|monitor.presented\n",
            File(directory, "events.log").readText(Charsets.UTF_8),
        )
        assertEquals(
            legacyConnectTrace + "1760000004000 event=connect.gate body=z8 ops=known\n",
            File(directory, "connect-trace.log").readText(Charsets.UTF_8),
        )
    }

    @Test
    fun `legacy events round trip through an export and a reopened store`() {
        val directory = legacyDirectory()
        val first = DiagnosticEventStore(File(directory, "events.log"))
        val exported = render(first)

        assertTrue(exported.contains("2025-10-09T08:53:20Z  app.launched"))
        assertTrue(exported.contains("2025-10-09T08:53:21Z  usb.attached.no-serial"))
        assertTrue(exported.contains("2025-10-09T08:53:23Z  connection.connected"))
        assertTrue(exported.contains("1760000000500 event=connect.gate body=z6iii inferred=three ops=unknown"))
        assertEquals(
            listOf(
                "app.launched",
                "connection.path.usb",
                "usb.attached.no-serial",
                "error.connection.usb.permission",
                "connection.connected",
            ),
            first.privacyFilteredActivityLog(),
        )

        first.flush()
        val reopened = DiagnosticEventStore(File(directory, "events.log"))
        assertEquals(first.recentEvents(), reopened.recentEvents())
        assertEquals(first.recentConnectTrace(), reopened.recentConnectTrace())
        assertEquals(exported, render(reopened))
    }

    @Test
    fun `the journal writer persists without an explicit flush`() {
        val directory = Files.createTempDirectory("openzcine-diagnostics-writer").toFile()
        val file = File(directory, "events.log")
        val store = DiagnosticEventStore(file, nowMillis = { 7 })

        store.record(AndroidDiagnosticEvent.APP_LAUNCHED)

        val deadline = System.nanoTime() + 5_000_000_000L
        while (file.readTextOrEmpty() != "7|app.launched\n" && System.nanoTime() < deadline) Thread.yield()
        assertEquals("7|app.launched\n", file.readTextOrEmpty())
        assertFalse(File(directory, "connect-trace.log").exists(), "no trace recorded, so no trace file")
    }

    @Test
    fun `corrupt legacy lines are dropped on the next persist as before`() {
        val directory = Files.createTempDirectory("openzcine-diagnostics-corrupt").toFile()
        File(directory, "events.log").writeText("1|app.launched\n2|ssid=PRIVATE\nnot-a-line\n3|app.background\n")
        val store = DiagnosticEventStore(File(directory, "events.log"))

        store.flush()

        assertEquals("1|app.launched\n3|app.background\n", File(directory, "events.log").readText())
    }

    private fun legacyDirectory(): File =
        Files.createTempDirectory("openzcine-diagnostics-legacy").toFile().also { directory ->
            File(directory, "events.log").writeBytes(legacyEvents.toByteArray(Charsets.UTF_8))
            File(directory, "connect-trace.log").writeBytes(legacyConnectTrace.toByteArray(Charsets.UTF_8))
        }

    private fun render(store: DiagnosticEventStore): String =
        DiagnosticReportRenderer.render(
            metadata =
                DiagnosticReportMetadata(
                    generatedAtMillis = 1_760_000_010_000,
                    appVersion = "0.2.5",
                    buildNumber = 205,
                    androidApi = 35,
                    deviceClass = DiagnosticDeviceClass.PHONE,
                ),
            events = store.recentEvents(),
            historicalExits = emptyList(),
            connectTrace = store.recentConnectTrace(),
        )

    private fun File.readTextOrEmpty(): String = if (isFile) readText(Charsets.UTF_8) else ""
}
