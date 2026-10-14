package com.opencapture.openzcine.media

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.NikonAssists
import com.opencapture.openzcine.frameio.frameioArtifactPreparer
import com.opencapture.openzcine.frameio.frameioDeliveryController
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.settings.OperatorSettings
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED absent catalog; actual Z playback composition and its return callback. */
@RunWith(AndroidJUnit4::class)
class GalleryOpeningAdmissionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun missingLibraryKeepsUnavailableCloseAndReturnsToGallery() = unavailable(libraryMissing = true)
    @Test fun missingCapturedRecordKeepsUnavailableCloseAndReturnsToGallery() = unavailable(libraryMissing = false)

    private fun unavailable(libraryMissing: Boolean) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = Files.createTempDirectory("SIMULATED-Z-opening-")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val preferences = "SIMULATED-Z-opening." + UUID.randomUUID()
        try {
            val cache = MediaCacheStore(root)
            val lut = AndroidLutLibrary(context)
            val delivery = NikonMediaDelivery(context, MonitorDeliveryCoordinator(scope),
                frameioDeliveryController(context), cache, AndroidMediaGalleryGateway(context.contentResolver),
                frameioArtifactPreparer(context, lut))
            val favorites = object : MonitorMediaFavoritesStore {
                override fun favorites(): Set<String> = emptySet()
                override fun saveFavorites(keys: Set<String>) = Unit
            }
            val codec = object : MonitorMediaCatalogCodec<NikonLibraryClip> {
                override fun decode(bytes: ByteArray): List<MonitorMediaRecord<NikonLibraryClip>> = emptyList()
                override fun encode(records: List<MonitorMediaRecord<NikonLibraryClip>>): ByteArray = "[]".toByteArray()
                override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<NikonLibraryClip> =
                    throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
            }
            val library = MonitorMediaLibraryModel(MonitorMediaCache(MonitorMediaCacheDirectory(root.toFile()), codec,
                MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")), favorites, scope = scope)
            val clip = NikonMediaClipRecord(handle = 1, storageId = 65_537, sizeBytes = 512,
                captureDate = "20261013T120000", pixelWidth = 1920, pixelHeight = 1080,
                filename = "SIMULATED-original.MOV", contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null)
            val assists = NikonAssists(MonitorAssistState(), FeedLutSelection.BuiltIn(FeedLut.MONO)) {}
            val settings = OperatorSettings(context.getSharedPreferences(preferences, Context.MODE_PRIVATE))
            var shown by mutableStateOf(true)
            compose.setContent {
                if (shown) MediaPlaybackScreen(cache, if (libraryMissing) null else library, emptyList(),
                    clip, listOf(clip), "SIMULATED-owner", cameraTransferAvailable = false,
                    connectionOwner = null, favoriteIDs = emptySet(), assists = assists,
                    exposureAssistCameraInput = ExposureAssistCameraInput(), operatorSettings = settings,
                    lutLibrary = lut, mediaDelivery = delivery, onToggleFavorite = {}, onClose = { shown = false })
                else Box { androidx.compose.material3.Text("SIMULATED gallery") }
            }
            compose.onNodeWithText("Media unavailable").assertIsDisplayed()
            compose.onNodeWithText("Close").performClick()
            compose.onNodeWithText("SIMULATED gallery").assertIsDisplayed()
        } finally {
            scope.cancel()
            context.deleteSharedPreferences(preferences)
            root.toFile().deleteRecursively()
        }
    }
}
