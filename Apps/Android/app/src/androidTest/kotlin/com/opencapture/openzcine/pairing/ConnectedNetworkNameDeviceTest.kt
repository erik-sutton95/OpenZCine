package com.opencapture.openzcine.pairing

import android.Manifest
import android.content.Intent
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * With the location permission, the app reads the name of the Wi-Fi network the phone is on: what
 * names a router setup and what tells a camera's own access point apart (A4-40). The platform's
 * own answer (`cmd wifi status`, read with shell rights) is the expectation. Android names the
 * network only with location on and to an app in the foreground, as the app is when it asks.
 */
@RunWith(AndroidJUnit4::class)
class ConnectedNetworkNameDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Before
    fun allowLocation() {
        for (permission in listOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, permission)
        }
        shell("cmd location set-location-enabled true")
    }

    @Test
    fun readsTheJoinedWifiNetworksName() {
        val joined = joinedNetwork()
        assumeTrue("The device is not on Wi-Fi", joined != null)
        ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)).use {
            assertEquals(joined, ConnectedNetworkName.read(context))
        }
    }

    private fun joinedNetwork(): String? =
        Regex("connected to \"([^\"]+)\"").find(shell("cmd wifi status"))?.groupValues?.get(1)

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .bufferedReader()
            .use { it.readText() }
}
