package com.opencapture.openzcine.settings

import com.opencapture.opencine.cameracontrols.MonitorLegalDocument
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ZLegalDocumentsTest {
    @Test
    fun `licenses and the staged NOTICE read offline while privacy and terms open the web`() {
        val documents = zLegalDocuments(notice = "SIMULATED NOTICE")
        assertEquals("SIMULATED NOTICE", documents.notice.body)
        assertTrue(documents.licenses.body.contains("Apache License, Version 2.0"))
        assertTrue(documents.licenses.body.contains("Attribution: NOTICE."))
        assertEquals(AndroidSupportLinks.PRIVACY, (documents.privacy as MonitorLegalDocument.Link).url)
        assertEquals(AndroidSupportLinks.TERMS, (documents.terms as MonitorLegalDocument.Link).url)
    }
}
