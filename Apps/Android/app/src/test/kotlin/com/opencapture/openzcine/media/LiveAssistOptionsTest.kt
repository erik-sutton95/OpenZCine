package com.opencapture.openzcine.media

import androidx.compose.ui.geometry.Rect
import com.opencapture.openzcine.AssistTool
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LiveAssistOptionsTest {
    @Test
    fun `panel trails its measured tool and prefers a complete fit above`() {
        val offset =
            assistOptionsPanelOffset(
                viewportWidth = 1_000f,
                viewportHeight = 600f,
                anchorBounds = Rect(700f, 500f, 760f, 550f),
                panelWidth = 400f,
                panelHeight = 300f,
            )

        assertEquals(360f, offset.x)
        assertEquals(190f, offset.y)
    }

    @Test
    fun `top anchor falls below and every panel edge remains clear`() {
        val offset =
            assistOptionsPanelOffset(
                viewportWidth = 400f,
                viewportHeight = 800f,
                anchorBounds = Rect(2f, 20f, 50f, 70f),
                panelWidth = 376f,
                panelHeight = 500f,
            )

        assertEquals(12f, offset.x)
        assertEquals(80f, offset.y)
        assertTrue(offset.x + 376f <= 400f - 12f)
        assertTrue(offset.y + 500f <= 800f - 12f)
    }

    @Test
    fun `live panel closes when its anchor lifecycle is no longer interactive`() {
        val tools = listOf(AssistTool.LUT, AssistTool.WAVE)

        assertTrue(
            retainLiveAssistOptions(
                AssistTool.WAVE,
                tools,
                liveMode = true,
                locked = false,
                resumed = true,
            ),
        )
        assertFalse(
            retainLiveAssistOptions(AssistTool.WAVE, tools, true, locked = true, resumed = true),
        )
        assertFalse(
            retainLiveAssistOptions(
                AssistTool.WAVE,
                tools,
                liveMode = false,
                locked = false,
                resumed = true,
            ),
        )
        assertFalse(
            retainLiveAssistOptions(AssistTool.WAVE, tools, true, false, resumed = false),
        )
        assertFalse(
            retainLiveAssistOptions(
                AssistTool.WAVE,
                listOf(AssistTool.LUT),
                true,
                false,
                true,
            ),
        )
        assertFalse(retainLiveAssistOptions(AssistTool.AUDIO, tools, true, false, true))
    }
}
