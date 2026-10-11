package com.opencapture.openzcine.media

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonStillPhotoClassification
import com.opencapture.opencine.nikon.NikonStillPreviewStrategy
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import java.nio.file.Files
import java.nio.file.Path
import java.util.Comparator
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Closing the still viewer or the player returns to the same gallery: no relist, no Loading, the
 * scroll position kept (A4-03). Pocket and Insta present their covers over a live library; Z bumped
 * its reload key on close, which retired the library and rebuilt the grid at the top.
 * All content is SIMULATED metadata and four-byte stub files in an isolated cache bucket.
 */
@RunWith(AndroidJUnit4::class)
class GalleryCoverReturnMainActivityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val preferences = context.getSharedPreferences("openzcine.media-library", Context.MODE_PRIVATE)
    private val savedCameraStore = SharedPreferencesSavedCameraStore(context)
    private val cache = MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
    private val bucket = "SIMULATED-RETURN-${System.nanoTime()}"
    private var preferencesBaseline: Map<String, *>? = null
    private var savedCameraBaseline: List<SavedCameraRecord>? = null
    private var createdDirectory: Path? = null
    private var scenario: ActivityScenario<MainActivity>? = null
    private var originalIdleTimeout = 0L

    @Before
    fun openSeededGallery() {
        originalIdleTimeout = Configurator.getInstance().waitForIdleTimeout
        // The catalog's live frame clock never idles; read the tree as it is.
        Configurator.getInstance().waitForIdleTimeout = 0
        preferencesBaseline = preferences.all.toMap()
        savedCameraBaseline = savedCameraStore.records()
        val record = SavedCameraRecord(
            host = "simulated-return-fixture", cameraName = "SIMULATED return",
            transport = SavedCameraTransport.USB_C, lastSeenAtEpochMillis = 1, wifiSsid = null,
        )
        savedCameraStore.replace(listOf(record))
        // Odd rows are stills (photo viewer), even rows are proxies (player).
        val clips = (1..ROWS).map { number ->
            val still = number % 2 == 1
            NikonMediaClipRecord(
                handle = number.toLong(), storageId = 65_537, sizeBytes = 4,
                captureDate = "20261003T10%02d00".format(number), pixelWidth = 1_920, pixelHeight = 1_080,
                filename = name(number),
                contentKind = if (still) NikonMediaContentKind.STILL_PHOTO else NikonMediaContentKind.PLAYABLE_PROXY,
                stillPhoto = if (still) NikonStillPhotoClassification("JPEG", NikonStillPreviewStrategy.PROGRESSIVE) else null,
            )
        }
        val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        index.rememberCameraListing(bucket, clips)
        index.rememberCameraBucket(record.id, bucket, record.displayTitle)
        index.saveViewOptions(MediaLibraryViewOptions(
            source = MediaLibrarySource.CAMERA, layout = MonitorMediaLayout.LIST,
            sortOrder = MediaLibrarySortOrder.NAME, thumbnailSize = MonitorThumbnailSize.SMALL,
        ))
        clips.forEach { clip ->
            cache.openEntry(bucket, MediaCacheObjectIdentity(clip), clip.sizeBytes).apply {
                check(finalPath.parent.parent == cache.rootDirectory)
                createdDirectory = finalPath.parent
                append(0, byteArrayOf(1, 2, 3, 4))
                complete()
            }
        }
        scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        requireNotNull(device.wait(Until.findObject(By.desc("Media library")), TIMEOUT_MILLIS)).click()
        requireNotNull(device.wait(Until.findObject(By.descStartsWith(name(1))), TIMEOUT_MILLIS))
    }

    @After
    fun restoreFixtureState() {
        try { scenario?.close() } finally {
            Configurator.getInstance().waitForIdleTimeout = originalIdleTimeout
            savedCameraBaseline?.let(savedCameraStore::replace)
            preferencesBaseline?.let { saved ->
                val editor = preferences.edit().clear()
                saved.forEach { (key, value) ->
                    when (value) {
                        is String -> editor.putString(key, value)
                        is Boolean -> editor.putBoolean(key, value)
                        is Int -> editor.putInt(key, value)
                        is Long -> editor.putLong(key, value)
                        is Float -> editor.putFloat(key, value)
                        is Set<*> -> editor.putStringSet(key, value.map { requireNotNull(it as? String) }.toSet())
                        else -> error("Unsupported saved preference type for $key")
                    }
                }
                check(editor.commit())
            }
            createdDirectory?.let { directory ->
                check(directory.parent == cache.rootDirectory)
                if (Files.exists(directory)) Files.walk(directory).use { paths ->
                    paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                }
            }
        }
    }

    @Test
    fun closingThePhotoViewerKeepsTheGalleryAndItsScroll() = assertCoverReturn(still = true)

    @Test
    fun closingThePlayerKeepsTheGalleryAndItsScroll() = assertCoverReturn(still = false)

    private fun assertCoverReturn(still: Boolean) {
        scrollPastFirstRows()
        val before = visibleRows()
        assertFalse("The fixture must start scrolled away from the first row", name(1) in before)
        // A middle row: the first visible one can sit under the gallery's header.
        val target = before.filter { it.endsWith(if (still) ".JPG" else ".MOV") }.let { it.getOrNull(it.size / 2) }
            ?: error("No ${if (still) "still" else "clip"} row is visible in $before")
        requireNotNull(device.findObject(By.descStartsWith(target))).click()
        val back = device.wait(Until.findObject(By.desc("Back to media")), TIMEOUT_MILLIS)
        assertNotNull("The ${if (still) "photo viewer" else "player"} did not open over the gallery", back)
        back.click()
        assertTrue(device.wait(Until.gone(By.desc("Back to media")), TIMEOUT_MILLIS))
        // A relist retires the library and rebuilds the grid at the top a moment after the close.
        // Sample long enough to see it.
        val deadline = SystemClock.uptimeMillis() + HOLD_MILLIS
        while (SystemClock.uptimeMillis() < deadline) {
            assertEquals("The gallery relisted or lost its scroll after the cover closed", before, visibleRows())
            SystemClock.sleep(150)
        }
    }

    private fun scrollPastFirstRows() {
        repeat(3) {
            if (name(1) !in visibleRows()) return
            val list = requireNotNull(device.findObject(By.scrollable(true).hasDescendant(By.descStartsWith(PREFIX))))
            list.scroll(Direction.DOWN, 0.6f, 600)
            SystemClock.sleep(400)
        }
    }

    private fun visibleRows(): List<String> {
        repeat(20) {
            if (Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
            try {
                val rows = device.findObjects(By.descStartsWith(PREFIX))
                    .filter { !it.visibleBounds.isEmpty }
                    .map { it.contentDescription.substringBefore(",") }.distinct().sorted()
                if (rows.isNotEmpty()) return rows
            } catch (_: StaleObjectException) {
                // The next attempt reads the current rows.
            }
            SystemClock.sleep(20)
        }
        return emptyList()
    }

    private fun name(number: Int) = PREFIX + "%02d".format(number) + if (number % 2 == 1) ".JPG" else ".MOV"

    private companion object {
        const val PREFIX = "SIMULATED-RET-"
        const val ROWS = 40
        const val TIMEOUT_MILLIS = 15_000L
        const val HOLD_MILLIS = 3_000L
    }
}
