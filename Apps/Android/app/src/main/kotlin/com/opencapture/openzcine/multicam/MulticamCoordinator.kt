package com.opencapture.openzcine.multicam

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
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
import com.opencapture.opencine.multicam.ExclusionReason
import com.opencapture.opencine.multicam.MulticamGroup
import com.opencapture.opencine.multicam.MulticamSnapshot
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import com.opencapture.opencine.multicam.RecordSubmissionError
import com.opencapture.opencine.multicam.RecordSubmissionException
import com.opencapture.opencine.multicam.ResourceAdmission
import com.opencapture.opencine.multicam.AdmissionReason
import com.opencapture.opencine.multicam.ResourceBudget
import com.opencapture.opencine.multicam.ResourceClaim
import com.opencapture.opencine.multicam.ResourceRequest
import com.opencapture.opencine.multicam.TargetOutcome
import com.opencapture.opencine.multicam.TargetPolicy
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.NikonMulticamPolicy
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
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

/** One member's open link: its own Nikon session and that session's live frames. */
class MulticamLink(val session: CameraSession, val frames: Flow<LiveFrame>)

/**
 * Operator-facing multicam sentences, the same as iOS `MulticamCopy`. Never "sync" or "genlock":
 * a group press is coordinated dispatch with per-camera confirmation.
 */
object MulticamCopy {
    const val SESSION_FULL = "Multicam holds four cameras."
    const val ALREADY_MEMBER = "That camera is already on the stage."
    const val CAMERA_WIFI = "Camera Wi-Fi can't join a multicam session."
    const val NOT_REACHABLE = "Not reachable."
    const val EMPTY_PICKER = "No other cameras reachable. Pair one, or plug USB-C / join the same network."
    const val COULDNT_CONNECT = "Couldn't connect"
    const val LOST_CONNECTION = "Connection lost"
    const val COULDNT_REC = "Couldn't rec"
    const val CHANGED = "Cameras changed. Try again."

    fun confirm(direction: RecordDirection, names: List<String>): String =
        if (direction == RecordDirection.START) {
            "Start recording on ${names.joinToString(", ")}?"
        } else {
            "Stop recording on ${names.size} ${if (names.size == 1) "camera" else "cameras"}?"
        }

    /** `null` when every addressed camera rolls. */
    fun mixedStart(rolling: Int, total: Int, firstFailed: String): String? =
        if (rolling < total) "$rolling of $total rolling. $firstFailed didn't start." else null

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

    val displayName: String get() = record.customName?.takeIf { it.isNotBlank() } ?: record.cameraName
    val letter: String get() = listOf("A", "B", "C", "D")[slot.coerceIn(0, 3)]
    val isLive: Boolean get() = status == MemberStatus.Live
    val batteryReading: com.opencapture.opencine.core.BatteryReading? get() = control?.refresh()?.power?.batteryReading
    val batteryPercent: Int? get() = properties.batteryPercent?.takeIf { it in 0..100 }
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
    private val decoder: () -> (ByteArray) -> ImageBitmap? = { { null } },
    /** Where member frames decode, off the main thread in the app. */
    private val decodeContext: CoroutineContext = Dispatchers.Default,
    private val now: () -> Long = System::currentTimeMillis,
) {
    var presented by mutableStateOf(false)
        private set
    var arrangement by mutableStateOf(MultiviewArrangement.CENTER_STAGE)

    /** The selected tile; its member is the program camera. */
    var focusedSlot by mutableIntStateOf(0)
        private set
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
        arrangement = MultiviewArrangement.CENTER_STAGE
        focusedSlot = 0
    }

    /** Closes every member link. Never stops a recording. */
    fun end() {
        members.forEach(::stop)
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
            AdmissionReason.QualificationUnknown -> "Multicam support is not known for this setup."
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
        members.remove(member)
        if (member.slot == focusedSlot) members.minByOrNull { it.slot }?.let { focusedSlot = it.slot }
    }

    fun select(slot: Int) {
        focusedSlot = slot
        memberAt(slot)?.id?.takeIf { group[it] != null }?.let(group::setStage)
    }

    // MARK: Group record

    /** Group start (nothing rolling) or stop; Nikon keeps its eligible-subset default. */
    fun groupPlan(): RecordPlan = plan(group.entries.map { it.id })

    /** One camera's own start or stop (its tile menu, or a Couldn't rec retry). */
    fun plan(id: MonitorEntryID): RecordPlan = plan(listOf(id))

    fun names(plan: RecordPlan): List<String> =
        plan.targets.flatMap { it.entries }.mapNotNull { member(it)?.displayName }

    /** Runs [plan] in the coordinator's scope, so Live View replacing the stage does not cancel it. */
    fun start(plan: RecordPlan) {
        scope.launch { run(plan) }
    }

    suspend fun run(plan: RecordPlan) {
        if (groupBusy) return
        groupBusy = true
        try {
            val sessions = sessionMap()
            val submission =
                try {
                    plan.submit(group, engineState(), sessions)
                } catch (error: RecordSubmissionException) {
                    if (error.error == RecordSubmissionError.STALE) toast = MulticamCopy.CHANGED
                    return
                }
            apply(plan, submission.finished(sessions).outcomes)
        } finally {
            groupBusy = false
        }
    }

    private fun plan(entries: List<MonitorEntryID>): RecordPlan {
        val rolling = entries.any { member(it)?.recording == true }
        return RecordPlan.make(
            if (rolling) RecordDirection.STOP else RecordDirection.START,
            TargetPolicy.ELIGIBLE_SUBSET,
            entries,
            group,
            engineState(),
        )
    }

    private fun apply(plan: RecordPlan, outcomes: Map<com.opencapture.opencine.core.CameraSessionID, TargetOutcome>) {
        val failed = mutableListOf<MulticamMember>()
        for (target in plan.targets) {
            val confirmed = outcomes[target.session] == TargetOutcome.Confirmed
            for (id in target.entries) {
                val member = member(id)?.takeIf { it.control?.id == target.session } ?: continue
                member.note = if (confirmed) null else MulticamCopy.COULDNT_REC
                if (!confirmed) failed += member
            }
        }
        // Shown but not sent (no live view, closed link) did not start either; a lent camera is
        // simply in its Live View.
        val excluded =
            plan.exclusions.filter { it.reason != ExclusionReason.Busy }.mapNotNull { member(it.entry) }
        excluded.forEach { it.note = MulticamCopy.COULDNT_REC }
        if (plan.direction != RecordDirection.START) return
        val total = plan.targets.size + plan.satisfied.size + excluded.size
        val notRolling = failed + excluded
        notRolling.firstOrNull()?.let { first ->
            MulticamCopy.mixedStart(total - notRolling.size, total, first.displayName)?.let { toast = it }
        }
    }

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

    // MARK: Live View loan

    /**
     * Lends one member's open link to the single-camera monitor: its stage feed stops (the
     * monitor pumps the link now), it holds an editor lease and is busy for group plans. Returns
     * the session to show, or null when it cannot be lent.
     */
    fun lend(id: MonitorEntryID): CameraSession? {
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
                        withContext(decodeContext) { decode(frame.jpegData) }?.let { member.frame = it }
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
