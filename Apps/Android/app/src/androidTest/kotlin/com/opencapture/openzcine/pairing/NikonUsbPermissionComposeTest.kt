package com.opencapture.openzcine.pairing

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.AppIntegration
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.PairScreen
import com.opencapture.opencine.appkit.SavedCamerasStore
import com.opencapture.opencine.appkit.StoredString
import com.opencapture.opencine.nikon.NikonIntegration
import com.opencapture.opencine.nikon.UsbPtpOpenResult
import com.opencapture.openzcine.saveLandscapeEvidence
import com.opencapture.openzcine.settleLandscape
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.UsbPtpCameraSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED first-run pairing: in-memory state only, no app data or camera transport is opened. */
@RunWith(AndroidJUnit4::class)
class NikonUsbPermissionComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Before fun landscapeFixture() { compose.settleLandscape() }

    @Test
    fun permissionRowAllowsRetryThenBecomesASelectableSharedCamera() {
        val pending = UsbPtpCamera("SIMULATED", "SIMULATED ZR", UsbPtpCameraAccess.NEEDS_PERMISSION, null)
        var requests = 0
        val usb = object : UsbPtpCameraSource {
            override val cameras = MutableStateFlow(listOf(pending))
            override fun refresh() = Unit
            override fun requestPermission(camera: UsbPtpCamera) { requests++ }
            override fun open(camera: UsbPtpCamera): UsbPtpOpenResult = error("No camera opens in this test")
            override fun close() = Unit
        }
        val credentials = object : PairingCredentials {
            override var lastSsid: String? = null
            override fun passphrase(ssid: String): String? = null
            override fun save(ssid: String, passphrase: String) = Unit
        }
        val environment = PairingEnvironment(
            joinCameraAp = { _, _ -> false }, releaseCameraAp = {}, hotspotCameras = emptyFlow(),
            createSession = { error("No network session opens in this test") }, usbCameraSource = usb,
            createUsbSession = { error("No USB session opens in this test") }, credentials = credentials,
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val connector = SavedCameraConnector(environment, { false }, { false }, scope, { id, _ -> "$id" })
        val port = AppNikonConnectPort(
            { id, _ -> "$id" }, connector, { emptyList() }, { null }, onPaired = {}, onForget = {},
            onExplicitUsbReconnect = {}, scope = scope, offersDiagnostics = false,
        )
        lateinit var model: CamerasModel
        compose.runOnUiThread {
            port.sceneActive = true
            port.pageVisible = true
            model = CamerasModel(
                listOf(AppIntegration(NikonIntegration(port), nikonIntegrationSlots(connector, { emptyList() }, credentials, onScanAccessPoint = {}, onChooseConnection = {}))),
                SavedCamerasStore(object : StoredString {
                    private var value: String? = null
                    override fun read(): String? = value
                    override fun write(value: String) { this.value = value }
                }), scope,
            )
        }
        compose.setContent {
            MaterialTheme { PairScreen(model, onDone = {}, onDiagnostics = {}, onReportProblem = {}) }
        }
        compose.onNodeWithText("Continue").assertIsNotEnabled()
        compose.onNodeWithText("Allow").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("USB-C · allow Android camera access").assertIsDisplayed()
        compose.saveLandscapeEvidence("usb-consent-waiting")
        compose.onNodeWithText("Allow").performClick()
        compose.runOnIdle { assertEquals(1, requests); assertEquals(0, model.state.value.nearby.size) }
        compose.runOnUiThread { usb.cameras.value = listOf(pending.copy(access = UsbPtpCameraAccess.DENIED)) }
        compose.onNodeWithText("Allow").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("USB-C · access was denied").assertIsDisplayed()
        compose.saveLandscapeEvidence("usb-consent-denied")
        compose.onNodeWithText("Allow").performClick()
        compose.runOnIdle { assertEquals(2, requests) }

        compose.runOnUiThread {
            usb.cameras.value = listOf(pending.copy(access = UsbPtpCameraAccess.READY, hostKey = "usb:SIMULATED"))
        }
        compose.onNodeWithText("Allow").assertDoesNotExist()
        compose.onNodeWithText("SIMULATED ZR").performScrollTo().assertIsDisplayed().performClick()
        compose.onNodeWithText("Continue").assertIsEnabled()
        compose.saveLandscapeEvidence("usb-consent-ready")
        compose.runOnIdle { port.pageVisible = false; port.sceneActive = false; scope.cancel() }
    }
}
