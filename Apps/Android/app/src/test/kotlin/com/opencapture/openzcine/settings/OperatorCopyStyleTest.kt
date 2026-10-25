package com.opencapture.openzcine.settings

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/** Owner style rule: operator copy never uses the em dash (hardware pass 2026-10-24). */
class OperatorCopyStyleTest {
    @Test
    fun `string resources never use the em dash`() {
        val root = File(System.getProperty("openzcine.repositoryRoot"))
        val pattern = Regex("""<string name="([^"]+)"[^>]*>([^<]*)</string>""")
        val offenders = listOf("Apps/Android/app/src/main/res/values/strings.xml", "Apps/Android/wear/src/main/res/values/strings.xml")
            .flatMap { path -> pattern.findAll(root.resolve(path).readText()).map { it.groupValues[1] to it.groupValues[2] } }
            // A lone dash is the unknown-value glyph, not prose.
            .filter { (name, text) -> '\u2014' in text && text.trim() != "\u2014" && name !in CHOOSER_STRINGS }
            .map { it.first }
        assertEquals(emptyList(), offenders)
    }

    private companion object {
        /** The add-setup chooser copy, replaced by the shared OpenCine chooser in its own change. */
        val CHOOSER_STRINGS = setOf("saved_setup_ap_body", "saved_setup_hotspot_body", "saved_setup_usb_body",
            "saved_setup_router_name_permission")
    }
}
