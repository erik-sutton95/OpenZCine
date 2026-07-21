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
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import java.nio.file.Files
import java.nio.file.Path
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

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
            MediaClipRecord(
                handle = 0xCAFE,
                storageId = 0x0001_0001,
                sizeBytes = 4,
                captureDate = "20260715T101010",
                pixelWidth = 1_920,
                pixelHeight = 1_080,
                filename = CACHED_FILENAME,
                contentKind = MediaContentKind.PLAYABLE_PROXY,
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

        // iOS openCachedMediaLibrary: intro-card Media Library, not a per-row button.
        val entry = device.waitForText("Media Library")
        saveDeviceScreenshot("openzcine-android-offline-media-startup.png")
        entry.click()

        assertNotNull(device.waitForText(CACHED_FILENAME))
        saveDeviceScreenshot("openzcine-android-offline-media-library.png")
    }

    @Test
    fun clearingStandaloneSettingsStillLeavesMediaLibraryEntryOnIntroCard() {
        scenario =
            ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )

        assertNotNull(device.waitForText("Media Library"))
        device.waitForText("Settings").click()
        val clearAction =
            device.wait(
                Until.findObject(By.desc("Clear local media cache")),
                UI_TIMEOUT_MILLIS,
            ) ?: throw AssertionError("Timed out waiting for the clear-cache action")
        clearAction.click()
        device.waitForText("Clear cache").click()
        assertNotNull(
            device.wait(
                Until.findObject(By.textStartsWith("Removed ")),
                UI_TIMEOUT_MILLIS,
            ),
        )

        device.pressBack()
        // Intro Media Library remains (iOS always shows it); emptied caches open
        // an empty offline library instead of hiding the entry point.
        assertNotNull(device.waitForText("Media Library"))
    }

    private fun UiDevice.waitForText(text: String): UiObject2 =
        wait(Until.findObject(By.text(text)), UI_TIMEOUT_MILLIS)
            ?: throw AssertionError("Timed out waiting for text: $text")

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
