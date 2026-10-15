package com.opencapture.openzcine

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.openzcine.diagnostics.AndroidAppDiagnostics
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.frameio.frameioDeliveryController
import com.opencapture.openzcine.frameio.frameioArtifactPreparer
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.media.AndroidMediaGalleryGateway
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.opencine.appkit.MonitorDeliveryCoordinator
import com.opencapture.openzcine.media.NikonMediaDelivery
import com.opencapture.openzcine.media.MediaGalleryFailureInjection
import com.opencapture.openzcine.media.MediaLibraryIndex
import com.opencapture.openzcine.media.SharedPreferencesMediaLibraryPreferences
import com.opencapture.openzcine.multicam.MulticamCoordinator
import com.opencapture.openzcine.multicam.multicamDecoder
import com.opencapture.openzcine.multicam.multicamLink
import com.opencapture.openzcine.pairing.PairingScript
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import com.opencapture.openzcine.pairing.realPairingEnvironment
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext

/**
 * The activity-retained owners (OpenCine `retainedMonitorRoot`): the session on the monitor, the
 * scope its shared session and multicam members run in, the pairing environment that holds its
 * camera-AP binding and USB source, and the stores and deliveries. A recreated activity composes
 * over the same root, so the session survives; finishing the activity closes it.
 */
internal class AppRoot(
    context: Context,
    /** Debug demo feed (`zc.demo.feed`); created once per root. */
    val demo: Pair<CameraSession, LiveFrameSource?>?,
    /** Debug scripted pairing; created once per root. */
    val pairingScript: PairingScript?,
    diagnostics: AndroidAppDiagnostics,
    galleryFailure: MediaGalleryFailureInjection,
) : AutoCloseable {
    private val app = context.applicationContext
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var monitorSession by mutableStateOf(demo?.first)

    /**
     * The HDMI capture feed beside a capture-only session. Non-null exactly while the monitor is on
     * the HDMI path; closed (CameraX unbind) whenever the monitor exits.
     */
    var uvcSource by mutableStateOf<UvcFrameSource?>(null)

    /**
     * A monitor reached from a saved card retains that exact profile. Link settings may then leave
     * the monitor without guessing a topology or constructing a second session.
     */
    var activeSavedCamera by mutableStateOf<SavedCameraRecord?>(null)

    val shellSessions = NikonShellSessions(scope)
    val savedCameraStore = SharedPreferencesSavedCameraStore(app)

    /**
     * The app-private LUT library owns transient SAF import and Swift-packed render payloads. It is
     * deliberately process-local; only generated selections persist.
     */
    val lutLibrary = AndroidLutLibrary(app)
    val mediaCacheStore = MediaCacheStore(app.noBackupFilesDir.resolve("media-cache").toPath())
    val mediaLibraryIndex = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(app))
    val frameioController = frameioDeliveryController(app)

    // The root releases the delivery owners before their supplied scope.
    private val deliveryScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The shared delivery run survives gallery close and activity recreation. */
    val mediaDeliveryCoordinator = MonitorDeliveryCoordinator(deliveryScope)
    val mediaDelivery = NikonMediaDelivery(
        appContext = app,
        coordinator = mediaDeliveryCoordinator,
        frameio = frameioController,
        cacheStore = mediaCacheStore,
        galleryGateway = AndroidMediaGalleryGateway(app.contentResolver, galleryFailure),
        exporter = frameioArtifactPreparer(app, lutLibrary),
    )

    /**
     * Keeps the process-wide camera-AP binding alive while its handed-off session is active, and
     * USB attach/detach observed while a handed-off session is on the monitor.
     */
    val pairingEnvironment =
        pairingScript?.environment
            ?: realPairingEnvironment(app) { phase, detail ->
                if (phase == "connect.gate") {
                    diagnostics.recordConnectTrace(detail)
                    return@realPairingEnvironment
                }
                // Closed phase tokens only; free-form detail is discarded here.
                AndroidDiagnosticEvent.fromPhase(phase)?.let { diagnostics.record(it) }
            }

    /**
     * Multicam (NIKON-01): up to four bodies on the shared OpenCineMulticam engine, each on its own
     * saved-profile session beside the single-camera monitor.
     */
    val multicam =
        MulticamCoordinator(
            scope = scope,
            connect = { record -> withContext(Dispatchers.IO) { multicamLink(record, pairingEnvironment) } },
            decoder = ::multicamDecoder,
        )

    override fun close() {
        mediaDeliveryCoordinator.close()
        deliveryScope.cancel()
        pairingEnvironment.usbCameraSource?.close()
        scope.cancel()
    }
}
