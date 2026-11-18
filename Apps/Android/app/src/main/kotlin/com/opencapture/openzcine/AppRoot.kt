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
import com.opencapture.openzcine.multicam.multicamLookRendererFactory
import com.opencapture.openzcine.multiview.ZCineMemberTransport
import com.opencapture.openzcine.multiview.ZCineMultiview
import com.opencapture.openzcine.multiview.ZCineMultiviewEnvironment
import com.opencapture.openzcine.transport.CameraListDiscovery
import com.opencapture.opencine.appkit.MultiviewStagePreferencesStore
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.NikonMemberTiming
import com.opencapture.opencine.nikon.NikonMultiview
import com.opencapture.opencine.nikon.NikonMultiviewLinkError
import com.opencapture.opencine.nikon.NikonMultiviewSavedSetup
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.platform.SharedWiFiPath
import com.opencapture.opencine.runtime.MonitorJpegFrameDecoder
import com.opencapture.openzcine.pairing.PairingScript
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import com.opencapture.openzcine.pairing.realPairingEnvironment
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map
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
     * Multiview (Plan 6): OpenCine's shared Multiview over up to four Z bodies, each on its own
     * saved-profile session beside the single-camera monitor. One per opened stage; null while
     * Multiview is closed.
     */
    var multiview by mutableStateOf<ZCineMultiview?>(null)
        private set
    private val multiviewDiscovery by lazy { CameraListDiscovery() }
    private val multiviewPath by lazy { SharedWiFiPath(app) }

    /**
     * Runs from a stage's close until its members' CloseSessions finished and the settle after them
     * passed (the ZR releases its PTP slot about 1.2 s after a close): the app's own single-camera
     * connect waits for it ([awaitMultiviewReleased]) so it never Inits a body a member just left.
     */
    private var multiviewRelease: Job? = null

    /**
     * Opens Multiview (the stage starts when its screen appears); an open stage stays as it is.
     * [environment] replaces the platform's for an instrumented test's scripted bodies.
     */
    fun openMultiview(environment: ZCineMultiviewEnvironment? = null): ZCineMultiview {
        multiview?.let { return it }
        val stage = ZCineMultiview(environment ?: multiviewEnvironment(), scope)
        stage.lendToLiveView = { slot, transport ->
            val host = NikonMultiview.address(stage.links[slot].host)
            activeSavedCamera = savedCameraStore.current.firstOrNull { NikonMultiview.address(it.host) == host }
            monitorSession = transport.session
            true
        }
        multiview = stage
        return stage
    }

    /**
     * The stage closed: every member link is closed (CloseSession, never a record command) and the
     * app's single-camera connect waits out the settle after those closes.
     */
    fun closeMultiview() {
        val stage = multiview ?: return
        multiview = null
        // The screen's close already stopped it; the app root's close (onCleared) has not.
        if (stage.coordinator.running) stage.coordinator.stop()
        val previous = multiviewRelease
        multiviewRelease = scope.launch {
            previous?.join()
            stage.links.forEach { it.awaitClosed() }
            delay(NikonMemberTiming.RECONNECT_SETTLE)
        }
        stage.dispose()
    }

    /** Waits until no Multiview member's close or settle is pending (see [multiviewRelease]). */
    suspend fun awaitMultiviewReleased() {
        multiviewRelease?.join()
    }

    private fun multiviewEnvironment() = ZCineMultiviewEnvironment(
        connect = { host -> connectMultiviewMember(host) },
        currentHolder = { host -> multiviewDiscovery.currentHolder(host) },
        sightings = { listened, saved, excluded -> multiviewDiscovery.multiviewSightings(listened, saved, excluded) },
        // The app's own NSD rows; the passive pass adds presence and saved-host liveness.
        listened = pairingEnvironment.hotspotCameras.map { rows ->
            rows.map { row ->
                if (row.isHeldByAnotherDevice) {
                    NikonSighting(row.host, row.name, NikonSighting.Source.HELD_BY_ANOTHER_DEVICE, row.heldByDeviceName)
                } else {
                    NikonSighting(row.host, row.name, NikonSighting.Source.NETWORK)
                }
            }
        },
        // Router and phone-hotspot setups only: USB-C and the camera's own Wi-Fi cannot share a network.
        saved = {
            savedCameraStore.current.filter { ZCineMultiview.joinsMultiview(it.transport) }.map {
                NikonMultiviewSavedSetup(it.host, it.customName?.takeIf(String::isNotBlank) ?: it.cameraName)
            }
        },
        hostPath = multiviewPath,
        decoder = {
            val decoder = MonitorJpegFrameDecoder(maxLongSide = TILE_LONG_SIDE)
            ({ jpeg -> decoder.decode(jpeg) })
        },
        lookRenderer = multicamLookRendererFactory(lutLibrary),
        presentationStore = MultiviewStagePreferencesStore(
            app.getSharedPreferences(ZCineMultiview.PRESENTATION_PREFERENCES, Context.MODE_PRIVATE),
            ZCineMultiview.PRESENTATION_KEY,
        ),
    )

    /**
     * A member's own strict saved-profile session at [host]; closed again when it does not connect. A
     * body that does not know this phone, or that another device took after the holder check, fails
     * with the link's operator copy ([NikonMultiviewLinkError.connectFailure]).
     */
    private suspend fun connectMultiviewMember(host: String): ZCineMemberTransport {
        val session = withContext(Dispatchers.IO) { pairingEnvironment.createSavedProfileSession(host) }
        try {
            session.connect()
            if (session.state.value !is CameraSessionState.Connected) {
                throw NikonMultiviewLinkError.connectFailure(session.connectionProgress.value.failure)
                    ?: IllegalStateException("Could not connect")
            }
        } catch (error: Throwable) {
            withContext(NonCancellable) { session.disconnect() }
            throw error
        }
        // Health needs frames of the current native stream only: the shared flow replays its last
        // frame to a new collector, which is not a new picture after a restart.
        val frames = ((session as? SwiftCoreCameraSession)?.liveFrames as? SwiftCoreLiveFrameSource)?.currentStreamFrames
            ?: (session as? SwiftCoreCameraSession)?.liveFrames?.frames
            ?: emptyFlow()
        return ZCineMemberTransport(session, frames)
    }

    override fun close() {
        closeMultiview()
        mediaDeliveryCoordinator.close()
        deliveryScope.cancel()
        pairingEnvironment.usbCameraSource?.close()
        scope.cancel()
    }
}

private const val TILE_LONG_SIDE = 960
