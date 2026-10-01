package com.opencapture.openzcine.bridge

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.core.rejection
import com.opencapture.openzcine.IsoPickerPolicy
import com.opencapture.openzcine.WbPickerPolicy
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import com.opencapture.opencine.core.CameraSession as OpenCineCameraSession

/**
 * CORE-02 (OpenCine plan 13): the monitor's Nikon control [session] as an OpenCine
 * [OpenCineCameraSession] for movie ISO, white balance and explicit record start/stop. Same slice
 * and rules as the iOS `NikonCameraSession`.
 *
 * An adapter only. [session] keeps the one command path: its mutex-serialized writes, the Swift
 * core's encoding and its readback (`confirmAndroidControlWrites`). This class adds admission
 * against the Swift-authorized domains, receipts by [OperationID], camera-reported recording that
 * stays unknown until the camera says, and idempotent start/stop. Nothing here depends on a
 * picture source.
 */
internal class NikonOpenCineSession(
    private val session: CameraSession,
    private val scope: CoroutineScope,
    private val recordObservationTimeout: Duration = 5.seconds,
) : OpenCineCameraSession {
    override val id: CameraSessionID = CameraSessionID()
    private val lock = Any()
    private val started = TimeSource.Monotonic.markNow()
    private val attempt = ConnectionAttemptID()
    private val _snapshots =
        MutableStateFlow(
            CameraSnapshot(
                session = id,
                epoch = ControlEpoch(1),
                device = CameraDeviceID.provisional(INTEGRATION),
            ),
        )
    override val snapshots: StateFlow<CameraSnapshot> = _snapshots.asStateFlow()
    private val receipts = HashMap<OperationID, MutableStateFlow<CommandReceipt>>()

    /** Record targets in flight: not finished, so a newer press must follow, never be skipped. */
    private val recordTargets = HashMap<OperationID, Boolean>()
    private var wasReady = false
    private var everReady = false
    private var closed = false
    private val feed: Job

    init {
        refresh()
        feed =
            scope.launch {
                combine(session.state, session.cameraProperties, session.reportedRecording) { _, _, _ -> }
                    .collect { refresh() }
            }
    }

    private fun now(): MonotonicInstant = MonotonicInstant(started.elapsedNow())

    override suspend fun submit(command: CameraCommand): CommandReceipt {
        val operation = command.operation
        val start: Boolean?
        val controlWrite: Pair<CameraControl, String>?
        synchronized(lock) {
            receipts[operation]?.let { return it.value }
            val snapshot = refreshLocked()
            receipts[operation] =
                MutableStateFlow(
                    CommandReceipt(
                        operation,
                        id,
                        command.intent,
                        confirmation =
                            snapshot.capabilities[command.intent.key]?.semantics?.confirmation
                                ?: SettingSemantics.Confirmation.READBACK,
                    ),
                )
            snapshot.rejection(command, now())?.let {
                return transition(operation, CommandStage.Rejected(it))
            }
            transition(operation, CommandStage.Admitted)
            when (val intent = command.intent) {
                is CameraCommandIntent.Set -> {
                    controlWrite = writeLabel(intent.value)
                        ?: return transition(operation, CommandStage.Failed(CommandFailure.NOT_SENT))
                    start = null
                }
                CameraCommandIntent.StartRecording, CameraCommandIntent.StopRecording -> {
                    val target = intent == CameraCommandIntent.StartRecording
                    // Idempotent: a target the camera already reports is confirmed without a
                    // command, so a confirmed or retried press can never undo itself.
                    if (
                        recordTargets.isEmpty() &&
                        snapshot.recording.value == (if (target) RecordingState.RECORDING else RecordingState.IDLE)
                    ) {
                        return transition(operation, CommandStage.Confirmed)
                    }
                    recordTargets[operation] = target
                    controlWrite = null
                    start = target
                }
                // Not advertised, so admission already rejected it as unknown support.
                is CameraCommandIntent.FocusPoint ->
                    return transition(operation, CommandStage.Failed(CommandFailure.NOT_SENT))
            }
            transition(operation, CommandStage.Sent)
        }
        return if (controlWrite != null) {
            write(operation, controlWrite.first, controlWrite.second)
        } else {
            record(operation, start == true)
        }
    }

    override suspend fun outcome(operation: OperationID): CommandReceipt? {
        val receipt = synchronized(lock) { receipts[operation] } ?: return null
        return receipt.first { it.isFinished }
    }

    override fun receipt(operation: OperationID): CommandReceipt? = synchronized(lock) { receipts[operation]?.value }

    override suspend fun close(reason: SessionCloseReason): Unit = closeNow(reason)

    /** Never sends a command. */
    override fun closeNow(reason: SessionCloseReason) {
        synchronized(lock) {
            if (closed) return
            closed = true
            for (receipt in receipts.values) {
                val stage = receipt.value.stage
                if (!receipt.value.isFinished) {
                    receipt.value =
                        receipt.value.copy(
                            stage =
                                if (stage == CommandStage.Admitted) {
                                    CommandStage.Failed(CommandFailure.NOT_SENT)
                                } else {
                                    CommandStage.OutcomeUnknown
                                },
                        )
                }
            }
            recordTargets.clear()
            val current = _snapshots.value
            _snapshots.value =
                current.copy(
                    revision = current.revision.next(),
                    connection = ConnectionState.Disconnected(reason),
                    authority = ControlAuthority.Unavailable(UnavailableReason.Link),
                )
        }
        feed.cancel()
    }

    /** The operator acting on what the camera reports right now. */
    suspend fun request(intent: CameraCommandIntent): CommandReceipt =
        submit(CameraCommand(intent, CommandPreconditions(refresh())))

    /** The monitor's ISO or white-balance write, failing exactly like [CameraSession.applyControl]. */
    suspend fun applyControl(control: CameraControl, label: String) {
        val value = settingValue(control, label) ?: throw CameraControlException.UnsupportedSelection
        request(CameraCommandIntent.Set(value)).stage.controlFailure()?.let { throw it }
    }

    /** An explicit record start or stop, failing exactly like [CameraSession.setRecording]. */
    suspend fun setRecording(recording: Boolean) {
        val intent = if (recording) CameraCommandIntent.StartRecording else CameraCommandIntent.StopRecording
        request(intent).stage.recordingFailure()?.let { throw it }
    }

    /** Re-reads the camera facts, publishes a changed snapshot, and confirms reported records. */
    fun refresh(): CameraSnapshot = synchronized(lock) { refreshLocked() }

    private suspend fun write(operation: OperationID, control: CameraControl, label: String): CommandReceipt {
        val stage =
            try {
                session.applyControl(control, label)
                // The Swift core read every write back before returning.
                CommandStage.Confirmed
            } catch (error: CameraControlException) {
                error.toStage()
            } catch (cancelled: CancellationException) {
                finish(operation, CommandStage.OutcomeUnknown)
                throw cancelled
            }
        return finish(operation, stage)
    }

    private suspend fun record(operation: OperationID, start: Boolean): CommandReceipt {
        try {
            session.setRecording(start)
        } catch (error: CameraRecordingException) {
            return finish(operation, error.toStage())
        } catch (cancelled: CancellationException) {
            finish(operation, CommandStage.OutcomeUnknown)
            throw cancelled
        }
        synchronized(lock) {
            val receipt = receipts.getValue(operation)
            if (receipt.value.isFinished) return receipt.value
            // Accepted is not confirmed: wait for the camera to report the target.
            transition(operation, CommandStage.Accepted)
            transition(operation, CommandStage.AwaitingObservation)
            refreshLocked()
        }
        scope.launch {
            delay(recordObservationTimeout)
            synchronized(lock) {
                if (receipts[operation]?.value?.stage == CommandStage.AwaitingObservation) {
                    finishLocked(operation, CommandStage.TimedOut)
                }
            }
        }
        return synchronized(lock) { receipts.getValue(operation).value }
    }

    private fun finish(operation: OperationID, stage: CommandStage): CommandReceipt =
        synchronized(lock) { finishLocked(operation, stage) }

    private fun finishLocked(operation: OperationID, stage: CommandStage): CommandReceipt {
        recordTargets.remove(operation)
        val receipt = receipts.getValue(operation)
        // Close may have finished it already; its answer stands.
        if (receipt.value.isFinished) return receipt.value
        return transition(operation, stage)
    }

    private fun transition(operation: OperationID, stage: CommandStage): CommandReceipt {
        val receipt = receipts.getValue(operation)
        receipt.value = receipt.value.copy(stage = stage)
        return receipt.value
    }

    private fun refreshLocked(): CameraSnapshot {
        val current = _snapshots.value
        if (closed) return current
        val state = session.state.value
        val properties = session.cameraProperties.value
        val reported = session.reportedRecording.value
        val at = now()
        val ready = state is CameraSessionState.Connected
        // A replacement link is a new control epoch for the same owned session.
        val epoch = if (ready && !wasReady && everReady) current.epoch.next() else current.epoch
        wasReady = ready
        everReady = everReady || ready
        val descriptors = descriptors(properties, reported)
        val capabilities =
            if (CapabilitySnapshot(current.capabilities.revision, descriptors) == current.capabilities) {
                current.capabilities
            } else {
                CapabilitySnapshot(current.capabilities.revision.next(), descriptors)
            }
        val serial = (state as? CameraSessionState.Connected)?.identity?.serialNumber.orEmpty()
        val photography = properties.captureSelector.equals("photo", ignoreCase = true)
        var next =
            current.copy(
                epoch = epoch,
                device = if (serial.isEmpty()) current.device else CameraDeviceID.durable(serial, INTEGRATION),
                connection =
                    when {
                        ready -> ConnectionState.Ready
                        everReady -> ConnectionState.Recovering(attempt)
                        else -> ConnectionState.Connecting(attempt, ConnectionPhase.LINK)
                    },
                authority = if (ready) ControlAuthority.Owner else ControlAuthority.Unavailable(UnavailableReason.Link),
                capabilities = capabilities,
                mode = current.mode.observe(properties.captureSelector?.let { captureMode(photography) }, at),
                recording =
                    current.recording.observe(
                        reported?.let { if (it) RecordingState.RECORDING else RecordingState.IDLE },
                        at,
                    ),
                power =
                    current.power.copy(
                        battery =
                            current.power.battery.observe(
                                properties.batteryPercent?.let { it / 100.0 },
                                at,
                                ObservationPrecision.Quantized(0.01),
                            ),
                    ),
                settings =
                    reportedSettings(properties, photography)
                        .mapValues { (key, value) -> current.value(key).observe(value, at) }
                        .filterValues { it.isKnown },
            )
        if (next != current) {
            next = next.copy(revision = current.revision.next())
            _snapshots.value = next
        }
        for ((operation, target) in recordTargets.toMap()) {
            if (receipts[operation]?.value?.stage == CommandStage.AwaitingObservation &&
                next.recording.value == (if (target) RecordingState.RECORDING else RecordingState.IDLE)
            ) {
                finishLocked(operation, CommandStage.Confirmed)
            }
        }
        return next
    }

    internal companion object {
        val INTEGRATION: IntegrationID = IntegrationID("org.opencapture.nikon-ptp")

        /** The controls this slice owns; the monitor routes exactly these through the seam. */
        val CONTROLS: Set<CameraControl> = setOf(CameraControl.ISO, CameraControl.WHITE_BALANCE)

        /**
         * Movie ISO, white balance and record, admitting exactly what the Swift core's
         * `androidControlWrites` encodes and the monitor offers:
         * - ISO: the Swift-authorized ladder, the picker ladder (offered before descriptors land),
         *   and the camera's current value (Auto can park off the ladder, e.g. 51200).
         * - White balance: advertised presets (the picker's list while none are advertised) and
         *   the documented Kelvin range in 10 K steps whenever the body offers Kelvin.
         */
        fun descriptors(properties: CameraPropertySnapshot, reportedRecording: Boolean?): List<SettingDescriptor> {
            val codec = codec(properties)
            val isoLabels =
                properties.controlCapabilities.isoValues + IsoPickerPolicy.unifiedOptions +
                    listOfNotNull(properties.iso?.toString())
            val iso = isoLabels.distinct().mapNotNull { label -> settingValue(CameraControl.ISO, label) }
            val advertised = properties.controlCapabilities.whiteBalanceValues
            val kelvinOpen = advertised.isEmpty() || advertised.any(WbPickerPolicy::isKelvinLabel)
            val presets = if (advertised.isEmpty()) WbPickerPolicy.presetOptions else advertised
            val whiteBalance =
                SettingDomain(
                    choices = presets.mapNotNull { label -> settingValue(CameraControl.WHITE_BALANCE, label) },
                    range =
                        if (kelvinOpen) {
                            WbPickerPolicy.MINIMUM_KELVIN.toDouble()..WbPickerPolicy.MAXIMUM_KELVIN.toDouble()
                        } else {
                            null
                        },
                    step = if (kelvinOpen) WbPickerPolicy.FINE_STEP_KELVIN.toDouble() else null,
                )
            val isoAvailability =
                when {
                    // Photo chrome edits the stills ISO, a separate camera setting outside this slice.
                    properties.captureSelector.equals("photo", ignoreCase = true) ->
                        Availability.Unavailable(UnavailableReason.Mode)
                    !IsoPickerPolicy.allowsManualISO(codec, properties.exposureMode) ->
                        Availability.Unavailable(UnavailableReason.Mode)
                    IsoPickerPolicy.blocksISOChangeWhileRecording(codec, reportedRecording == true) ->
                        Availability.Unavailable(UnavailableReason.RecordingActive)
                    else -> Availability.Available
                }
            return listOf(
                SettingDescriptor(SettingKey.ISO, domain = SettingDomain(iso), availability = isoAvailability),
                SettingDescriptor(SettingKey.WHITE_BALANCE, domain = whiteBalance),
                SettingDescriptor(SettingKey.RECORDING),
            )
        }

        /** The common value for a monitor label, or `null` outside this slice. */
        fun settingValue(control: CameraControl, label: String): SettingValue? =
            when (control) {
                CameraControl.ISO -> label.trim().toIntOrNull()?.let { SettingValue.Iso(ISOValue.Manual(it)) }
                CameraControl.WHITE_BALANCE -> SettingValue.WhiteBalance(whiteBalance(label))
                else -> null
            }

        /** The control and label the Swift core takes for a common value. */
        fun writeLabel(value: SettingValue): Pair<CameraControl, String>? =
            when (value) {
                is SettingValue.Iso -> (value.value as? ISOValue.Manual)?.let { CameraControl.ISO to it.iso.toString() }
                is SettingValue.WhiteBalance ->
                    CameraControl.WHITE_BALANCE to
                        when (val balance = value.value) {
                            WhiteBalanceValue.Auto -> "Auto"
                            is WhiteBalanceValue.Preset -> balance.id
                            is WhiteBalanceValue.Kelvin -> "${balance.kelvin}K"
                        }
                else -> null
            }

        private fun whiteBalance(label: String): WhiteBalanceValue {
            val trimmed = label.trim()
            val kelvin = trimmed.removeSuffix("K").takeIf { it != trimmed }?.toIntOrNull()
            if (kelvin != null) return WhiteBalanceValue.Kelvin(kelvin)
            return if (trimmed == "Auto") WhiteBalanceValue.Auto else WhiteBalanceValue.Preset(trimmed)
        }

        private fun codec(properties: CameraPropertySnapshot): String =
            // The monitor's "no value" placeholder (U+2014), as in MonitorScreen.
            (properties.codecSelection ?: properties.codec)?.takeIf { it != "\u2014" }.orEmpty()

        private fun reportedSettings(
            properties: CameraPropertySnapshot,
            photography: Boolean,
        ): Map<SettingKey, SettingValue?> {
            val iso =
                when {
                    // Photo chrome reports the stills ISO, not this slice's movie ISO.
                    photography -> null
                    IsoPickerPolicy.isAutoISOActive(properties.isoAuto, codec(properties)) ->
                        SettingValue.Iso(ISOValue.Auto)
                    else -> properties.iso?.let { SettingValue.Iso(ISOValue.Manual(it.toInt())) }
                }
            val mode = properties.activeWhiteBalanceMode(photography)
            val whiteBalance =
                if (mode == "Color temp") {
                    properties.whiteBalanceKelvin?.let { SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(it)) }
                } else {
                    mode?.let { SettingValue.WhiteBalance(whiteBalance(it)) }
                }
            return mapOf(SettingKey.ISO to iso, SettingKey.WHITE_BALANCE to whiteBalance)
        }

        private fun captureMode(photography: Boolean): CaptureMode =
            if (photography) {
                CaptureMode(CaptureMode.Role.PHOTO, "${INTEGRATION.rawValue}.photo", "Photo")
            } else {
                CaptureMode(CaptureMode.Role.VIDEO, "${INTEGRATION.rawValue}.movie", "Movie")
            }

        /** Keeps an unchanged observation and its timestamp; a new value is camera-reported now. */
        private fun <T : Any> ObservedValue<T>.observe(
            value: T?,
            at: MonotonicInstant,
            precision: ObservationPrecision? = null,
        ): ObservedValue<T> =
            when {
                this.value == value -> this
                value == null -> ObservedValue.unknown
                else -> ObservedValue(value, ObservationOrigin.CAMERA_REPORTED, at, precision = precision)
            }

        private fun CameraControlException.toStage(): CommandStage =
            when (this) {
                CameraControlException.NotConnected -> CommandStage.Rejected(CommandRejection.NotConnected)
                CameraControlException.MediaBusy ->
                    CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.Busy))
                CameraControlException.CommandRejected -> CommandStage.Rejected(CommandRejection.CameraRefused)
                CameraControlException.ReadbackMismatch -> CommandStage.Failed(CommandFailure.NOT_APPLIED)
                // The write may have reached the camera; never success.
                CameraControlException.TransportFailed -> CommandStage.OutcomeUnknown
                CameraControlException.CoreUnavailable, CameraControlException.UnsupportedSelection ->
                    CommandStage.Failed(CommandFailure.NOT_SENT)
            }

        private fun CameraRecordingException.toStage(): CommandStage =
            when (this) {
                CameraRecordingException.NotConnected -> CommandStage.Rejected(CommandRejection.NotConnected)
                CameraRecordingException.MediaBusy ->
                    CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.Busy))
                CameraRecordingException.CommandRejected -> CommandStage.Rejected(CommandRejection.CameraRefused)
                CameraRecordingException.TransportFailed -> CommandStage.OutcomeUnknown
                CameraRecordingException.CoreUnavailable, CameraRecordingException.Unsupported ->
                    CommandStage.Failed(CommandFailure.NOT_SENT)
            }

        private fun CommandStage.controlFailure(): CameraControlException? =
            when (this) {
                is CommandStage.Rejected ->
                    when (rejection) {
                        CommandRejection.CameraRefused -> CameraControlException.CommandRejected
                        CommandRejection.NotConnected, CommandRejection.SessionClosed ->
                            CameraControlException.NotConnected
                        CommandRejection.Unavailable(UnavailableReason.Busy) -> CameraControlException.MediaBusy
                        else -> CameraControlException.UnsupportedSelection
                    }
                CommandStage.Failed(CommandFailure.NOT_APPLIED) -> CameraControlException.ReadbackMismatch
                is CommandStage.Failed -> CameraControlException.UnsupportedSelection
                CommandStage.OutcomeUnknown, CommandStage.TimedOut -> CameraControlException.TransportFailed
                else -> null
            }

        private fun CommandStage.recordingFailure(): CameraRecordingException? =
            when (this) {
                is CommandStage.Rejected ->
                    when (rejection) {
                        CommandRejection.CameraRefused -> CameraRecordingException.CommandRejected
                        CommandRejection.NotConnected, CommandRejection.SessionClosed ->
                            CameraRecordingException.NotConnected
                        CommandRejection.Unavailable(UnavailableReason.Busy) -> CameraRecordingException.MediaBusy
                        else -> CameraRecordingException.Unsupported
                    }
                is CommandStage.Failed -> CameraRecordingException.Unsupported
                CommandStage.OutcomeUnknown, CommandStage.TimedOut -> CameraRecordingException.TransportFailed
                else -> null
            }
    }
}
