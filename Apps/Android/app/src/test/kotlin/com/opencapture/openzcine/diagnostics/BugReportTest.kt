package com.opencapture.openzcine.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BugReportTest {
    @Test
    fun `validation trims required fields and bounds every operator field`() {
        val empty =
            BugReportDraft(
                summary = "  ",
                whatHappened = "\n",
                stepsToReproduce = "",
                frequency = BugReportFrequency.UNKNOWN,
                connection = BugReportConnection.UNKNOWN,
            )

        assertEquals(BugReportFieldError.REQUIRED, empty.validation().summary)
        assertEquals(BugReportFieldError.REQUIRED, empty.validation().whatHappened)
        assertNull(empty.validation().stepsToReproduce)

        val oversized =
            empty.copy(
                summary = "s".repeat(BugReportDraft.MAXIMUM_SUMMARY_LENGTH + 1),
                whatHappened = "h".repeat(BugReportDraft.MAXIMUM_DESCRIPTION_LENGTH + 1),
                stepsToReproduce = "r".repeat(BugReportDraft.MAXIMUM_STEPS_LENGTH + 1),
            )

        assertEquals(BugReportFieldError.TOO_LONG, oversized.validation().summary)
        assertEquals(BugReportFieldError.TOO_LONG, oversized.validation().whatHappened)
        assertEquals(BugReportFieldError.TOO_LONG, oversized.validation().stepsToReproduce)
    }

    @Test
    fun `payload matches the v1 contract and omits optional steps when blank`() {
        val payload =
            BugReportPayload.from(
                draft =
                    BugReportDraft(
                        summary = "  Live view freezes  ",
                        whatHappened = "  The preview stopped after reconnecting.  ",
                        stepsToReproduce = "  ",
                        frequency = BugReportFrequency.SOMETIMES,
                        connection = BugReportConnection.WIFI,
                    ),
                context =
                    BugReportContext(
                        appVersion = " 0.1.117 ",
                        buildNumber = " 117 ",
                        osVersion = " Android 16 (API 36) ",
                        deviceClass = BugReportDeviceClass.PHONE,
                        connection = BugReportConnection.WIFI,
                    ),
            )

        assertEquals(
            "{\"schemaVersion\":1,\"summary\":\"Live view freezes\"," +
                "\"whatHappened\":\"The preview stopped after reconnecting.\"," +
                "\"frequency\":\"sometimes\",\"context\":{" +
                "\"platform\":\"android\",\"appVersion\":\"0.1.117\"," +
                "\"buildNumber\":\"117\",\"osVersion\":\"Android 16 (API 36)\"," +
                "\"deviceClass\":\"phone\",\"connection\":\"wifi\"}}",
            payload.toJson(),
        )

        val wire = payload.toJson()
        listOf("model", "serial", "ssid", "ip", "media", "path", "diagnostic", "attachment").forEach {
            forbidden -> assertFalse(wire.contains(forbidden, ignoreCase = true), forbidden)
        }
    }

    @Test
    fun `context accepts only bounded coarse metadata`() {
        val valid = sampleContext()
        assertTrue(valid.isValid())
        assertFalse(
            valid.copy(appVersion = "v".repeat(BugReportContext.MAXIMUM_APP_VERSION_LENGTH + 1)).isValid(),
        )
        assertFalse(
            valid.copy(buildNumber = "b".repeat(BugReportContext.MAXIMUM_BUILD_NUMBER_LENGTH + 1)).isValid(),
        )
        assertFalse(
            valid.copy(osVersion = "o".repeat(BugReportContext.MAXIMUM_OS_VERSION_LENGTH + 1)).isValid(),
        )
    }

    private fun sampleContext(): BugReportContext =
        BugReportContext(
            appVersion = "0.1.117",
            buildNumber = "117",
            osVersion = "Android 16 (API 36)",
            deviceClass = BugReportDeviceClass.PHONE,
            connection = BugReportConnection.USB,
        )
}
