package com.opencapture.openzcine

import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.cameracontrols.displaySections
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.nikon.NIKON_CAPTURE_PROFILE
import com.opencapture.opencine.vocabulary.CameraCaptureProfile
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.openzcine.core.MonitorDataAvailability
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertNull

/** The zoom chip and gimbal stick follow the Nikon control model (iOS `ControlCapabilityAdoptionTests`). */
class ControlCapabilityAdoptionTest {
    @Test fun beforeConnectionTheStaticProfileKeepsUnknownValues() {
        val controls = ControlCapabilities.beforeConnection(NIKON_CAPTURE_PROFILE)
        assertNull(controls.codecColor.offer)
        assertTrue(MonitorDisplaySection.COLOR in controls.displaySections)
        assertFalse(MonitorDisplaySection.ZOOM_CHIP in controls.displaySections)
        assertFalse(MonitorDisplaySection.GIMBAL_STICK in controls.displaySections)
    }

    @Test
    fun noZBodyOffersAZoomChipOrGimbalStick() {
        val controls = ControlCapabilities.derive(CapabilitySnapshot(), NIKON_CAPTURE_PROFILE)
        assertEquals(SupportStatus.UNSUPPORTED, controls.gimbal.support)
        assertEquals(SupportStatus.UNKNOWN, controls.zoom.support)
        val sections = MonitorDataAvailability.OWNING.monitorSections(cameraReportsTimecode = true,
            isPhotographyMode = false, controls = controls)
        assertFalse(MonitorDisplaySection.ZOOM_CHIP in sections)
        assertFalse(MonitorDisplaySection.GIMBAL_STICK in sections)
    }

    @Test
    fun aModelThatOffersZoomMountsTheChip() {
        val zoom = ControlCapabilities.derive(CapabilitySnapshot(), CameraCaptureProfile(supportsZoom = true))
        val sections = MonitorDataAvailability.OWNING.monitorSections(cameraReportsTimecode = true,
            isPhotographyMode = false, controls = zoom)
        assertTrue(MonitorDisplaySection.ZOOM_CHIP in sections)
        assertFalse(MonitorDisplaySection.GIMBAL_STICK in sections)
    }
}
