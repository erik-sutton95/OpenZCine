package com.opencapture.openzcine.pairing

import com.opencapture.opencine.appkit.StationSetupRoute
import com.opencapture.opencine.appkit.stationSetupChooser
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.openzcine.R
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * Add setup on Z is OpenCine's shared chooser (the one Pocket shows): this app supplies its
 * routes and their live action words, never its own sheet or copy. SIMULATED camera, no radio.
 */
class NikonAddSetupChooserTest {
    private val camera = SavedCamera(
        id = "zr", integration = IntegrationID("org.opencapture.nikon"), advertisedName = "ZR_6002199", model = "Nikon ZR",
        routes = emptyList(),
    )

    @Test fun `every missing kind is a route with its live action`() {
        val all = listOf(
            SavedCameraTransport.USB_C, SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.INFRASTRUCTURE, SavedCameraTransport.PHONE_HOTSPOT,
        )
        assertEquals(
            listOf(
                RouteKind.USB to R.string.saved_setup_connect_when_plugged,
                RouteKind.CAMERA_ACCESS_POINT to R.string.saved_setup_ap_action_scan,
                RouteKind.INFRASTRUCTURE_NETWORK to R.string.saved_setup_find_on_network,
                RouteKind.PHONE_HOTSPOT to R.string.saved_setup_wait_for_camera,
            ),
            nikonSetupActions(all, usbReady = false, routerFound = false, apKeyStored = false),
        )
        assertEquals(
            listOf(
                R.string.saved_setup_connect_now, R.string.saved_setup_ap_action_join,
                R.string.saved_setup_connect_now, R.string.saved_setup_wait_for_camera,
            ),
            nikonSetupActions(all, usbReady = true, routerFound = true, apKeyStored = true).map { it.second },
        )
    }

    @Test fun `the routes open the shared chooser in its order`() {
        val routes = nikonSetupActions(
            missingSetupKinds(emptyList()), usbReady = false, routerFound = false, apKeyStored = false,
        ).map { (kind, _) -> StationSetupRoute(kind) }
        val chooser = stationSetupChooser(camera, routes)
        assertEquals("How should this camera connect?", chooser.title)
        assertEquals(listOf("wifi", "phoneHotspot", "cameraAccessPoint", "usb"), chooser.options.map { it.id })
    }

    @Test fun `the setup words are sentence case with no em dash and no private sheet copy`() {
        val strings = File(System.getProperty("openzcine.repositoryRoot"))
            .resolve("Apps/Android/app/src/main/res/values/strings.xml").readText()
        val setup = Regex("""<string name="(saved_setup_[a-z_]+|saved_add_setup_[a-z_]+)">([^<]*)</string>""")
            .findAll(strings).associate { it.groupValues[1] to it.groupValues[2] }
        assertFalse(setup.keys.any { it.startsWith("saved_add_setup_") }, "the shared chooser owns the title")
        assertFalse(setup.values.any { it.contains('\u2014') }, "no em dash in setup copy")
        assertEquals("Connect when plugged in", setup["saved_setup_connect_when_plugged"])
    }
}
