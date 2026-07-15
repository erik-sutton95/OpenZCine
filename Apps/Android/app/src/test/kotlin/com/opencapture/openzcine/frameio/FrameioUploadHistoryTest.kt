package com.opencapture.openzcine.frameio

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FrameioUploadHistoryTest {
    @Test
    fun `confirmed identities survive a new index instance and remain bounded`() {
        var persisted: String? = null
        fun index(): FrameioUploadHistoryIndex =
            FrameioUploadHistoryIndex(
                loadValue = { persisted },
                saveValue = { value ->
                    persisted = value
                    true
                },
                maximumIdentities = 2,
            )

        assertTrue(index().recordUploaded("clip-one"))
        assertTrue(index().recordUploaded("clip-two"))
        assertTrue(index().wasUploaded("clip-one"))
        assertTrue(index().recordUploaded("clip-three"))

        val restored = index()
        assertFalse(restored.wasUploaded("clip-one"))
        assertTrue(restored.wasUploaded("clip-two"))
        assertTrue(restored.wasUploaded("clip-three"))
        assertFalse(restored.recordUploaded("clip/name"))
    }
}
