package com.opencapture.openzcine.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals

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
        assertEquals(
            "https://github.com/erik-sutton95/OpenZCine/security/advisories/new",
            AndroidSupportLinks.SECURITY_ADVISORY,
        )
    }
}
