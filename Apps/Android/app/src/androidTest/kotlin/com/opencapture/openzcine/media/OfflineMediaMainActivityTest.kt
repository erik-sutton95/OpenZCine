package com.opencapture.openzcine.media

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.os.Environment
import android.provider.MediaStore
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import java.nio.file.Files
import java.nio.file.Path
import com.opencapture.opencine.appkit.MonitorMediaViewOptions
import com.opencapture.opencine.appkit.MonitorMediaCategoryFilter
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/** End-to-end device coverage for opening one completed cache with no camera session. */
@RunWith(AndroidJUnit4::class)
class OfflineMediaMainActivityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device: UiDevice = UiDevice.getInstance(instrumentation)
    private val savedCameraStore = SharedPreferencesSavedCameraStore(context)
    private val mediaPreferences =
        context.getSharedPreferences(MEDIA_PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val cameraBucketID = "$CAMERA_BUCKET_PREFIX-${System.nanoTime()}"
    private var scenario: ActivityScenario<MainActivity>? = null
    private var savedCameraBackup: List<SavedCameraRecord> = emptyList()
    private var mediaPreferencesBackup: Map<String, String> = emptyMap()
    private var createdFinalPath: Path? = null
    private var createdPartialPath: Path? = null

    @Before
    fun seedCompletedOfflineLibrary() {
        savedCameraBackup = savedCameraStore.records()
        mediaPreferencesBackup = mediaPreferences.stringSnapshot()

        val record =
            SavedCameraRecord(
                host = SAVED_CAMERA_ID,
                cameraName = "Offline Nikon ZR",
                transport = SavedCameraTransport.USB_C,
                lastSeenAtEpochMillis = 1L,
                wifiSsid = null,
            )
        savedCameraStore.replace(listOf(record))

        val clip =
            NikonMediaClipRecord(
                handle = 0xCAFE,
                storageId = 0x0001_0001,
                sizeBytes = 4,
                captureDate = "20260715T101010",
                pixelWidth = 1_920,
                pixelHeight = 1_080,
                filename = CACHED_FILENAME,
                contentKind = NikonMediaContentKind.PLAYABLE_PROXY,
                stillPhoto = null,
            )
        val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        index.rememberCameraListing(cameraBucketID, listOf(clip))
        index.rememberCameraBucket(record.id, cameraBucketID, record.displayTitle)

        val cacheStore =
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        cacheStore.openEntry(cameraBucketID, MediaCacheObjectIdentity(clip), clip.sizeBytes).apply {
            append(0, byteArrayOf(1, 2, 3, 4))
            complete()
            createdFinalPath = finalPath
            createdPartialPath = partialPath
        }
    }

    @After
    fun restoreAppState() {
        scenario?.close()
        scenario = null
        savedCameraStore.replace(savedCameraBackup)
        mediaPreferences.restoreStrings(mediaPreferencesBackup)
        listOfNotNull(createdFinalPath, createdPartialPath).forEach(Files::deleteIfExists)
        createdFinalPath?.parent?.let(Files::deleteIfExists)
    }

    @Test
    fun completedSavedCameraCacheOpensTheLocalLibraryWithoutASession() {
        scenario =
            ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )

        // The shared cameras header opens the same offline library without a session.
        val entry = device.waitForCamerasAction("Media library")
        saveDeviceScreenshot("openzcine-android-offline-media-startup.png")
        entry.click()

        assertNotNull(device.waitForText(CACHED_FILENAME))
        saveDeviceScreenshot("openzcine-android-offline-media-library.png")
    }

    @Test
    fun theCachedClipPlayerSharesThroughTheSharedDeliveryPopupAcrossRotation() {
        scenario =
            ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
        try {
            // A launch can replace the orientation the test host had, so set it after.
            device.setOrientationNatural()
            device.waitForOrientation(landscape = false)
            device.waitForCamerasAction("Media library").click()
            device.waitForText(CACHED_FILENAME).click()
            device.waitForDescription("Share clip").click()
            // The shared popup (A4-10), not a Z overlay, offers the native share destination.
            assertNotNull(device.waitForText("Nearby Share, Files, and other apps"))
            saveDeviceScreenshot("openzcine-android-delivery-popup-portrait.png")
            device.setOrientationLeft()
            device.waitForOrientation(landscape = true)
            assertNotNull(device.waitForText("Nearby Share, Files, and other apps"))
            saveDeviceScreenshot("openzcine-android-delivery-popup-landscape.png")
        } finally {
            device.setOrientationNatural()
        }
    }

    @Test
    fun malformedCompletedCacheReportsFailureInsteadOfWaitingForever() {
        scenario = ActivityScenario.launch(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        device.waitForCamerasAction("Media library").click()
        device.waitForText(CACHED_FILENAME).click()
        // The deliberately malformed four-byte fixture must reach Media3 and report its error.
        // An unopened offline library leaves the borrowed shared player preparing forever.
        assertNotNull(
            "The actual cached player must enter native preparation and publish its failure",
            // The app's failure copy replaces Media3's raw "Source error" message.
            device.wait(Until.findObject(By.textStartsWith("Couldn't play this camera proxy")), UI_TIMEOUT_MILLIS),
        )
    }

    @Test
    fun clearingStandaloneSettingsStillLeavesMediaLibraryEntryInCamerasHeader() {
        scenario =
            ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )

        assertNotNull(device.waitForCamerasAction("Media library"))
        device.waitForCamerasAction("Settings").click()
        device.waitForText("Operator Setup")
        device.revealSettingsTab("Storage").click()
        device.waitForText("Clear").click()
        // Clearing asks first on every app (A4-06); confirm inside the dialog's own window.
        var dialog: UiObject2 = device.wait(Until.findObject(By.text("Clear cache?")), UI_TIMEOUT_MILLIS)
            ?: throw AssertionError("Clearing the cache asks first")
        while (dialog.findObject(By.text("Clear")) == null) {
            dialog = dialog.parent ?: throw AssertionError("The clear dialog has no confirmation")
        }
        dialog.findObject(By.text("Clear")).click()
        assertNotNull(
            device.wait(
                Until.findObject(By.textStartsWith("Removed ")),
                UI_TIMEOUT_MILLIS,
            ),
        )

        device.pressBack()
        // The common cameras header keeps the entry point after clearing the cache.
        // Empty caches open an empty offline library.
        assertNotNull(device.waitForCamerasAction("Media library"))
    }

    @Test
    fun actualSharedMediaShellKeepsCategoriesLayoutAndDensityAcrossRotationAndRelaunch() {
        val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        val preferences = index.mediaPreferences("view-only")
        preferences.saveViewOptions(MonitorMediaViewOptions())
        try {
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
            device.waitForCamerasAction("Media library").click()
            device.setOrientationLeft()
            device.waitForDescription("Show Photos media").click()
            device.waitForIdle()
            assertEquals(MonitorMediaCategoryFilter.PHOTOS, preferences.viewOptions().category)
            device.waitForDescription("Show Videos media").click()
            assertNotNull(device.waitForText(CACHED_FILENAME))
            device.waitForDescription("List view").click()
            device.waitForIdle()
            assertEquals(MonitorMediaLayout.LIST, preferences.viewOptions().layout)
            device.waitForDescription("Grid view").click()
            for ((size, label) in MonitorThumbnailSize.entries.zip(listOf("Small", "Medium", "Large"))) {
                device.waitForDescription("$label thumbnails").click()
                device.waitForIdle()
                assertEquals(size, preferences.viewOptions().thumbnailSize)
            }
            device.setOrientationNatural()
            assertNotNull(device.waitForText(CACHED_FILENAME))
            device.waitForDescription("List view").click()
            device.waitForIdle()
            val retained = preferences.viewOptions()
            assertEquals(MonitorMediaCategoryFilter.VIDEOS, retained.category)
            assertEquals(MonitorMediaLayout.LIST, retained.layout)
            assertEquals(MonitorThumbnailSize.LARGE, retained.thumbnailSize)
            scenario?.close()
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
            device.waitForCamerasAction("Media library").click()
            assertNotNull(device.waitForText(CACHED_FILENAME))
            assertEquals(retained, preferences.viewOptions())
        } finally {
            device.setOrientationNatural()
            device.unfreezeRotation()
        }
    }

    private fun UiDevice.waitForText(text: String): UiObject2 =
        wait(Until.findObject(By.text(text)), UI_TIMEOUT_MILLIS)
            ?: throw AssertionError("Timed out waiting for text: $text")

    private fun UiDevice.revealSettingsTab(description: String): UiObject2 {
        repeat(8) {
            findObject(By.desc(description))?.let { tab ->
                val observedBounds = tab.visibleBounds
                waitForIdle()
                findObject(By.desc(description))?.let { current ->
                    if (current.visibleBounds == observedBounds) return current
                }
            }
            val rail = wait(
                Until.findObject(By.clazz("android.widget.HorizontalScrollView").scrollable(true)),
                UI_TIMEOUT_MILLIS,
            ) ?: throw AssertionError("The native settings tab rail is missing")
            val bounds = rail.visibleBounds
            val inset = bounds.width() / 10
            rail.setGestureMargins(inset, 0, inset, 0)
            // Native scroll holds before releasing its swipe, avoiding residual fling.
            rail.scroll(Direction.RIGHT, 0.8f, 600)
            waitForIdle()
        }
        return waitForDescription(description)
    }

    private fun UiDevice.waitForCamerasAction(description: String): UiObject2 {
        waitForDescription(description)
        check(wait(Until.gone(By.desc("OpenZCine")), UI_TIMEOUT_MILLIS)) {
            "The native startup splash still covers the cameras header"
        }
        waitForIdle()
        return waitForDescription(description)
    }

    private fun UiDevice.waitForOrientation(landscape: Boolean) {
        val deadline = System.currentTimeMillis() + UI_TIMEOUT_MILLIS
        while ((displayWidth > displayHeight) != landscape && System.currentTimeMillis() < deadline) waitForIdle()
        assertEquals(landscape, displayWidth > displayHeight)
        waitForIdle()
    }

    private fun UiDevice.waitForDescription(description: String): UiObject2 =
        wait(Until.findObject(By.desc(description)), UI_TIMEOUT_MILLIS)
            ?: throw AssertionError("Timed out waiting for description: $description")

    private fun SharedPreferences.stringSnapshot(): Map<String, String> =
        all.mapValues { (key, value) ->
            value as? String
                ?: throw AssertionError("Unexpected non-string media preference at $key")
        }

    private fun SharedPreferences.restoreStrings(snapshot: Map<String, String>) {
        edit().clear().apply {
            snapshot.forEach(::putString)
        }.commit()
    }

    private fun saveDeviceScreenshot(name: String) {
        if (InstrumentationRegistry.getArguments().getString(SCREENSHOT_ARGUMENT) != "true") return
        val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val values =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/OpenZCine-Android",
                )
            }
        val resolver = context.contentResolver
        val output =
            checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
        resolver.openOutputStream(output).use { stream ->
            checkNotNull(stream)
            check(screenshot.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        screenshot.recycle()
        println("ANDROID_OFFLINE_MEDIA_SCREENSHOT=$output")
    }

    private companion object {
        const val MEDIA_PREFERENCES_NAME = "openzcine.media-library"
        const val SAVED_CAMERA_ID = "offline-media-test-camera"
        const val CAMERA_BUCKET_PREFIX = "ZR-OFFLINE-MEDIA-TEST"
        const val CACHED_FILENAME = "OFFLINE_0001.MOV"
        const val SCREENSHOT_ARGUMENT = "offline-media-screenshot"
        const val UI_TIMEOUT_MILLIS = 10_000L
    }
}
