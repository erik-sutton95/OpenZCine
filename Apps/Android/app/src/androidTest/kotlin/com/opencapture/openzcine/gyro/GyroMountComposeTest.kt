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
        val savedCalibration = preferences.getString("mountCalibration", null)
        val enabled = preferences.getBoolean("enabled", false)
        preferences.edit().putString("mountPreset", "removed-preset").remove("mountCalibration")
            .putBoolean("enabled", false).commit()
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
            preferences.edit().putString("mountPreset", saved).putString("mountCalibration", savedCalibration)
                .putBoolean("enabled", enabled).commit()
        }
    }

    @Test fun persistedCalibrationIsCoreValidatedAndManualSelectionClearsIt() {
        assertTrue(SwiftCore.isAvailable)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("gyro-logging", Context.MODE_PRIVATE)
        val saved = preferences.getString("mountPreset", null)
        val savedCalibration = preferences.getString("mountCalibration", null)
        val enabled = preferences.getBoolean("enabled", false)
        val verified = "{\"opaqueCoreValue\":1}"
        val native = object : GyroCalibrationNative {
            override fun validate(calibrationJSON: String): Boolean = calibrationJSON == verified
            override fun create(): String = error("No sensor session should start.")
            override fun add(owner: String, observationJSON: String): String? = error("Not used")
            override fun capture(owner: String, timestamp: Double): String? = error("Not used")
            override fun close(owner: String) = Unit
        }
        preferences.edit().putString("mountPreset", "unconfigured").putString("mountCalibration", verified)
            .putBoolean("enabled", false).commit()
        val coordinator = GyroCaptureCoordinator(context, calibrationNative = native)
        var invalid: GyroCaptureCoordinator? = null
        try {
            compose.waitUntil(10_000) { coordinator.state.value.mountOptions.isNotEmpty() }
            assertEquals(verified, coordinator.state.value.mountCalibration)
            coordinator.beginCalibration()
            compose.waitUntil(5_000) { coordinator.state.value.calibration.error != null }
            assertFalse(coordinator.state.value.calibration.active)
            assertEquals(verified, coordinator.state.value.mountCalibration)
            coordinator.setMountPreset("unconfigured")
            compose.waitUntil(5_000) { coordinator.state.value.mountCalibration == null }
            assertNull(preferences.getString("mountCalibration", null))
            preferences.edit().putString("mountCalibration", "invalid").commit()
            val restored = GyroCaptureCoordinator(context, calibrationNative = native)
            invalid = restored
            compose.waitUntil(10_000) { restored.state.value.mountOptions.isNotEmpty() }
            assertNull(restored.state.value.mountCalibration)
        } finally {
            coordinator.close(); invalid?.close()
            preferences.edit().putString("mountPreset", saved).putString("mountCalibration", savedCalibration)
                .putBoolean("enabled", enabled).commit()
        }
    }
}
