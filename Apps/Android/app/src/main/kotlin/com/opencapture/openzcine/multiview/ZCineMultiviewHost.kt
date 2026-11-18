package com.opencapture.openzcine.multiview

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorImagePreview
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.appkit.MonitorCaptureDrum
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MultiviewCameraSettingsState
import com.opencapture.opencine.appkit.MultiviewCoordinator
import com.opencapture.opencine.appkit.MultiviewJournalStorage
import com.opencapture.opencine.appkit.MultiviewMemberChange
import com.opencapture.opencine.appkit.MultiviewNetworkPath
import com.opencapture.opencine.appkit.MultiviewNetworkStorage
import com.opencapture.opencine.appkit.MultiviewReadout
import com.opencapture.opencine.appkit.MultiviewScreenHost
import com.opencapture.opencine.appkit.MultiviewSettingsCategory
import com.opencapture.opencine.appkit.MultiviewStagePreferencesStore
import com.opencapture.opencine.appkit.MultiviewTally
import com.opencapture.opencine.appkit.MultiviewTileReadings
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.appkit.cameraName
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.StationHostPath
import com.opencapture.opencine.media.storageReadout
import com.opencapture.opencine.multicam.ResourceBudget
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraShutterMode
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.NikonMemberOpener
import com.opencapture.opencine.nikon.NikonMovieTone
import com.opencapture.opencine.nikon.NikonMultiview
import com.opencapture.opencine.nikon.NikonMultiviewCamera
import com.opencapture.opencine.nikon.NikonMultiviewLink
import com.opencapture.opencine.nikon.NikonMultiviewSavedSetup
import com.opencapture.opencine.nikon.NikonMultiviewScanner
import com.opencapture.opencine.nikon.NikonMultiviewTransport
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.multicam.MulticamCameraEditor
import com.opencapture.openzcine.multicam.MulticamEditorSession
import com.opencapture.openzcine.multicam.MulticamLookRenderer
import com.opencapture.openzcine.multicam.MulticamPicture
import com.opencapture.openzcine.multicam.identifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.CoroutineContext
import kotlin.time.Duration

/**
 * One Multiview member's PTP session as the Nikon member link runs it: the app's own nikon session
 * (a `SwiftCoreCameraSession` with its own connection owner) and that session's live frames.
 */
class ZCineMemberTransport(
    override val session: CameraSession,
    override val frames: Flow<LiveFrame>,
) : NikonMultiviewTransport {
    override val serialNumber: String
        get() = (session.state.value as? CameraSessionState.Connected)?.identity?.serialNumber.orEmpty()

    /** CloseSession, then the sockets. Never a record command. */
    override suspend fun shutdown() {
        session.disconnect()
    }
}

/**
 * What the Multiview stage needs from the app and the platform, injected so the tests run it on
 * scripted bodies and virtual time. iOS twin: `ZCineMultiviewEnvironment`.
 */
class ZCineMultiviewEnvironment(
    /** Opens a PTP session to a picked host (Init, OpenSession, GetDeviceInfo); throws when none answers. */
    val connect: suspend (String) -> ZCineMemberTransport,
    /** The device serving a host now, from a fresh presence sweep (never a control-port dial). */
    val currentHolder: suspend (String) -> String?,
    /** One passive Add-list pass (`NikonDiscovery.multiviewSightings`) over the app's listened rows. */
    val sightings: suspend (listened: List<NikonSighting>, savedHosts: List<String>, excludedHosts: Set<String>) -> List<NikonSighting>,
    /** The app's own NSD rows, as they change, for [sightings]. */
    val listened: Flow<List<NikonSighting>> = emptyFlow(),
    /** The saved router and hotspot setups the Add list offers. */
    val saved: () -> List<NikonMultiviewSavedSetup>,
    val hostPath: StationHostPath,
    /** The coordinator's clock in milliseconds (record report freshness, take timing). */
    val clock: () -> Long = System::currentTimeMillis,
    val monotonic: () -> MonotonicInstant = { MonotonicInstant.now() },
    val sleep: suspend (Duration) -> Unit = { delay(it) },
    /** A JPEG decoder per tile (each keeps its own bitmap ring). */
    val decoder: () -> (ByteArray) -> Bitmap? = { { null } },
    /** Where tile frames decode, off the main thread in the app. */
    val decodeContext: CoroutineContext = Dispatchers.Default,
    /** A tile's native look renderer; null when this device cannot render one (no Auto LUT pixels). */
    val lookRenderer: (() -> MulticamLookRenderer)? = null,
    /** The pause after each frame for a tile (the program tile, or one of the others). */
    val framePace: (isProgram: Boolean) -> Duration = { Duration.ZERO },
    /** Where the stage's layout, selection and Fit/Fill live (ZCine's existing key). */
    val presentationStore: MultiviewStagePreferencesStore? = null,
)

/**
 * The app's half of the shared Multiview: one per opened stage. It builds the shared coordinator
 * over four Nikon member links (no commissioner: bodies are already on a router or this phone's
 * hotspot), keeps each tile's picture with its Auto LUT, the settings editor and the Live View loan,
 * and answers the shared screen ([MultiviewScreenHost]). iOS twin: `ZCineMultiview`.
 */
class ZCineMultiview(
    private val environment: ZCineMultiviewEnvironment,
    parent: CoroutineScope,
) : MultiviewScreenHost {
    private val scope = CoroutineScope(parent.coroutineContext + SupervisorJob(parent.coroutineContext[Job]))
    val links: List<NikonMultiviewLink<ZCineMemberTransport>>
    val coordinator: MultiviewCoordinator<NikonMultiviewCamera, NikonMultiviewLink<ZCineMemberTransport>>

    /** Each tile's picture: the newest frame, baked through its Auto LUT while that is on. */
    val pictures: List<MulticamPicture>
    private val shown = mutableStateListOf<ImageBitmap?>().apply { repeat(TILE_COUNT) { add(null) } }

    /** Bumps when a tile's readings change (at most twice a second for the timecode). */
    private val revisions = mutableStateListOf<Long>().apply { repeat(TILE_COUNT) { add(0L) } }
    private val decoders = List(TILE_COUNT) { environment.decoder() }
    private val pending = arrayOfNulls<ByteArray>(TILE_COUNT)
    private val decoding = BooleanArray(TILE_COUNT)
    private val attached = BooleanArray(TILE_COUNT)

    /** Each tile's camera model as GetDeviceInfo reported it on its current link (kept while it reconnects). */
    private val models = mutableStateListOf<String>().apply { repeat(TILE_COUNT) { add("") } }
    private var listenedNow: List<NikonSighting> = emptyList()
    private val listening: Job

    /** The open settings editor and its tile. */
    var editor: Pair<Int, MulticamCameraEditor>? by mutableStateOf(null)
        private set

    /** The open editor's last command note (a refusal or error), as Pocket's popup shows it. */
    var editorNote: String? by mutableStateOf(null)
        private set

    /** The tile lent to the single-camera Live View. */
    var lentSlot: Int? by mutableStateOf(null)
        private set
    private var liveExit: (() -> Unit)? = null

    /** The operator's record confirmation preference. */
    var recordConfirmation: () -> Boolean = { true }

    /** Lends [slot]'s session to the single-camera monitor; false when it could not open. */
    var lendToLiveView: (slot: Int, transport: ZCineMemberTransport) -> Boolean = { _, _ -> false }

    /** Ends the single-camera monitor's loan; the monitor then calls [returnFromLiveView]. */
    var endLiveView: () -> Unit = {}

    /** The stage stopped: the app drops this Multiview. */
    var stopped: () -> Unit = {}
    var logLine: (String) -> Unit = {}

    init {
        val opener = NikonMemberOpener<ZCineMemberTransport>(
            now = environment.monotonic,
            sleep = environment.sleep,
            currentHolder = environment.currentHolder,
            connect = environment.connect,
            serialNumber = { it.serialNumber },
            close = { it.shutdown() },
        )
        var owner: MultiviewCoordinator<NikonMultiviewCamera, NikonMultiviewLink<ZCineMemberTransport>>? = null
        links = List(TILE_COUNT) { slot ->
            NikonMultiviewLink(
                opener = opener,
                scope = scope,
                conversion = CONVERSION,
                now = environment.monotonic,
                wallClock = environment.clock,
                framePace = { environment.framePace(owner?.presentation?.selected == slot) },
            )
        }
        pictures = List(TILE_COUNT) { slot ->
            MulticamPicture(FeedLutSelection.BuiltIn(FeedLut.NLOG_709)) { shown[slot] = it }
        }
        val scanner = NikonMultiviewScanner(
            sightings = { saved, excluded -> environment.sightings(listenedNow, saved, excluded) },
            saved = environment.saved,
            excludedHosts = { memberHosts },
            sleep = environment.sleep,
        )
        coordinator = MultiviewCoordinator(
            links = links,
            policy = NikonMultiview.policy,
            commissioner = null,
            scanner = scanner,
            hostPath = environment.hostPath,
            describe = { it.record },
            // A stage without a network name is not a journal the shared validation keeps, and Nikon
            // needs no cleanup record: the layout persists through `presentation` below.
            journal = MultiviewJournalStorage(load = { null }, save = { true }),
            networks = MultiviewNetworkStorage(password = { _, _ -> null }, save = {}),
            scope = scope,
            budget = ResourceBudget(qualifiedEntries = TILE_COUNT),
            sightingAddress = { it.host },
            clock = environment.clock,
            monotonic = environment.monotonic,
            networkPath = MultiviewNetworkPath.EITHER,
        )
        owner = coordinator
        environment.presentationStore?.let { store -> coordinator.presentation.attachPersistence(store::load, store::save) }
        links.forEachIndexed { slot, link -> link.onFrame = { show(it, slot) } }
        coordinator.host = this
        listening = scope.launch { environment.listened.collect { listenedNow = it } }
    }

    /** Hosts members hold: the Add list never dials or lists them. */
    val memberHosts: Set<String>
        get() = coordinator.members.filter { it.camera != null }.map { it.address }.filter { it.isNotEmpty() }.toSet()

    /** The look [slot]'s Auto LUT applies now: its tone's look, or null when the tone needs none or is unknown. */
    fun autoLook(slot: Int): FeedLut? = links[slot].recordingTone?.let(::look)

    /** Whether [slot]'s tile shows its Auto LUT: the member's choice is on and its tone needs a look. */
    fun lutShown(slot: Int): Boolean = coordinator.members[slot].lutEnabled && autoLook(slot) != null

    /** [slot]'s tile picture, null while none decoded. */
    fun picture(slot: Int): ImageBitmap? = shown[slot]

    /** Whether [session] is a member's own (lent or not): only the stage closes it. */
    fun owns(session: CameraSession?): Boolean = session != null && links.any { it.transport?.session === session }

    /** The slot lent to Live View when [session] is its session. */
    fun lentSession(session: CameraSession?): Boolean =
        session != null && lentSlot?.let { links[it].transport?.session === session } == true

    private fun show(frame: LiveFrame, slot: Int) {
        if (!attached[slot]) {
            attached[slot] = true
            pictures[slot].attach(scope, environment.lookRenderer, FeedLutSelection.BuiltIn(FeedLut.NLOG_709))
        }
        applyLUT(slot)
        val model = links[slot].transport?.let { it.session.state.value as? CameraSessionState.Connected }?.identity?.model
        if (!model.isNullOrBlank() && models[slot] != model) models[slot] = model
        val stamp = environment.clock() / READINGS_REFRESH_MILLIS
        if (revisions[slot] != stamp) revisions[slot] = stamp
        if (frame.jpegData.isNotEmpty()) decode(slot, frame.jpegData)
    }

    /** The newest frame of a tile decodes next; at most one decode per tile runs. */
    private fun decode(slot: Int, jpeg: ByteArray) {
        pending[slot] = jpeg
        if (decoding[slot]) return
        decoding[slot] = true
        scope.launch {
            try {
                while (true) {
                    val next = pending[slot] ?: break
                    pending[slot] = null
                    // An immutable copy: the decoder reuses its ring while a look may still bake.
                    val bitmap = withContext(environment.decodeContext) {
                        decoders[slot](next)?.copy(Bitmap.Config.ARGB_8888, false)
                    }
                    if (bitmap != null && lentSlot != slot && links[slot].transport != null) pictures[slot].accept(bitmap)
                }
            } finally {
                decoding[slot] = false
            }
        }
    }

    /** The tile's Auto LUT: on while the member's choice is on and its tone needs a look. */
    private fun applyLUT(slot: Int) {
        val look = autoLook(slot)
        if (look != null) pictures[slot].select(FeedLutSelection.BuiltIn(look))
        pictures[slot].showLut(coordinator.members[slot].lutEnabled && look != null)
    }

    // Live View

    /**
     * The single-camera monitor stood down: the lent session (or the replacement its recovery opened,
     * null when lost) goes back to the tile, and the screen leaves Live View.
     */
    fun returnFromLiveView(transport: ZCineMemberTransport?) {
        val slot = lentSlot ?: return
        lentSlot = null
        links[slot].reclaim(transport)
        val exit = liveExit
        liveExit = null
        exit?.invoke()
    }

    /**
     * The app's monitor stood down without closing the session: the lent link goes back to its tile
     * while it is still connected; a session that dropped meanwhile returns nothing and the tile's
     * repair takes over.
     */
    fun returnLentSession() {
        val slot = lentSlot ?: return
        returnFromLiveView(links[slot].transport?.takeIf { it.session.state.value is CameraSessionState.Connected })
    }

    /** Final teardown after the stage closed; this Multiview is not reused. */
    fun dispose() {
        retireEditor()
        listening.cancel()
        scope.cancel()
    }

    // Settings editor

    private fun retireEditor() {
        val open = editor ?: return
        editor = null
        editorNote = null
        open.second.retire()
        coordinator.editorLeases.close(coordinator.members[open.first].entryID)
    }

    /** The settings the popup offers for this body: the ones it can write (no mode, color or audio). */
    private fun categories(slot: Int): List<MultiviewSettingsCategory> {
        val descriptors = links[slot].snapshot.capabilities.descriptors
        val result = mutableListOf(
            MultiviewSettingsCategory.ISO, MultiviewSettingsCategory.SHUTTER,
            MultiviewSettingsCategory.EXPOSURE, MultiviewSettingsCategory.WB,
        )
        if (SettingKey.FOCUS_MODE in descriptors) result += MultiviewSettingsCategory.FOCUS
        if (SettingKey.APERTURE in descriptors) result += MultiviewSettingsCategory.APERTURE
        result += MultiviewSettingsCategory.RESOLUTION
        return result
    }

    // MultiviewHost

    override val confirmsRecord: Boolean get() = recordConfirmation()

    override fun openLiveView(slot: Int): Boolean {
        if (lentSlot != null) return false
        val transport = links[slot].lend() ?: return false
        lentSlot = slot
        if (!lendToLiveView(slot, transport)) {
            lentSlot = null
            links[slot].reclaim(transport)
            return false
        }
        return true
    }

    override fun closeLiveView() {
        if (lentSlot != null) endLiveView()
    }

    override fun closeEditors() = retireEditor()

    override fun memberChanged(slot: Int, change: MultiviewMemberChange) {
        if (editor?.first == slot) retireEditor()
        if (change != MultiviewMemberChange.CONTROL) {
            // The previous camera's last frame never shows again (a LUT toggle re-bakes it).
            pictures[slot].clear()
            pending[slot] = null
            shown[slot] = null
            models[slot] = ""
        }
    }

    override fun stageStopped() {
        retireEditor()
        pictures.forEach { it.retire() }
        stopped()
    }

    override fun showsPicture(slot: Int): Boolean = lentSlot != slot

    override fun log(line: String) = logLine(line)

    override fun readings(slot: Int): MultiviewTileReadings? {
        val name = coordinator.cameraName(slot) ?: return null
        revisions[slot]
        val link = links[slot]
        val properties = link.reported
        val snapshot = link.snapshot
        val format = listOfNotNull(properties.resolution, properties.frameRate?.let { "${it}p" }, properties.codec)
            .joinToString(" · ")
        val timecode = link.timecode?.takeIf { it.on }?.let { MonitorTimecodeFormat.label(it.hour, it.minute, it.second) }
        val hasPicture = shown[slot] != null
        return MultiviewTileReadings(
            name = name,
            model = models[slot],
            format = format,
            storage = snapshot.storage.storageReadout?.free ?: MultiviewTally.UNAVAILABLE,
            timecode = timecode,
            readouts = readouts(properties),
            // The camera's own take length, as Pocket shows it: a Z body reports none, so the tally
            // reads REC (never a phone-derived count).
            recordingSeconds = null,
            power = snapshot.power,
            hasPicture = hasPicture,
            accessibilityValue = if (hasPicture) "Live" else "Waiting",
        )
    }

    override val editsCameraSettings: Boolean get() = true
    override val appliesAutoLUT: Boolean get() = true

    override fun lutChanged(slot: Int) = applyLUT(slot)

    override fun openCameraSettings(slot: Int) {
        retireEditor()
        val link = links[slot]
        val control = link.control ?: return
        val transport = link.transport ?: return
        if (link.lent) return
        val lease = coordinator.openEditorLease(slot) ?: return
        lateinit var opened: MulticamCameraEditor
        val session = MulticamEditorSession(control, transport.session) {
            editor?.second === opened && links[slot].control === control && coordinator.editorAdmits(lease, slot)
        }
        opened = MulticamCameraEditor(coordinator.members[slot].entryID, lease, session)
        editor = slot to opened
    }

    override fun cameraSettings(slot: Int): MultiviewCameraSettingsState? {
        val open = editor ?: return null
        if (open.first != slot || links[slot].control == null) return null
        return MultiviewCameraSettingsState(
            categories(slot), recording = links[slot].recordReport?.recording == true, note = editorNote,
        )
    }

    override fun admitsControls(slot: Int): Boolean =
        links[slot].transport != null && !links[slot].lent && lentSlot != slot

    override val pickerGuidance: String get() = PICKER_GUIDANCE

    // MultiviewScreenHost

    @Composable
    override fun Picture(slot: Int, fill: Boolean) {
        val image = shown[slot]
        if (lentSlot != slot && image != null) {
            Image(
                image, null, Modifier.fillMaxSize().testTag("multicam.tile.picture.$slot"),
                contentScale = if (fill) ContentScale.Crop else ContentScale.Fit,
            )
        }
    }

    @Composable
    override fun SettingsPreview(slot: Int, modifier: Modifier) {
        MonitorImagePreview(
            shown[slot], "${coordinator.cameraName(slot).orEmpty()} picture",
            modifier.testTag("multiview.settings.preview"),
        )
    }

    @Composable
    override fun SettingsControls(
        slot: Int,
        category: MultiviewSettingsCategory,
        locked: Boolean,
        maxHeight: Float,
        close: () -> Unit,
    ) {
        val open = editor?.takeIf { it.first == slot }
        if (open != null && category == MultiviewSettingsCategory.RESOLUTION) {
            RecordingFormat(slot)
            return
        }
        val key = settingKey(category)
        if (open == null || key == null) {
            Unavailable()
            return
        }
        val scope = rememberCoroutineScope()
        val control = remember(open.second) { MonitorControlModel(scope) }
        DisposableEffect(open.second, control) {
            control.onNote = { note -> if (editor === open) editorNote = note }
            control.bind(open.second.session)
            onDispose { control.unbind() }
        }
        val field = control.captureField(key)
        if (field == null) {
            Unavailable()
            return
        }
        MonitorCaptureDrum(
            control, field, enabled = !locked,
            modifier = Modifier.heightIn(max = maxHeight.dp).testTag("multiview.settings.${key.identifier}"),
        )
    }

    /**
     * The Format tab: the recording format as the body reports it. Nikon's common session writes no
     * movie format (resolution, frame rate and codec change on the camera), so the tab reads it back.
     */
    @Composable
    private fun RecordingFormat(slot: Int) {
        revisions[slot]
        val properties = links[slot].reported
        val rows = listOf(
            "Resolution" to properties.resolution,
            "Frame rate" to properties.frameRate?.let { "${it}p" },
            "Codec" to properties.codec,
            "Tone" to links[slot].recordingTone?.label,
        )
        Column(Modifier.fillMaxWidth().testTag("multiview.settings.format"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            for ((title, value) in rows) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(title, style = MonitorTypography.text(13f, FontWeight.Medium), color = MonitorPalette.muted)
                    Text(value ?: MultiviewTally.UNAVAILABLE, style = MonitorTypography.text(13f, FontWeight.Medium))
                }
            }
            Text(FORMAT_NOTE, style = MonitorTypography.text(12f, FontWeight.Normal), color = MonitorPalette.muted)
        }
    }

    @Composable
    private fun Unavailable() {
        Text(
            "Not available on this camera", style = MonitorTypography.text(13f, FontWeight.Medium),
            color = MonitorPalette.muted,
        )
    }

    /**
     * The lent tile's Live View is ZCine's one monitor, drawn by the app shell under the stage; the
     * shared screen hides the stage meanwhile. [exit] returns to the stage once the monitor stood down.
     */
    @Composable
    override fun LiveView(slot: Int, exit: () -> Unit) {
        SideEffect { liveExit = exit }
    }

    companion object {
        /** App qualification: four tiles (the engine-port's tested product limit). */
        const val TILE_COUNT: Int = 4

        /** The SharedPreferences file and key the previous multicam stage saved its layout under. */
        const val PRESENTATION_PREFERENCES: String = "multiview-presentation"
        const val PRESENTATION_KEY: String = "stage"

        private const val READINGS_REFRESH_MILLIS = 500L

        /** The Add camera list's setup steps: Z bodies join the network from their own menus. iOS twin: `pickerGuidance`. */
        const val PICKER_GUIDANCE: String =
            "On each camera: Network menu \u2192 Connect to computer, on this phone\u2019s Wi-Fi or hotspot. " +
                "A camera not yet paired with this phone: pair it in Your cameras first."

        /** Under the Format tab's values. iOS twin: `formatNote`. */
        const val FORMAT_NOTE: String = "Change the recording format on the camera."

        /** The look for a recording tone: N-Log and Log3G10 need theirs, SDR and HLG none. */
        fun look(tone: NikonMovieTone): FeedLut? = when (tone) {
            NikonMovieTone.N_LOG -> FeedLut.NLOG_709
            NikonMovieTone.LOG3G10 -> FeedLut.LOG3G10_709
            NikonMovieTone.SDR, NikonMovieTone.HLG -> null
        }

        /** The Auto LUT caption's conversion title for a tone. */
        val CONVERSION: (NikonMovieTone) -> String? = { look(it)?.label }

        /** The common setting a category's drum edits. */
        fun settingKey(category: MultiviewSettingsCategory): SettingKey? = when (category) {
            MultiviewSettingsCategory.ISO -> SettingKey.ISO
            MultiviewSettingsCategory.SHUTTER -> SettingKey.SHUTTER
            MultiviewSettingsCategory.EXPOSURE -> SettingKey.EXPOSURE_COMPENSATION
            MultiviewSettingsCategory.WB -> SettingKey.WHITE_BALANCE
            MultiviewSettingsCategory.FOCUS -> SettingKey.FOCUS_MODE
            MultiviewSettingsCategory.APERTURE -> SettingKey.APERTURE
            MultiviewSettingsCategory.RESOLUTION, MultiviewSettingsCategory.MODE, MultiviewSettingsCategory.COLOR,
            MultiviewSettingsCategory.AUDIO,
            -> null
        }

        /** ISO, shutter, white balance and focus as read back from the camera; unknown stays unknown. */
        fun readouts(properties: CameraPropertySnapshot): List<MultiviewReadout> {
            val shutter = if (properties.shutterMode == CameraShutterMode.SPEED) {
                properties.shutterSpeed ?: properties.shutterAngle
            } else {
                properties.shutterAngle ?: properties.shutterSpeed
            }
            return listOf(
                MultiviewReadout("ISO", properties.iso?.toString() ?: MultiviewTally.UNAVAILABLE),
                MultiviewReadout("SHUTTER", shutter ?: MultiviewTally.UNAVAILABLE),
                MultiviewReadout(
                    "WB",
                    properties.whiteBalanceKelvin?.let { "${it}K" } ?: properties.whiteBalanceMode ?: MultiviewTally.UNAVAILABLE,
                ),
                MultiviewReadout("FOCUS", properties.focusMode ?: MultiviewTally.UNAVAILABLE),
            )
        }

        /** Whether a saved setup may join Multiview: router and phone hotspot only (USB-C and camera Wi-Fi do not). */
        fun joinsMultiview(transport: com.opencapture.opencine.nikon.SavedCameraTransport): Boolean =
            transport == com.opencapture.opencine.nikon.SavedCameraTransport.INFRASTRUCTURE ||
                transport == com.opencapture.opencine.nikon.SavedCameraTransport.PHONE_HOTSPOT
    }
}
