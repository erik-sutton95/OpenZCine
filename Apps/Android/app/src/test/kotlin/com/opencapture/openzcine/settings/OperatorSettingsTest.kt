package com.opencapture.openzcine.settings

import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.TestSharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OperatorSettingsTest {
    private val store = TestSharedPreferences()

    @Test
    fun `readouts default visible`() {
        val settings = OperatorSettings(store)
        assertTrue(settings.statusBarVisible.value)
        assertTrue(settings.assistToolbarVisible.value)
        assertTrue(settings.cameraValuesVisible.value)
        assertTrue(settings.recReadoutVisible.value)
        assertTrue(settings.codecReadoutVisible.value)
        assertTrue(settings.mediaReadoutVisible.value)
        assertTrue(settings.fpsReadoutVisible.value)
        assertTrue(settings.recordConfirmationEnabled.value)
        assertTrue(settings.hapticsEnabled.value)
        assertTrue(settings.keepScreenAwake.value)
        assertFalse(settings.ruleOfThirdsEnabled.value)
        assertFalse(settings.centerCrosshairEnabled.value)
        assertEquals(LocalFramingGuide.OFF, settings.framingGuide)
        assertEquals(LocalDesqueezePresentation.OFF, settings.desqueezePresentation)
    }

    @Test
    fun `toggle writes through and survives a reload`() {
        OperatorSettings(store).apply {
            fpsReadoutVisible.toggle()
        }
        val reloaded = OperatorSettings(store)
        assertEquals(false, reloaded.fpsReadoutVisible.value)
    }

    @Test
    fun `storage keys never collide`() {
        val keys = OperatorSettings(store).all.map { it.key }
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun `local monitor controls persist and drive the screen awake policy`() {
        OperatorSettings(store).apply {
            statusBarVisible.toggle()
            assistToolbarVisible.toggle()
            cameraValuesVisible.toggle()
            recordConfirmationEnabled.toggle()
            keepScreenAwake.toggle()
        }

        val restored = OperatorSettings(store)
        assertFalse(restored.statusBarVisible.value)
        assertFalse(restored.assistToolbarVisible.value)
        assertFalse(restored.cameraValuesVisible.value)
        assertFalse(restored.recordConfirmationEnabled.value)
        assertFalse(restored.shouldKeepScreenAwake(monitorPresented = true))
        assertFalse(restored.shouldKeepScreenAwake(monitorPresented = false))
    }

    @Test
    fun `assist toolbar visibility retains LUT and survives a reload`() {
        val settings = OperatorSettings(store)
        settings.toggleAssistToolbarToolVisibility(AssistTool.LUT)
        settings.toggleAssistToolbarToolVisibility(AssistTool.PEAK)

        assertTrue(settings.isAssistToolbarToolVisible(AssistTool.LUT))
        assertFalse(settings.isAssistToolbarToolVisible(AssistTool.PEAK))
        assertFalse(OperatorSettings(store).isAssistToolbarToolVisible(AssistTool.PEAK))
    }

    @Test
    fun `toolbar order reconciles malformed stored data and retains moves`() {
        store.edit()
            .putString("display.assistToolbar.order.v1", "VECTOR,UNKNOWN,VECTOR,LUT")
            .apply()

        val settings = OperatorSettings(store)
        assertEquals(AssistTool.VECTOR, settings.assistToolbarOrder.first())
        assertEquals(AssistTool.LUT, settings.assistToolbarOrder[1])
        assertEquals(AssistTool.entries.toSet(), settings.assistToolbarOrder.toSet())

        settings.moveAssistToolbarTool(AssistTool.LUT, direction = -1)
        assertEquals(AssistTool.LUT, OperatorSettings(store).assistToolbarOrder.first())
    }

    @Test
    fun `toolbar reset restores every currently supported tool`() {
        val settings = OperatorSettings(store)
        settings.toggleAssistToolbarToolVisibility(AssistTool.WAVE)
        settings.moveAssistToolbarTool(AssistTool.VECTOR, direction = -1)
        settings.resetAssistToolbarPreferences()

        assertEquals(AssistTool.entries.toList(), settings.assistToolbarOrder)
        assertEquals(AssistTool.entries.toList(), settings.visibleAssistToolbarTools)
    }

    @Test
    fun `local framing selection persists and remains separate from camera grid state`() {
        OperatorSettings(store).apply {
            ruleOfThirdsEnabled.value = true
            centerCrosshairEnabled.value = true
            framingGuide = LocalFramingGuide.CINEMA_239
            desqueezePresentation = LocalDesqueezePresentation.X165
        }

        val restored = OperatorSettings(store)
        assertTrue(restored.ruleOfThirdsEnabled.value)
        assertTrue(restored.centerCrosshairEnabled.value)
        assertEquals(LocalFramingGuide.CINEMA_239, restored.framingGuide)
        assertEquals(LocalDesqueezePresentation.X165, restored.desqueezePresentation)
        assertTrue(restored.localFramingAssistConfiguration.accessibilitySummary.contains("unchanged"))
    }

    @Test
    fun `malformed local framing selections safely fall back to off`() {
        store.edit()
            .putString("assist.local.framingGuide.v1", "NOT_A_GUIDE")
            .putString("assist.local.desqueezePresentation.v1", "NOT_A_PRESENTATION")
            .apply()

        val restored = OperatorSettings(store)
        assertEquals(LocalFramingGuide.OFF, restored.framingGuide)
        assertEquals(LocalDesqueezePresentation.OFF, restored.desqueezePresentation)
    }

    @Test
    fun `version text matches the iOS format`() {
        assertEquals("0.1.117 (42)", appVersionText("0.1.117", 42))
    }
}
