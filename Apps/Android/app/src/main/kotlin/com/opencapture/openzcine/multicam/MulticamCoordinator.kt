package com.opencapture.openzcine.multicam

import com.opencapture.opencine.multicam.RecordAll
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import com.opencapture.opencine.appkit.MonitorCapturePresentation
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.opencine.appkit.MultiviewStageState
import com.opencapture.opencine.appkit.MultiviewStageLayout
import com.opencapture.monitorui.MultiviewArrangement
import com.opencapture.openzcine.monitorTimecodeLabel
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.multicam.EditorLeaseException
import com.opencapture.opencine.multicam.EditorLeases
import com.opencapture.opencine.multicam.MulticamGroup
import com.opencapture.opencine.multicam.MulticamSnapshot
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import com.opencapture.opencine.multicam.ResourceAdmission
import com.opencapture.opencine.multicam.AdmissionReason
import com.opencapture.opencine.multicam.ResourceBudget
import com.opencapture.opencine.multicam.ResourceClaim
import com.opencapture.opencine.multicam.ResourceRequest
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.NikonMulticamPolicy
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.LiveFrame
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.CoroutineContext
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/** One member's open link: its own Nikon session and that session's live frames. */
class MulticamLink(val session: CameraSession, val frames: Flow<LiveFrame>)

/**
 * Operator-facing multicam sentences, the same as iOS `MulticamCopy`. Never "sync" or "genlock":
 * a group press is coordinated dispatch with per-camera confirmation.
 */
object MulticamCopy {
    const val SESSION_FULL = "Multiview holds four cameras."
    const val ALREADY_MEMBER = "That camera is already on the stage."
    const val CAMERA_WIFI = "Camera Wi-Fi can't join Multiview."
    const val NOT_REACHABLE = "Not reachable."
    const val EMPTY_PICKER = "No other cameras reachable. Pair one, or plug USB-C / join the same network."
    const val COULDNT_CONNECT = "Couldn't connect"
    const val LOST_CONNECTION = "Connection lost"
    fun notApplied(setting: String): String = "$setting not applied"
}

/**
 * The app's saved-path adapter to the integration's qualification. Android records carry no
 * serial, so the same setup is refused here and the body serial is
 * checked again after connect from the session's identity. HDMI is not a saved Android setup, and
 * photography mode is unknown before connect (a member that is in it fails its record instead).
 */
private fun multicamQualification(
    record: SavedCameraRecord, reachable: Boolean, memberHosts: Collection<String>,
): MulticamQualification {
    if (record.host in memberHosts) {
        return MulticamQualification.Refused(MulticamQualificationRefusal.ALREADY_MEMBER)
    }
    val path = when (record.transport) {
        SavedCameraTransport.CAMERA_ACCESS_POINT -> RouteKind.CAMERA_ACCESS_POINT
        SavedCameraTransport.PHONE_HOTSPOT -> RouteKind.PHONE_HOTSPOT
        SavedCameraTransport.INFRASTRUCTURE -> RouteKind.INFRASTRUCTURE_NETWORK
        SavedCameraTransport.USB_C -> RouteKind.USB
    }
    return NikonMulticamPolicy.qualification(
        path, reachable, isPhotography = null, device = null, members = emptyList(),
    )
}

private fun qualificationCopy(reason: MulticamQualificationRefusal): String = when (reason) {
    MulticamQualificationRefusal.ALREADY_MEMBER -> MulticamCopy.ALREADY_MEMBER
    MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION -> MulticamCopy.CAMERA_WIFI
    MulticamQualificationRefusal.OPERATION_UNAVAILABLE -> "Movie mode only."
    MulticamQualificationRefusal.NOT_REACHABLE -> MulticamCopy.NOT_REACHABLE
}

sealed interface MemberStatus {
    data object Connecting : MemberStatus

    data object Live : MemberStatus

    data class Failed(val reason: String) : MemberStatus
}

/** One stage tile's camera. Each field is its own snapshot state so a frame recomposes one tile. */
class MulticamMember internal constructor(val slot: Int, val record: SavedCameraRecord) {
    val id = MonitorEntryID()
    var status by mutableStateOf<MemberStatus>(MemberStatus.Connecting)
        internal set
    var frame by mutableStateOf<ImageBitmap?>(null)
        internal set

    /** `HH:MM:SS` from the live-view header, null while the body reports no timecode. */
    var timecode by mutableStateOf<String?>(null)
        internal set

    /** Camera-reported; null until the camera says. */
    var recording by mutableStateOf<Boolean?>(null)
        internal set
    var recordingSinceMillis by mutableStateOf<Long?>(null)
        internal set
    var properties by mutableStateOf(CameraPropertySnapshot())
        internal set

    /** The last command that did not land on this camera, shown on its tile. */
    var note by mutableStateOf<String?>(null)
        internal set

    /** The body serial its session reported; the member identity. */
    internal var serial: String? = null
    internal var link: MulticamLink? = null
    internal var control: NikonOpenCineSession? = null
    internal var job: Job? = null

    /** This member's own picture and look; it publishes what the tile shows into [frame]. */
    val picture = MulticamPicture(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)) { frame = it }

    val displayName: String get() = record.customName?.takeIf { it.isNotBlank() } ?: record.cameraName
    val letter: String get() = listOf("A", "B", "C", "D")[slot.coerceIn(0, 3)]
    val isLive: Boolean get() = status == MemberStatus.Live
}

/**
 * OpenZCine multicam on the shared engine (Android twin of iOS `MulticamCoordinator`): up to four
 * Nikon bodies on four fixed tiles. OpenCineMulticam decides membership, group record targets,
 * per-camera results, editor leases and the qualified limit; each member is its own
 * `SwiftCoreCameraSession` (owner-keyed in the JNI facade) behind a `NikonOpenCineSession`.
 * Writes go through that session's readback-confirmed `applyControl`.
 */
class MulticamCoordinator(
    private val scope: CoroutineScope,
    /** Opens one member's own link (the saved-profile session factories). */
    private val connect: suspend (SavedCameraRecord) -> MulticamLink,
    /** A JPEG decoder per member feed (each keeps its own bitmap ring). */
    private val decoder: () -> (ByteArray) -> Bitmap? = { { null } },
    /** Where member frames decode, off the main thread in the app. */
    private val decodeContext: CoroutineContext = Dispatchers.Default,
    private val now: () -> Long = System::currentTimeMillis,
    /** A member's native look renderer; `null` when this device cannot render one (no LUT tool). */
    private val lookRenderer: (() -> MulticamLookRenderer)? = null,
    /** The operator's current single-camera look, which seeds each member's own selection. */
    private val operatorLook: () -> FeedLutSelection = { FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709) },
    /** The app's one stored-LUT library, for the per-member look list. */
    internal val lutLibrary: AndroidLutLibrary? = null,
) {
    var presented by mutableStateOf(false)
        private set
    val presentation = MultiviewStageState(TILES)
    var arrangement: MultiviewArrangement
        get() = presentation.layout.arrangement
        set(value) { presentation.layout = if (value == MultiviewArrangement.GRID) MultiviewStageLayout.GRID else MultiviewStageLayout.CENTER_STAGE }

    /** The selected tile; its member is the program camera. */
    var focusedSlot: Int
        get() = presentation.selected
        private set(value) { presentation.selected = value }
    val members = mutableStateListOf<MulticamMember>()
    var toast by mutableStateOf<String?>(null)
    var groupBusy by mutableStateOf(false)
        private set

    /** The member lent to the single-camera Live View, if any. */
    var lent by mutableStateOf<MonitorEntryID?>(null)
        private set

    /** Engine membership: members with a live control session, in tile order. */
    val group = MulticamGroup()
    private val leases = EditorLeases()

    fun member(id: MonitorEntryID): MulticamMember? = members.firstOrNull { it.id == id }

    fun memberAt(slot: Int): MulticamMember? = members.firstOrNull { it.slot == slot }

    val program: MulticamMember? get() = memberAt(focusedSlot)
    val anyRecording: Boolean get() = members.any { it.recording == true }
    val canRecord: Boolean get() = group.entries.isNotEmpty() && !groupBusy

    /** Whether [session] is a member's own link (lent or not): only the stage closes it. */
    fun owns(session: CameraSession?): Boolean = session != null && members.any { it.link?.session === session }

    /** The member whose link the monitor is showing, when [session] is one. */
    fun lentMember(session: CameraSession?): MulticamMember? =
        lent?.let(::member)?.takeIf { it.link?.session === session }

    fun begin() {
        end()
        presented = true
    }

    /** Closes every member link. Never stops a recording. */
    fun end() {
        closeCameraSettings()
        closeLookSettings()
        members.forEach(::stop)
        members.forEach { it.picture.retire() }
        members.clear()
        group.entries.map { it.id }.forEach(group::remove)
        leases.closeAll()
        lent = null
        groupBusy = false
        toast = null
        presented = false
    }

    // MARK: Adding cameras

    fun refusal(record: SavedCameraRecord, reachable: Boolean): String? =
        when (val reason = admission(record, reachable).firstOrNull()) {
            null -> null
            is AdmissionReason.IntegrationRefused -> qualificationCopy(reason.reason)
            AdmissionReason.QualificationUnknown -> "Multiview support is not known for this setup."
            else -> MulticamCopy.SESSION_FULL
        }

    fun add(record: SavedCameraRecord, reachable: Boolean, slot: Int? = null): MulticamMember? {
        refusal(record, reachable)?.let {
            toast = it
            return null
        }
        val taken = members.map { it.slot }.toSet()
        val target = slot?.takeIf { it !in taken } ?: (0 until TILES).firstOrNull { it !in taken }
        if (target == null) {
            toast = MulticamCopy.SESSION_FULL
            return null
        }
        val member = MulticamMember(target, record)
        if (program == null) focusedSlot = target
        members += member
        start(member)
        return member
    }

    fun retry(id: MonitorEntryID) {
        val member = member(id) ?: return
        stop(member)
        member.status = MemberStatus.Connecting
        member.note = null
        start(member)
    }

    /** Removes one camera and closes its link. Never stops its recording. */
    fun remove(id: MonitorEntryID) {
        val member = member(id) ?: return
        if (lent == id) lent = null
        stop(member)
        member.picture.retire()
        members.remove(member)
        if (member.slot == focusedSlot) members.minByOrNull { it.slot }?.let { focusedSlot = it.slot }
    }

    fun select(slot: Int) {
        if (cameraEditor?.member != memberAt(slot)?.id) closeCameraSettings()
        focusedSlot = slot
        memberAt(slot)?.id?.takeIf { group[it] != null }?.let(group::setStage)
    }

    // MARK: Group record (the shared RecordAll policy, plan rule and copy)

    /** Record all: stop when any member rolls, else start; refused while any member cannot record. */
    fun groupPlan(): RecordPlan = plan(group.entries.map { it.id })

    /** One camera's own start or stop (its tile menu). */
    fun plan(id: MonitorEntryID): RecordPlan = plan(listOf(id))

    /**
     * Runs [plan] in the coordinator's scope, so Live View replacing the stage does not cancel it.
     * [together]: Record all, which also reports one group line.
     */
    fun start(plan: RecordPlan, together: Boolean) {
        scope.launch { run(plan, together) }
    }

    suspend fun run(plan: RecordPlan, together: Boolean) {
        if (groupBusy) return
        groupBusy = true
        try {
            if (together) toast = RecordAll.progress(plan.direction)
            for (target in plan.targets) target.entries.forEach { member(it)?.note = RecordAll.WAITING }
            val result = RecordAll.run(plan, group, engineState(), sessionMap())
            if (result == null) {
                toast = RecordAll.CHANGED
                return
            }
            for (member in members) {
                val outcome = result.outcome(member.id, group) ?: continue
                RecordAll.note(outcome, plan.direction)?.let { member.note = it }
            }
            if (together) {
                val start = plan.direction == RecordDirection.START
                toast = RecordAll.summary(result, allMatch = members.all { it.recording == start })
            }
        } finally {
            groupBusy = false
        }
    }

    private fun plan(entries: List<MonitorEntryID>): RecordPlan =
        RecordAll.plan(entries, { member(it)?.recording == true }, group, engineState())

    // MARK: Camera values (that member's own readback-confirmed writes)

    fun descriptor(key: SettingKey, member: MulticamMember): SettingDescriptor? =
        member.control?.refresh()?.capabilities?.get(key)

    fun set(value: SettingValue, id: MonitorEntryID, label: String) {
        val member = member(id) ?: return
        val control = member.control ?: return
        scope.launch {
            val receipt = control.request(CameraCommandIntent.Set(value))
            val finished = if (receipt.isFinished) receipt else control.outcome(receipt.operation)
            member.note =
                when (finished?.stage) {
                    CommandStage.Confirmed, CommandStage.Failed(CommandFailure.SUPERSEDED) ->
                        member.note?.takeIf { it != MulticamCopy.notApplied(label) }
                    else -> MulticamCopy.notApplied(label)
                }
        }
    }

    // MARK: Borrowed settings editor

    /** The open camera editor, if any: one member's lease over its own session. */
    var cameraEditor by mutableStateOf<MulticamCameraEditor?>(null)
        private set

    /**
     * Slots whose live, unlent member can take a setting now: its session is ready with command
     * authority and describes at least one writable, available setting with bounded choices.
     */
    val cameraSettingsSlots: Set<Int>
        get() = members.mapNotNull { member ->
            if (!member.isLive || lent == member.id || member.link == null) return@mapNotNull null
            val snapshot = member.control?.refresh() ?: return@mapNotNull null
            if (snapshot.connection != ConnectionState.Ready) return@mapNotNull null
            if (snapshot.authority != ControlAuthority.Owner && snapshot.authority !is ControlAuthority.Lease) return@mapNotNull null
            member.slot.takeIf {
                multiviewEditableSettings.any { key ->
                    val descriptor = snapshot.capabilities[key] ?: return@any false
                    descriptor.access == SettingAccess.READ_WRITE && descriptor.availability == Availability.Available &&
                        MonitorCapturePresentation.choices(key, descriptor.domain).isNotEmpty()
                }
            }
        }.toSet()

    /** Opens the slot's member editor under a fresh engine lease, retiring any earlier one first. */
    fun openCameraSettings(slot: Int) {
        closeCameraSettings()
        closeLookSettings()
        if (slot !in cameraSettingsSlots) return
        val member = memberAt(slot) ?: return
        val source = member.control ?: return
        val owner = member.link?.session ?: return
        select(slot)
        val lease = try {
            leases.open(member.id, group, engineState())
        } catch (_: EditorLeaseException) {
            return
        }
        lateinit var editor: MulticamCameraEditor
        val session = MulticamEditorSession(source, owner) {
            // Main-side check at submission; the native gate reads only the editor's receipt.
            cameraEditor === editor && this@MulticamCoordinator.member(member.id) === member && member.control === source &&
                member.link?.session === owner && lent != member.id &&
                leases.refusal(lease, group, engineState()) == null
        }
        editor = MulticamCameraEditor(member.id, lease, session)
        cameraEditor = editor
    }

    /** Retires the editor and its lease. Never sends a command; recording is untouched. */
    fun closeCameraSettings() {
        val editor = cameraEditor ?: return
        cameraEditor = null
        editor.retire()
        leases.close(editor.member)
    }

    private fun closeEditorOf(member: MulticamMember) {
        // A bake still running for the old link or session can no longer publish.
        member.picture.invalidate()
        if (cameraEditor?.member == member.id) closeCameraSettings()
        if (lookSettingsSlot == member.slot) closeLookSettings()
    }

    // MARK: Per-member picture look (LUT)

    /** The member whose look options are open, if any. Transient, never persisted. */
    var lookSettingsSlot by mutableStateOf<Int?>(null)
        private set

    /** Slots whose live, unlent member has a native look renderer attached. */
    val pictureLUTSlots: Set<Int>
        get() = members.filter { it.isLive && lent != it.id && it.picture.renderCapable }.map { it.slot }.toSet()

    /** Whether any render-capable member shows its look, for the LUT tool state. */
    val lutOn: Boolean
        get() = members.any { it.slot in pictureLUTSlots && it.picture.lutEnabled }

    /** The group LUT tool: on for every capable member unless all already are, then off for all. */
    fun toggleLUT() {
        val capable = members.filter { it.slot in pictureLUTSlots }
        if (capable.isEmpty()) return
        val enabled = !capable.all { it.picture.lutEnabled }
        capable.forEach { it.picture.showLut(enabled) }
    }

    fun setLUTEnabled(id: MonitorEntryID, enabled: Boolean) {
        member(id)?.takeIf { it.slot in pictureLUTSlots }?.picture?.showLut(enabled)
    }

    fun setLUTSelection(id: MonitorEntryID, selection: FeedLutSelection) {
        member(id)?.takeIf { it.slot in pictureLUTSlots }?.picture?.select(selection)
    }

    fun openLookSettings(slot: Int) {
        closeCameraSettings()
        if (slot !in pictureLUTSlots) return
        select(slot)
        lookSettingsSlot = slot
    }

    fun closeLookSettings() {
        lookSettingsSlot = null
    }

    /** Gives the member its own renderer once its link is live. */
    internal fun attachPicture(member: MulticamMember) {
        member.picture.attach(scope, lookRenderer, operatorLook())
    }

    // MARK: Live View loan

    /**
     * Lends one member's open link to the single-camera monitor: its stage feed stops (the
     * monitor pumps the link now), it holds an editor lease and is busy for group plans. Returns
     * the session to show, or null when it cannot be lent.
     */
    fun lend(id: MonitorEntryID): CameraSession? {
        closeCameraSettings()
        closeLookSettings()
        if (lent != null) return null
        val member = member(id)?.takeIf { it.isLive } ?: return null
        val session = member.link?.session ?: return null
        try {
            leases.open(id, group, engineState())
        } catch (_: EditorLeaseException) {
            return null
        }
        member.job?.cancel()
        member.job = null
        lent = id
        return session
    }

    /**
     * The monitor stood down without disconnecting. The member resumes on the same session (same
     * engine session id, so earlier plans stay current); a session that dropped meanwhile fails
     * the tile with Retry.
     */
    fun reclaim() {
        val id = lent ?: return
        lent = null
        leases.close(id)
        val member = member(id) ?: return
        if (member.link?.session?.state?.value is CameraSessionState.Connected) {
            feed(member)
        } else {
            fail(member, MulticamCopy.LOST_CONNECTION)
        }
    }

    // MARK: Engine input

    fun engineState(): MulticamSnapshot =
        MulticamSnapshot(
            cameras = members.mapNotNull { it.control?.refresh() },
            busy = setOfNotNull(lent),
        )

    private fun sessionMap() =
        members.mapNotNull { member -> member.control?.let { it.id to (it as com.opencapture.opencine.core.CameraSession) } }
            .toMap()

    private fun admission(record: SavedCameraRecord, reachable: Boolean): List<AdmissionReason> {
        // ponytail: only USB interfaces are claimed; the engine-port qualified USB-C, router and
        // hotspot members together. Network conflicts join once a mix is device-tested.
        fun request(entry: MonitorEntryID, record: SavedCameraRecord) =
            ResourceRequest(
                entry,
                device = null,
                claims =
                    if (record.transport == SavedCameraTransport.USB_C) {
                        listOf(ResourceClaim.UsbInterface(record.host))
                    } else {
                        emptyList()
                    },
            )
        return ResourceAdmission.reasons(
            request(MonitorEntryID(), record),
            multicamQualification(record, reachable, members.map { it.record.host }),
            members.map { request(it.id, it.record) },
            BUDGET,
        )
    }

    // MARK: Member links and feeds

    private fun start(member: MulticamMember) {
        member.job =
            scope.launch {
                val link =
                    try {
                        connect(member.record).also { it.session.connect() }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        null
                    }
                if (member !in members) {
                    link?.let { closeLink(it) }
                    return@launch
                }
                val identity = (link?.session?.state?.value as? CameraSessionState.Connected)?.identity
                if (link == null || identity == null) {
                    link?.let { closeLink(it) }
                    member.status = MemberStatus.Failed(MulticamCopy.COULDNT_CONNECT)
                    return@launch
                }
                // The member is the body serial, checked here because Android records carry none:
                // one body never holds two stage links.
                val serial = identity.serialNumber.takeIf { it.isNotBlank() }
                if (serial != null && members.any { it !== member && it.serial == serial }) {
                    closeLink(link)
                    toast = MulticamCopy.ALREADY_MEMBER
                    remove(member.id)
                    return@launch
                }
                member.serial = serial
                member.link = link
                attach(member, link)
            }
    }

    private fun attach(member: MulticamMember, link: MulticamLink) {
        closeEditorOf(member)
        member.control?.closeNow(SessionCloseReason.REPLACED)
        val control = NikonOpenCineSession(link.session, scope)
        member.control = control
        val entry =
            MonitorEntryDescriptor(
                id = member.id,
                name = member.displayName,
                device = control.refresh().device,
                cameraSession = control.id,
                telemetry = TelemetrySource.CAMERA_SESSION,
                controlAuthority = ControlAuthority.Owner,
            )
        if (group[member.id] == null) {
            group.add(entry, group.entries.count { (member(it.id)?.slot ?: 0) < member.slot })
        } else {
            group.update(entry)
        }
        if (member.slot == focusedSlot) group.setStage(member.id)
        feed(member)
    }

    /** The member's stage feed: frames, header record state and timecode, polled properties. */
    private fun feed(member: MulticamMember) {
        val link = member.link ?: return
        member.job?.cancel()
        member.status = MemberStatus.Live
        member.note = null
        attachPicture(member)
        member.job =
            scope.launch {
                launch {
                    link.session.cameraProperties.collect { member.properties = it }
                }
                launch {
                    link.session.state.collect { state ->
                        if (state is CameraSessionState.Disconnected) fail(member, MulticamCopy.LOST_CONNECTION)
                    }
                }
                val decode = decoder()
                link.frames.conflate().collect { frame ->
                    if (frame.jpegData.isNotEmpty()) {
                        // An immutable copy: the decoder reuses its ring, while a look may still bake.
                        withContext(decodeContext) { decode(frame.jpegData)?.copy(Bitmap.Config.ARGB_8888, false) }
                            ?.let(member.picture::accept)
                    }
                    member.timecode =
                        monitorTimecodeLabel(frame.timecode)
                    member.recording = frame.isRecording
                    member.recordingSinceMillis =
                        if (frame.isRecording) member.recordingSinceMillis ?: now() else null
                }
            }
    }

    /** The tile keeps its camera with a Retry; the engine stops addressing it. */
    private fun fail(member: MulticamMember, reason: String) {
        if (member.status is MemberStatus.Failed) return
        closeEditorOf(member)
        member.status = MemberStatus.Failed(reason)
        member.recording = null
        member.control?.closeNow(SessionCloseReason.LINK_LOST)
        group.remove(member.id)
        val link = member.link
        member.link = null
        val job = member.job
        member.job = null
        scope.launch {
            link?.let { closeLink(it) }
            job?.cancel()
        }
    }

    private fun stop(member: MulticamMember) {
        closeEditorOf(member)
        member.job?.cancel()
        member.job = null
        member.control?.closeNow(SessionCloseReason.REQUESTED)
        group.remove(member.id)
        leases.close(member.id)
        val link = member.link
        member.link = null
        link?.let { scope.launch { closeLink(it) } }
    }

    /** CloseSession and sockets. Never a record command. */
    private suspend fun closeLink(link: MulticamLink) {
        withContext(NonCancellable) { link.session.disconnect() }
    }

    companion object {
        /** App qualification policy (the engine-port's tested product limit), not an engine constant. */
        val BUDGET = ResourceBudget(qualifiedEntries = 4)
        val TILES: Int = requireNotNull(BUDGET.qualifiedEntries) { "Multicam requires a finite app qualification budget" }
    }
}
