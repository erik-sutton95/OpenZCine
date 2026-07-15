package com.opencapture.openzcine.diagnostics

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AndroidSupportLinksTest {
    @Test
    fun `public destinations match the established iOS and repository links`() {
        assertEquals("https://openzcine.app/support/", AndroidSupportLinks.SUPPORT)
        assertEquals(
            "https://github.com/erik-sutton95/OpenZCine/discussions/new?category=ideas-feature-requests",
            AndroidSupportLinks.FEATURE_REQUEST,
        )
        assertEquals(
            "https://github.com/erik-sutton95/OpenZCine",
            AndroidSupportLinks.SOURCE,
        )
        assertEquals("https://openzcine.app/privacy/", AndroidSupportLinks.PRIVACY)
        assertEquals("https://openzcine.app/terms/", AndroidSupportLinks.TERMS)
    }

    @Test
    fun `bug report is Android prefixed and contains only coarse platform metadata`() {
        val value =
            AndroidSupportLinks.bugReport(
                AndroidSupportMetadata(
                    appVersion = "0.1.117",
                    buildNumber = 117,
                    androidApi = 33,
                    deviceClass = DiagnosticDeviceClass.PHONE,
                ),
            )
        val query = queryItems(URI(value).rawQuery)

        assertEquals("bug_report.yml", query["template"])
        assertEquals("[Android] ", query["title"])
        assertEquals(
            "OpenZCine 0.1.117 (build 117), Android API 33, phone",
            query["platform"],
        )
        assertFalse(value.contains("serial", ignoreCase = true))
        assertFalse(value.contains("model", ignoreCase = true))
        assertFalse(value.contains("ssid", ignoreCase = true))
        assertTrue(value.startsWith("https://github.com/erik-sutton95/OpenZCine/issues/new?"))
    }

    private fun queryItems(query: String): Map<String, String> =
        query.split('&').associate { item ->
            val parts = item.split('=', limit = 2)
            decode(parts[0]) to decode(parts.getOrElse(1) { "" })
        }

    private fun decode(value: String): String =
        URLDecoder.decode(value, StandardCharsets.UTF_8)
}
