package com.opencapture.openzcine.settings

import com.opencapture.opencine.cameracontrols.MonitorLegalDocument
import com.opencapture.opencine.cameracontrols.MonitorLegalDocuments
import com.opencapture.opencine.cameracontrols.MonitorPlatformLegalNotices
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks

/**
 * Z's legal set: privacy and terms are the web pages. Licenses and NOTICE are the repository's
 * LICENSE, THIRD-PARTY-NOTICES.md and NOTICE, staged as resources at build time, with the platform
 * notices; a build missing one shows the unavailable page.
 */
internal val ZLegalDocuments = MonitorLegalDocuments(
    wordmark = "OPENZCINE",
    privacy = MonitorLegalDocument.Link(AndroidSupportLinks.PRIVACY),
    terms = MonitorLegalDocument.Link(AndroidSupportLinks.TERMS),
    licenses = MonitorLegalDocument.bundledText(listOf(
        MonitorLegalDocument.resource("openzcine/legal/LICENSE"),
        MonitorLegalDocument.resource("openzcine/legal/THIRD-PARTY-NOTICES.md"),
        MonitorPlatformLegalNotices.text,
    )),
    notice = MonitorLegalDocument.bundledText(listOf(MonitorLegalDocument.resource("openzcine/legal/NOTICE"))),
)
