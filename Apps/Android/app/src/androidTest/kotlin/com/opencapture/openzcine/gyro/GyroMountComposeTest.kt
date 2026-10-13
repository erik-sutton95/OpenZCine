package com.opencapture.openzcine.gyro

import android.content.Context
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.bridge.SwiftCore
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GyroMountComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test fun coreMountSelectionIsDisplayedAndPersistsForTheNextLaunch() {
        assertTrue(SwiftCore.isAvailable)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("gyro-logging", Context.MODE_PRIVATE)
        val saved = preferences.getString("mountPreset", null)
        val enabled = preferences.getBoolean("enabled", false)
        preferences.edit().putString("mountPreset", "removed-preset").putBoolean("enabled", false).commit()
        val coordinator = GyroCaptureCoordinator(context)
        var reloaded: GyroCaptureCoordinator? = null
        var closed = false
        try {
            compose.setContent {
                val state by coordinator.state.collectAsState()
                GyroMountScreen(state, onSelect = coordinator::setMountPreset, onClose = { closed = true })
            }
            compose.waitUntil(10_000) { coordinator.state.value.mountOptions.isNotEmpty() }
            assertEquals("unconfigured", coordinator.state.value.mountPreset)
            compose.onNodeWithTag("gyro-mount-unconfigured").performScrollTo().assertIsSelected()
            val option = coordinator.state.value.mountOptions.firstOrNull { it.id == "rearLeft" }
            if (option == null) {
                assertEquals(listOf("unconfigured"), coordinator.state.value.mountOptions.map { it.id })
                compose.onAllNodesWithTag("gyro-mount-rearLeft").assertCountEquals(0)
                compose.onAllNodesWithTag("gyro-mount-frontUp").assertCountEquals(0)
                compose.onAllNodesWithText("Screen toward you").assertCountEquals(0)
                compose.onAllNodesWithText("Screen toward lens").assertCountEquals(0)
                assertTrue(runCatching { coordinator.setMountPreset("rearLeft") }.isFailure)
                compose.onNodeWithText("CLOSE").performClick()
                compose.runOnIdle { assertTrue(closed) }
                return
            }
            compose.onNodeWithTag("gyro-mount-${option.id}").performScrollTo().performClick()
            compose.waitUntil(5_000) { coordinator.state.value.mountPreset == option.id }
            compose.onNodeWithTag("gyro-mount-${option.id}").assertIsSelected()
            compose.onNodeWithText(option.detail).assertIsDisplayed()
            assertTrue(runCatching { coordinator.setMountPreset("unknown") }.isFailure)
            assertEquals(option.id, preferences.getString("mountPreset", null))
            val restored = GyroCaptureCoordinator(context)
            reloaded = restored
            compose.waitUntil(10_000) { restored.state.value.mountOptions.isNotEmpty() }
            assertEquals(option.id, restored.state.value.mountPreset)
            compose.onNodeWithText("CLOSE").performClick()
            compose.runOnIdle { assertTrue(closed) }
        } finally {
            coordinator.close()
            reloaded?.close()
            preferences.edit().putString("mountPreset", saved).putBoolean("enabled", enabled).commit()
        }
    }
}
