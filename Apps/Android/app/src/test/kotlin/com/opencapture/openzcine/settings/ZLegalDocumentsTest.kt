package com.opencapture.openzcine.settings

import com.opencapture.opencine.cameracontrols.MonitorLegalDocument
import com.opencapture.opencine.cameracontrols.MonitorPlatformLegalNotices
import com.opencapture.opencine.cameracontrols.MonitorSettingsCopy
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class ZLegalDocumentsTest {
    @Test
    fun `licenses and NOTICE are the staged repository files and privacy and terms read offline`() {
        val root = File(System.getProperty("openzcine.repositoryRoot"))
        fun text(path: String) = root.resolve(path).readText().trim()
        val documents = ZLegalDocuments
        assertTrue(documents.notice.available)
        assertEquals(text("NOTICE"), documents.notice.body)
        val platform = assertNotNull(MonitorPlatformLegalNotices.text)
        assertTrue(platform.contains(text("../OpenCine/THIRD-PARTY-NOTICES.md")))
        assertTrue(documents.licenses.available)
        assertEquals(listOf(text("LICENSE"), text("THIRD-PARTY-NOTICES.md"), platform).joinToString("\n\n"),
            documents.licenses.body)
        val privacy = assertIs<MonitorLegalDocument.Text>(documents.privacy).body
        val terms = assertIs<MonitorLegalDocument.Text>(documents.terms).body
        assertTrue(privacy.startsWith("OpenZCine "))
        assertTrue(privacy.contains("Sentry") && privacy.contains("Automatic error reports are optional"))
        assertTrue(privacy.endsWith(AndroidSupportLinks.PRIVACY))
        // In-app privacy matches the website (2026-10-16): the shared reliability paragraph with the
        // install identifier, and the optional RED looks Android offers.
        assertTrue(privacy.contains(MonitorSettingsCopy.reliabilityReportsPrivacy))
        assertTrue(privacy.contains("RED looks are optional") && privacy.contains("IPP2"))
        assertTrue(terms.startsWith("OpenZCine is free software under the Apache License 2.0."))
        assertTrue(terms.endsWith(AndroidSupportLinks.TERMS))
        assertFalse((privacy + terms).contains('\u2014'), "Operator copy never uses the em dash")
    }
}
