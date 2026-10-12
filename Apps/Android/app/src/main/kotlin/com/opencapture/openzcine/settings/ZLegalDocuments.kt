package com.opencapture.openzcine.settings

import com.opencapture.opencine.cameracontrols.MonitorLegalDocument
import com.opencapture.opencine.cameracontrols.MonitorLegalDocuments
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks

private val LICENSES_BODY =
    """
OpenZCine
Copyright 2026 Erik Sutton and OpenZCine contributors

Licensed under the Apache License, Version 2.0. You may obtain a copy of the License at:

http://www.apache.org/licenses/LICENSE-2.0

The shared monitor UI bundles the Sora typeface (SIL Open Font License 1.1), Lucide HUD icons (ISC; Feather-derived glyphs also MIT) and View Assist glyphs with Tabler-derived paths (MIT). Their license texts ship inside the shared UI.

The "R3D NE Monitor" built-in look is included with the permission of its author, Wang Yuehua.

Nikon PTP property and operation codes were cross-checked against libgphoto2's public protocol tables. No libgphoto2 source code is included.

Full license text: LICENSE in the repository. Third-party notices: THIRD-PARTY-NOTICES.md. Attribution: NOTICE.
    """.trimIndent()

/**
 * Z's legal set: privacy and terms are the web pages; the licenses summary and [notice], the
 * repository NOTICE staged into the app's assets, ship with the app.
 */
internal fun zLegalDocuments(notice: String) = MonitorLegalDocuments(
    wordmark = "OPENZCINE",
    privacy = MonitorLegalDocument.Link(AndroidSupportLinks.PRIVACY),
    terms = MonitorLegalDocument.Link(AndroidSupportLinks.TERMS),
    licenses = MonitorLegalDocument.Text(LICENSES_BODY),
    notice = MonitorLegalDocument.Text(notice),
)
