package com.opencapture.openzcine.settings

import com.opencapture.opencine.cameracontrols.MonitorLegalDocument
import com.opencapture.opencine.cameracontrols.MonitorPlatformLegalNotices
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class ZLegalDocumentsTest {
    @Test
    fun `licenses and NOTICE are the staged repository files while privacy and terms open the web`() {
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
        assertEquals(AndroidSupportLinks.PRIVACY, (documents.privacy as MonitorLegalDocument.Link).url)
        assertEquals(AndroidSupportLinks.TERMS, (documents.terms as MonitorLegalDocument.Link).url)
    }
}
