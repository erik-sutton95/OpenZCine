package com.opencapture.openzcine.bridge

import kotlin.test.Test
import kotlin.test.assertEquals

class SwiftCoreSmokeTest {
    @Test
    fun `formatReport renders all three lines in order`() {
        val lines =
            SwiftCoreSmoke.formatReport(
                version = "OpenZCineCore swift-android/arm64",
                ssid = "NIKON_ZR_01234",
                displayName = "Nikon ZR",
            )
        assertEquals(
            listOf(
                "core: OpenZCineCore swift-android/arm64",
                "ssid(ZR_6001234): NIKON_ZR_01234",
                "displayName(ZR_6001234): Nikon ZR",
            ),
            lines,
        )
    }

    @Test
    fun `formatReport marks a missing ssid`() {
        val lines = SwiftCoreSmoke.formatReport("v", null, "Nikon camera")
        assertEquals("ssid(ZR_6001234): <none>", lines[1])
    }
}
