package com.opencapture.openzcine.lut

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RedLutDownloadUrlTest {
    @Test
    fun `allows RED storefront and documented S3 bucket hosts only`() {
        assertTrue(
            isAllowedRedDownloadUrl(
                "https://www.reddigitalcinema.com/download/ipp2-output-presets",
            ),
        )
        assertTrue(
            isAllowedRedDownloadUrl(
                "https://s3.amazonaws.com/red-4/downloads/ipp2-presets.zip",
            ),
        )
        assertTrue(isAllowedRedDownloadUrl("https://red-4.s3.amazonaws.com/presets.zip"))
        assertFalse(isAllowedRedDownloadUrl("https://evil.example/red.zip"))
        assertFalse(isAllowedRedDownloadUrl("https://s3.amazonaws.com/other-bucket/file.zip"))
        assertFalse(isAllowedRedDownloadUrl("file:///tmp/local.zip"))
    }
}
