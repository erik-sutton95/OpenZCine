package com.opencapture.openzcine.media

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The offline gallery on the shared media host: its header names the camera (A4-30), cached clips
 * carry the shared source tag (A4-17), Back from the player returns to the gallery (A4-31), and the
 * camera set follows caches that complete after launch (A4-32). SIMULATED saved cameras and cache
 * bytes; the actual activity, shell and gallery.
 */
@RunWith(AndroidJUnit4::class)
class MediaHostMainActivityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device: UiDevice = UiDevice.getInstance(instrumentation)
    private val savedCameraStore = SharedPreferencesSavedCameraStore(context)
    private val mediaPreferences = context.getSharedPreferences("openzcine.media-library", Context.MODE_PRIVATE)
    private val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
    private val cacheStore = MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
    private val run = System.nanoTime()
    private val first = camera("media-host-a", "Host Nikon ZR", "MEDIA-HOST-A-$run", 0xCA01, "HOST_A_0001.MOV")
    private val second = camera("media-host-b", "Host Nikon Z6III", "MEDIA-HOST-B-$run", 0xCA02, "HOST_B_0001.MOV")
    private var scenario: ActivityScenario<MainActivity>? = null
    private var savedCameraBackup: List<SavedCameraRecord> = emptyList()
    private var mediaPreferencesBackup: Map<String, String> = emptyMap()
    private val created = mutableListOf<Path>()

    private class Camera(val record: SavedCameraRecord, val bucket: String, val clip: NikonMediaClipRecord)

    private fun camera(host: String, name: String, bucket: String, handle: Long, filename: String) = Camera(
        SavedCameraRecord(host = host, cameraName = name, transport = SavedCameraTransport.USB_C,
            lastSeenAtEpochMillis = 1L, wifiSsid = null),
        bucket,
        NikonMediaClipRecord(handle = handle, storageId = 0x0001_0001, sizeBytes = 4, captureDate = "20260715T101010",
            pixelWidth = 1_920, pixelHeight = 1_080, filename = filename,
            contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null),
    )

    @Before fun saveAppState() {
        savedCameraBackup = savedCameraStore.records()
        mediaPreferencesBackup = mediaPreferences.all.mapValues { (key, value) ->
            value as? String ?: throw AssertionError("Unexpected non-string media preference at $key")
        }
    }

    @After fun restoreAppState() {
        scenario?.close()
        scenario = null
        device.setOrientationNatural()
        device.unfreezeRotation()
        savedCameraStore.replace(savedCameraBackup)
        mediaPreferences.edit().clear().apply { mediaPreferencesBackup.forEach(::putString) }.commit()
        created.forEach(Files::deleteIfExists)
        created.mapNotNull { it.parent }.distinct().forEach(Files::deleteIfExists)
    }

    private fun register(vararg cameras: Camera) {
        savedCameraStore.replace(cameras.map { it.record })
        cameras.forEach {
            index.rememberCameraListing(it.bucket, listOf(it.clip))
            index.rememberCameraBucket(it.record.id, it.bucket, it.record.displayTitle)
        }
    }

    private fun complete(camera: Camera) {
        cacheStore.openEntry(camera.bucket, MediaCacheObjectIdentity(camera.clip), camera.clip.sizeBytes).apply {
            append(0, byteArrayOf(1, 2, 3, 4))
            complete()
            created.add(finalPath)
            created.add(partialPath)
        }
    }

    private fun launch() {
        scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
    }

    @Test fun offlineGalleryNamesItsCameraAndTagsCachedClips() {
        register(first)
        complete(first)
        launch()
        device.waitForCamerasAction("Media library").click()
        assertNotNull(device.waitForText(first.clip.filename))
        assertNotNull("The header names the camera", device.waitForText(first.record.displayTitle))
        assertNotNull("A cached clip carries the shared source tag", device.waitForText("CACHED"))
        screenshot("media-host-gallery-portrait")
        device.setOrientationLeft()
        assertNotNull(device.waitForText(first.clip.filename))
        assertNotNull(device.waitForText("CACHED"))
        screenshot("media-host-gallery-landscape")
    }

    @Test fun backFromThePlayerReturnsToTheGallery() {
        register(first)
        complete(first)
        launch()
        device.waitForCamerasAction("Media library").click()
        device.waitForText(first.clip.filename).click()
        assertNotNull(device.wait(Until.findObject(By.text("Source error")), UI_TIMEOUT_MILLIS))
        device.pressBack()
        assertTrue("Back closes the player", device.wait(Until.gone(By.text("Source error")), UI_TIMEOUT_MILLIS))
        assertNotNull("Back returns to the gallery", device.waitForText(first.clip.filename))
        assertTrue("Back does not close the gallery", device.findObject(By.desc("Media library")) == null)
    }

    @Test fun galleryOpenedAfterANewCacheCompletesListsEveryCamera() {
        register(first, second)
        complete(first)
        launch()
        device.waitForCamerasAction("Media library")
        complete(second)
        device.waitForCamerasAction("Media library").click()
        assertNotNull(device.waitForText(first.clip.filename))
        assertNotNull("Both completed caches show under All cameras", device.waitForText("All cameras"))
        assertNotNull(device.waitForText(second.clip.filename))
    }

    private fun UiDevice.waitForText(text: String): UiObject2 =
        wait(Until.findObject(By.text(text)), UI_TIMEOUT_MILLIS) ?: throw AssertionError("Timed out waiting for text: $text")

    private fun UiDevice.waitForCamerasAction(description: String): UiObject2 {
        wait(Until.findObject(By.desc(description)), UI_TIMEOUT_MILLIS)
        check(wait(Until.gone(By.desc("OpenZCine")), UI_TIMEOUT_MILLIS)) { "The native startup splash still covers the cameras header" }
        waitForIdle()
        return wait(Until.findObject(By.desc(description)), UI_TIMEOUT_MILLIS)
            ?: throw AssertionError("Timed out waiting for description: $description")
    }

    /** Evidence screenshots in the app's own external files, pulled by the emulator script. */
    private fun screenshot(name: String) {
        device.waitForIdle()
        val folder = File(context.getExternalFilesDir(null), "f16m").apply { mkdirs() }
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(folder, "$name.png").outputStream().use { check(image.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        image.recycle()
    }

    private companion object {
        const val UI_TIMEOUT_MILLIS = 10_000L
    }
}
