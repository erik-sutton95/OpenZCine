package com.opencapture.openzcine

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.CompositionLocalProvider
import com.opencapture.opencine.appkit.LocalMonitorCaptureCommandEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.graphics.asAndroidBitmap
import android.graphics.Bitmap
import java.io.File
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** SIMULATED private host mounts the real dashboard route and shared independent row controls. */
class GroupedStabilizationComposeTest {
    @get:Rule val compose = createComposeRule()
    private var snapshot by mutableStateOf(values())
    private var enabled by mutableStateOf(true)
    private var sourceCurrent by mutableStateOf(true)
    private var authorityEnabled by mutableStateOf(true)
    private val writes = mutableListOf<Pair<CameraControl, String>>()

    @Test fun combinedTileOpensBothRowsAndWritesOnlyTheSelectedRequestWhilePending() {
        show()
        open()
        option(CameraControl.VIBRATION_REDUCTION, 2).assertIsSelected()
        option(CameraControl.ELECTRONIC_VR, 0).assertIsSelected()
        option(CameraControl.VIBRATION_REDUCTION, 0).performClick()
        compose.runOnIdle { assertEquals(listOf(CameraControl.VIBRATION_REDUCTION to "SPORT"), writes) }
        option(CameraControl.ELECTRONIC_VR, 1).performClick()
        compose.runOnIdle {
            assertEquals(listOf(CameraControl.VIBRATION_REDUCTION to "SPORT", CameraControl.ELECTRONIC_VR to "ON"), writes)
        }
        capture("grouped-supported")
    }

    @Test fun electronicOnlyAdmissionStillOpensWithMovieObservationAndReason() {
        snapshot = values(movieOptions = emptyList())
        show()
        open()
        compose.onNodeWithTag("monitor.independentSettings.VIBRATION_REDUCTION.current").assertTextEquals("ON")
        capture("grouped-unavailable")
        compose.onNodeWithTag("monitor.independentSettings.VIBRATION_REDUCTION.reason").assertExists()
        option(CameraControl.ELECTRONIC_VR, 1).performClick()
        compose.runOnIdle { assertEquals(listOf(CameraControl.ELECTRONIC_VR to "ON"), writes) }
    }

    @Test fun unlistedObservedTextIsVisibleWithoutInventingASelection() {
        snapshot = values().copy(vibrationReduction = "unlisted observation")
        show()
        open()
        compose.onNodeWithTag("monitor.independentSettings.VIBRATION_REDUCTION.current").assertTextEquals("unlisted observation")
        compose.runOnIdle { snapshot = values().copy(vibrationReduction = null) }
        compose.onNodeWithTag("monitor.independentSettings.VIBRATION_REDUCTION.current").assertDoesNotExist()
        compose.runOnIdle { snapshot = values() }
        option(CameraControl.VIBRATION_REDUCTION, 2).assertIsSelected()
        compose.onNodeWithTag("monitor.independentSettings.VIBRATION_REDUCTION.current").assertDoesNotExist()
        compose.runOnIdle { assertTrue(writes.isEmpty()) }
    }

    @Test fun currentSourceLockAndCodecChangesRefuseWithoutChangingTheOtherRow() {
        show()
        open()
        compose.runOnIdle { sourceCurrent = false }
        option(CameraControl.VIBRATION_REDUCTION, 0).performClick()
        compose.runOnIdle { assertTrue(writes.isEmpty()); sourceCurrent = true; enabled = false }
        option(CameraControl.ELECTRONIC_VR, 1).assertIsNotEnabled().performClick()
        compose.runOnIdle { assertTrue(writes.isEmpty()); enabled = true; authorityEnabled = false }
        option(CameraControl.VIBRATION_REDUCTION, 0).assertIsNotEnabled().performClick()
        compose.runOnIdle { assertTrue(writes.isEmpty()); authorityEnabled = true; snapshot = values(codec = "N-RAW") }
        option(CameraControl.ELECTRONIC_VR, 1).performClick()
        compose.runOnIdle { assertTrue(writes.isEmpty()) }
        option(CameraControl.VIBRATION_REDUCTION, 0).performClick()
        compose.runOnIdle { assertEquals(listOf(CameraControl.VIBRATION_REDUCTION to "SPORT"), writes) }
    }

    @Test fun openingClosingAndHiddenOrderRoundTripSendNoCameraWrites() {
        show()
        open()
        compose.onNodeWithText("Close SIMULATED panel").performClick()
        compose.runOnIdle {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val prefs = context.getSharedPreferences("SIMULATED.grouped-order", 0)
            try {
                val old = "ELECTRONIC_VR,STABILIZATION,MODE,ISO,SHUTTER,IRIS,WHITE_BALANCE,RESOLUTION_FRAMERATE,CODEC"
                prefs.edit().clear().putString("display.commandGrid.order.v1", old).commit()
                val store = commandTileOrderStore(prefs)
                assertEquals(old, prefs.getString("display.commandGrid.order.v1", null))
                val moved = moveCommandTile(store.load(), CommandTileKind.STABILIZATION, 2)
                assertEquals(CommandTileKind.ELECTRONIC_VR, moved[0])
                assertEquals(CommandTileKind.STABILIZATION, visibleCommandTileOrder(moved)[2])
                store.save(moved)
                assertEquals(moved, store.load())
                assertTrue(writes.isEmpty())
            } finally { prefs.edit().clear().commit() }
        }
    }

    private fun open() {
        compose.onNodeWithContentDescription("VR / e-VR:", substring = true, useUnmergedTree = true).performClick()
        compose.onNodeWithTag("monitor.independentSettings").assertExists()
        compose.runOnIdle { assertTrue(writes.isEmpty()) }
    }

    private fun option(control: CameraControl, index: Int) =
        compose.onNodeWithTag("monitor.independentSettings.$control.option.$index")

    private fun capture(name: String) {
        compose.onNodeWithTag("monitor.independentSettings").assertIsDisplayed()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, "SIMULATED-$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    private fun show() {
        val strings = InstrumentationRegistry.getInstrumentation().targetContext.resources.phoneStringResolver()
        compose.setContent {
            OpenZCineTheme {
                val presentation = commandDashboardPresentation(snapshot, CameraPropertyRefreshStatus.Ready,
                    CameraSessionState.Connected(CameraIdentity("SIMULATED", "SIMULATED", "group")),
                    CommandTileKind.entries.toList(), strings)
                var opened by androidx.compose.runtime.remember { mutableStateOf(false) }
                Column {
                    if (opened) {
                        CompositionLocalProvider(LocalMonitorCaptureCommandEnabled provides authorityEnabled) {
                        CommandStabilizationPanel(presentation.stabilization, enabled, { sourceCurrent }, null,
                            onSelect = { request, choice -> writes += request.control to choice }, onUnavailable = { _, _ -> })
                        }
                        Button(onClick = { opened = false }) { Text("Close SIMULATED panel") }
                    } else {
                        CommandDashboard(presentation, portrait = false, controlsEnabled = enabled,
                            pendingControl = CameraControl.ELECTRONIC_VR,
                            onOpenControl = { check(it is CommandStabilizationRequest); opened = true },
                            onMoveTile = { _, _ -> }, liveFps = "SIMULATED", signalBars = 0)
                    }
                }
            }
        }
    }

    private fun values(codec: String? = "H.265", movieOptions: List<String> = listOf("SPORT", "OFF", "ON")) =
        CameraPropertySnapshot(codec = codec, vibrationReduction = "ON", electronicVr = "OFF",
            controlCapabilities = CameraControlCapabilities(vibrationReduction = movieOptions, electronicVr = listOf("OFF", "ON")))
}
