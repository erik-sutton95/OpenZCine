package com.opencapture.openzcine.media

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.MediaCatalog
import com.opencapture.opencine.nikon.NikonMediaBrowseGateway
import com.opencapture.opencine.nikon.NikonMediaService
import com.opencapture.opencine.nikon.NikonMediaSourceIdentity
import com.opencapture.opencine.nikon.NikonMediaSourcePort
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** SIMULATED real producer, actual gallery lease and durable legacy index. */
class NikonMediaCatalogAdoptionTest {
    @Test fun galleryCapturesActualSourceRecordsBeforeSingleDurableCommit() = runTest {
        val port = Port()
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val owner = NikonMediaGalleryCatalog(source)
        val prefs = Preferences(); val index = MediaLibraryIndex(prefs)
        val checkpoint = index.beginCameraListing("SIMULATED")
        val browse = owner.open(); val cursor = browse.catalog()
        val delta = assertNotNull(cursor.next())
        val page = owner.capture(delta, MediaCatalog(), browse.binding)
        checkpoint.applyPage(page.additions, page.removals)
        assertEquals(0, prefs.writes)
        assertTrue(page.catalog.complete)
        owner.admit(browse.binding)
        checkpoint.commit(prunesUnlistedClips = true)
        assertEquals(listOf("Göteborg.MOV"), index.persistedClips("SIMULATED").map { it.filename })
        assertEquals(2, prefs.writes) // One catalog write plus first indexed-camera registration.
        owner.close()
        assertEquals(listOf(41L), port.cancelled)
        assertEquals(1, port.exits)
    }

    @Test fun retiredCapturedPageCannotReachActualCheckpointAndSuccessorSurvivesOldGallery() = runTest {
        val port = Port()
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val owner = NikonMediaGalleryCatalog(source)
        val prefs = Preferences(); val index = MediaLibraryIndex(prefs)
        val checkpoint = index.beginCameraListing("SIMULATED")
        val browse = owner.open(); val cursor = browse.catalog()
        val delta = assertNotNull(cursor.next())
        val page = owner.capture(delta, MediaCatalog(), browse.binding)
        port.epoch = port.epoch.next()
        assertFailsWith<CancellationException> {
            owner.admit(browse.binding)
            checkpoint.applyPage(page.additions, page.removals)
            checkpoint.commit()
        }
        assertEquals(0, prefs.writes)
        assertTrue(index.persistedClips("SIMULATED").isEmpty())
        val successor = NikonMediaGalleryCatalog(source); val next = successor.open()
        owner.close()
        assertTrue(source.isCurrent(next.binding))
        assertEquals(0, port.exits)
        val nextPage = successor.capture(assertNotNull(next.catalog().next()), MediaCatalog(), next.binding)
        assertEquals(listOf("Göteborg.MOV"), nextPage.clips.map { it.filename })
        successor.close()
        assertEquals(1, port.exits)
        assertEquals(listOf(41L, 42L), port.cancelled)
    }

    private class Preferences : MediaLibraryPreferences {
        val values = mutableMapOf<String, String>(); var writes = 0
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) {
            writes += 1; if (value == null) values.remove(key) else values[key] = value
        }
    }
    private class Port : NikonMediaSourcePort {
        val session = CameraSessionID(); val native = Any(); var epoch = ControlEpoch(1)
        override val cameraNamespace = "SIMULATED"
        val cancelled = mutableListOf<Long>(); var exits = 0; var handle = 40L
        override fun sourceIdentity() = NikonMediaSourceIdentity(native, 1, session, epoch)
        override fun gateway(source: NikonMediaSourceIdentity) = object : NikonMediaBrowseGateway {
            override fun begin(): String {
                handle += 1
                return "OZCMEDIASTART1\t$handle\nresult\tmediaBusy\nstorageSlotCount\t0"
            }
            override fun next(cursor: Long, maxObjects: Int): String =
                "OZCMEDIA2\t0\t1\t0\n7\t65537\t100\t20261004T120000\t1920\t1080\t0\t0\t1\tproxy\t\t\tGöteborg.MOV"
            override fun cancel(cursor: Long) { cancelled += cursor }
            override fun exit() { exits += 1 }
        }
    }
}
