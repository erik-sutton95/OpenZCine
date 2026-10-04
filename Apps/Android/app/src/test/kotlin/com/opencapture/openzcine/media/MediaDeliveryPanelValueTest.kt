package com.opencapture.openzcine.media

import com.opencapture.openzcine.frameio.FrameioProject
import com.opencapture.openzcine.frameio.FrameioProjectListing
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MediaDeliveryPanelValueTest {
    @Test fun nativeDefaultsAndUnsupportedFactsStayDistinct() {
        val value = MediaDeliveryPanelValue.export(
            MediaDeliveryConfiguration(), null, MediaDeliveryDestination.NATIVE_SHARE,
        )
        assertFalse(value.bakeLUT!!.isOn)
        assertFalse(value.bakeLUT!!.enabled)
        assertEquals("MOV", value.format!!.selectedID)
        assertEquals(listOf("MOV", "MP4"), value.format!!.options.map { it.id })
        assertTrue(value.includeMetadata!!.isOn)
        assertNull(value.reupload)
        assertNull(value.filename)
        assertNull(value.convertLog)
        assertNull(value.outputCurve)
        assertNull(value.bakeExposure)
    }

    @Test fun frameioKeepsFormatReuploadAndExistingPostExportIdentifiers() {
        val value = MediaDeliveryPanelValue.export(
            MediaDeliveryConfiguration(), "SIMULATED LUT", MediaDeliveryDestination.FRAMEIO,
        )
        assertEquals("MOV", value.format!!.selectedID)
        assertFalse(value.reupload!!.isOn)
        assertEquals("SYSTEM_SHARE", MediaDeliveryPanelValue.postExport(MediaDeliveryPostExportAction.SYSTEM_SHARE).selectedID)
        assertEquals("SAVE_TO_PHOTOS", MediaDeliveryPanelValue.postExport(MediaDeliveryPostExportAction.SAVE_TO_PHOTOS).selectedID)
    }

    @Test fun unknownListingAndEightEligibleProjectsRetainOriginalAdmission() {
        assertNull(MediaDeliveryPanelValue.projects(null))
        val projects = (0..11).map { FrameioProject("SIMULATED/$it", "Project $it", "root/$it") }
        val listing = FrameioProjectListing("SIMULATED", "SIMULATED", "SIMULATED", listOf(
            FrameioProject("unavailable", "No root", null),
            FrameioProject("empty", "Empty root", ""),
        ) + projects)
        assertEquals(projects.take(8), MediaDeliveryPanelValue.projects(listing))
        assertEquals(emptyList(), MediaDeliveryPanelValue.projects(listing.copy(projects = emptyList())))
    }

    @Test fun knownDestinationOutsideEightChoicesDoesNotBecomeAnInventedNinthProject() {
        val projects = (0..11).map { FrameioProject("SIMULATED/$it", "Project $it", "root/$it") }
        val listing = FrameioProjectListing("SIMULATED", "SIMULATED", "SIMULATED", projects)
        val value = MediaDeliveryPanelValue.projectService(listing, "SIMULATED/10", "Known project 10", false, null)
        assertEquals(projects.take(8).map { it.id }, value.choices!!.map { it.id })
        assertEquals("Known project 10", value.selectedProjectLabel)
        assertFalse(value.allowsCreation)
        val listed = value.copy(selectedID = "SIMULATED/0", selectedLabel = "Stale label")
        assertEquals("Project 0", listed.selectedProjectLabel)
        val unknown = MediaDeliveryPanelValue.projectService(null, null, null, false, null)
        assertNull(unknown.choices)
        assertNull(unknown.selectedProjectLabel)
    }

    @Test fun sourceBatchWeightAndPreparingFactsAreNotRecomputedBySharedRendering() {
        val state = MediaDeliveryOverlayState(MediaDeliveryKind.FRAMEIO, 2, 2, 0.5)
        val value = state.monitorProgressValue()
        assertEquals(0.75, value.fraction)
        assertEquals("Clip 2 of 2", value.batch)
        assertEquals(state.statusLine, value.status)
        assertFalse(value.preparing)
        assertTrue(value.showsProgress)
        val preparing = state.copy(clipFraction = 0.0).monitorProgressValue()
        assertTrue(preparing.preparing)
        assertFalse(preparing.showsProgress)
    }
}
