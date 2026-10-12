package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.Intent
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.PreferencesSnapshot
import com.opencapture.openzcine.R
import java.util.regex.Pattern
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Nothing saved (a fresh install, or every setup forgotten): the shared pair page is home and offers
 * Nikon's transport wizard in one tap, and Back from the wizard returns to that page (A4-01).
 */
@RunWith(AndroidJUnit4::class)
class FirstRunPairingEntryTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private var savedCameras: PreferencesSnapshot? = null
    private var scenario: ActivityScenario<MainActivity>? = null

    @Before
    fun forgetEverySavedCamera() {
        savedCameras = PreferencesSnapshot(context, CAMERAS_DOCUMENT_PREFERENCES, SharedPreferencesSavedCameraStore.PREFERENCES_NAME)
            .also { it.clear() }
    }

    @After
    fun restoreSavedCameras() {
        try { scenario?.close() } finally { savedCameras?.restore() }
    }

    @Test
    fun emptySavedListOffersTheTransportWizardOnThePairPage() {
        scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        val entry = context.getString(R.string.pairing_step_choose_path)
        val offered = device.wait(Until.findObject(By.desc(entry)), TIMEOUT_MILLIS)
        assertNotNull("The pair page offers no way to the Nikon transport wizard", offered)
        offered.click()
        // The wizard asks for its permissions first when they are missing, else shows the paths.
        val wizard = Pattern.compile(Pattern.quote(context.getString(R.string.pairing_step_permissions)) + "|" +
            Pattern.quote(context.getString(R.string.pairing_card_cable_link)))
        assertNotNull("One tap did not open the transport wizard", device.wait(Until.findObject(By.text(wizard)), TIMEOUT_MILLIS))

        device.pressBack()
        assertNotNull("Back left the app instead of returning to the pair page",
            device.wait(Until.findObject(By.desc(entry)), TIMEOUT_MILLIS))
        assertEquals(Lifecycle.State.RESUMED, requireNotNull(scenario).state)
    }

    private companion object {
        const val TIMEOUT_MILLIS = 15_000L
    }
}
