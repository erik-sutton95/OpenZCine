package com.opencapture.openzcine

import android.content.SharedPreferences
import android.graphics.Bitmap
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.openzcine.bridge.SwiftCore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicLong

/** Raw real-frame metadata only; Swift owns all focus eligibility decisions. */
internal fun focusRackFocusJSON(focus: LiveFocusInfo?): JSONObject? =
    focus?.takeUnless { it.isDebugFixture }?.let {
        JSONObject().put("trackingAFActive", it.trackingAFActive)
            .put("subjectDetectionActive", it.subjectDetectionActive)
            .put("boxCount", it.boxes.size)
            .put("selectedBoxIndex", it.selectedBoxIndex ?: JSONObject.NULL)
    }

/** Rechecks the exact prepared readback tuple at the existing serialized send boundary. */
internal fun focusAFSettingsReadbacksMatch(expected: JSONObject, actual: CameraPropertySnapshot): Boolean =
    actual.captureSelector == "video" && listOf("mode" to actual.focusMode,
        "area" to actual.focusArea, "subject" to actual.focusSubject).all { (key, value) ->
        value != null && !expected.isNull(key) && expected.optString(key) == value
    }

/** Explicit Native mode selection releases the app point lock, preserving the interface lock. */
internal fun focusPointLockedAfterModeSelection(pointLocked: Boolean, currentMode: String,
    selectedMode: String, interfaceLocked: Boolean): Boolean =
    pointLocked && (interfaceLocked || currentMode != "timedRack" || selectedMode != "nativeAF")

/** Native transport to a Swift runner; this boundary never exposes camera command actions. */
internal interface FocusRackWirePort {
    fun create(connectionOwner: Long, templates: String): String?
    fun step(owner: String, request: String): String?
    fun close(owner: String)
}
private object NativeFocusRackWire : FocusRackWirePort {
    override fun create(connectionOwner: Long, templates: String): String? =
        if (SwiftCore.isAvailable) SwiftCore.focusRackCreate(connectionOwner, templates) else null
    override fun step(owner: String, request: String): String? = SwiftCore.focusRackStep(owner, request)
    override fun close(owner: String) = SwiftCore.focusRackClose(owner)
}

/** Main-thread shell adapter: forwards observations/intents, thumbnails and timing-template bytes. */
internal class FocusRackController(private val connectionOwner: Long, private val preferences: SharedPreferences,
    private val scope: CoroutineScope, private val wire: FocusRackWirePort = NativeFocusRackWire,
    private val observationNanos: () -> Long = System::nanoTime,
    private val nativeCheckpoint: AtomicReference<String?> = AtomicReference(null),
    private val selectedFocusMode: AtomicReference<String?> = AtomicReference(null),
) {
    private var owner: String? = null
    private val mutableState = MutableStateFlow(FocusRackViewState())
    val state: StateFlow<FocusRackViewState> = mutableState
    private val mutableThumbnails = MutableStateFlow<Map<String, Bitmap>>(emptyMap())
    val thumbnails: StateFlow<Map<String, Bitmap>> = mutableThumbnails
    private val mutableTemplates = MutableStateFlow<List<FocusRackTimingViewState>>(emptyList())
    val templates: StateFlow<List<FocusRackTimingViewState>> = mutableTemplates
    private var observation: JSONObject? = null
    @Volatile private var closed = false
    private var poller: Job? = null
    private var persistedTemplates: String? = null
    private var persistedCalibration: String? = null
    private var pendingCapture: Triple<String, Long, Bitmap>? = null
    private var captures: Map<String, Long> = emptyMap()
    private var stopPending = false
    private var pendingFocusMode: String? = null
    private val afInput = AtomicReference<String?>(null)
    private val nativeInput = AtomicReference<Pair<String, Long>?>(null)
    private val afInputAt = AtomicLong(0)
    @Volatile private var afSuspended = false
    private var afWriter: (suspend (JSONObject, () -> Boolean) -> JSONObject)? = null
    private var afWriteJob: Job? = null
    private var afEffectID: Long? = null
    private var nativeWriter: (suspend (JSONObject, () -> Boolean) -> Boolean)? = null
    private var nativeCompletionInput: () -> JSONObject? = { null }
    private var nativeWriteJob: Job? = null
    private var nativeEffectID: Long? = null

    /** The shell supplies only the existing admitted setting writer and actual readback. */
    fun configureAFSettings(writer: suspend (JSONObject, () -> Boolean) -> JSONObject) { afWriter = writer }

    /** Manual intent retires ownership before even a same-value picker write can be queued. */
    fun manualAFSetting(property: String) {
        send("manualAFSetting", JSONObject().put("afProperty", property))
    }

    /** Coordinates are normalized in the camera space; the Swift value owns target and delay state. */
    fun configureNativeAF(completionInput: () -> JSONObject? = { null },
        writer: suspend (JSONObject, () -> Boolean) -> Boolean) {
        nativeCompletionInput = completionInput
        nativeWriter = writer
    }
    fun armNativeTarget(mark: String) = send("nativeAFArm", JSONObject().put("nativeAFMark", mark))
    fun captureNativeTarget(x: Double, y: Double) = send("nativeAFCapture", JSONObject()
        .put("nativeAFPoint", JSONObject().put("x", x).put("y", y)))
    fun goNativeTarget(mark: String) = send("nativeAFGo", JSONObject().put("nativeAFMark", mark))
    fun runNativeTarget(mark: String) = send("nativeAFRun", JSONObject().put("nativeAFMark", mark))
    fun cancelNativeDelay() = send("nativeAFCancel")
    fun nativeDelay(value: String) {
        val seconds = value.toDoubleOrNull()
        if (seconds == null || !seconds.isFinite()) {
            mutableState.value = state.value.copy(error = "Enter a number for start delay.")
            return
        }
        send("nativeAFDelay", JSONObject().put("nativeAFStartDelay", seconds))
    }

    fun openPanel() { afSuspended = false; activate(); send("openPanel") }
    fun resumeAFSettings() { afSuspended = false; send("resumeAFSettings") }

    /** Allocates the inert native owner only when the operator first opens Focus Rack. */
    fun activate() {
        if (closed) return
        if (owner == null) {
            owner = runCatching { wire.create(connectionOwner,
                preferences.getString(TEMPLATES_KEY, "[]") ?: "[]") }.getOrNull()
            if (owner != null) nativeCheckpoint.get()?.let {
                send("nativeAFRestoreCheckpoint", JSONObject().put("nativeAFCheckpointJSON", it)
                    .put("focusMode", selectedFocusMode.get() ?: "timedRack"))
            }
            if (owner != null) preferences.getString(CALIBRATION_KEY, null)?.let {
                persistedCalibration = it
                send("loadCalibration", JSONObject().put("calibrationJSON", it))
            }
        }
        if (owner == null) {
            mutableState.value = state.value.copy(error = "Focus Rack is unavailable in this build.")
            return
        }
        if (poller?.isActive != true) poller = scope.launch {
            while (!closed) { send("poll"); delay(100) }
        }
    }

    fun observe(value: JSONObject) {
        observation = value
        nativeInput.set(value.toString() to observationNanos())
        afInput.set(value.optJSONObject("afSettings")?.toString())
        afInputAt.set(observationNanos())
        send("observe")
    }
    fun capture(id: String, candidate: Pair<Long, Bitmap>?) {
        if (candidate == null) return
        pendingCapture = Triple(id, candidate.first, candidate.second)
        send("capture", JSONObject().put("markID", id).put("expectedFrameSequence", candidate.first))
    }
    fun nudge(near: Boolean, steps: Int) = send("nudge", JSONObject().put("towardNear", near).put("steps", steps))
    fun selectFocusMode(mode: String) {
        afSuspended = false
        pendingFocusMode = mode
        mutableState.value = state.value.copy(focusModeSwitchPending = true,
            canChangeFocusMode = false, canAutofocus = false, canNativeAutofocus = false)
        send("selectFocusMode", JSONObject().put("focusMode", mode))
    }
    fun primary() = send("primary")
    fun run(direction: String) = send("run", JSONObject().put("direction", direction))
    fun goTo(mark: String) = send("goTo", JSONObject().put("markID", mark))
    fun calibrate() = send("calibrate")
    fun stop() {
        stopPending = state.value.active
        if (stopPending) mutableState.value = state.value.copy(phase = "stopping", primaryEnabled = false)
        send("stop")
    }
    fun reset() = send("reset")
    fun externalFocus() = send("externalFocus")
    fun nativeTargetFocus() = send("nativeTargetFocus")
    fun interrupt() {
        afSuspended = true
        observation?.put("foregroundOwner", false)
        observation?.optJSONObject("afSettings")?.let {
            it.put("foreground", false)
            afInput.set(it.toString())
            afInputAt.set(observationNanos())
        }
        observation?.let { nativeInput.set(it.toString() to observationNanos()) }
        send("interrupt")
    }
    fun closePanel(): Boolean {
        if (state.value.focusModeSwitchPending) return false
        observation?.put("foregroundOwner", false)
        pendingCapture = null
        send("closePanel")
        mutableThumbnails.value = emptyMap()
        return true
    }
    fun timing(edit: FocusRackTimingEdit) {
        val update = JSONObject()
        for ((name, value) in listOf("duration" to edit.duration, "delay" to edit.delay)) {
            if (value != null) {
                val seconds = value.toDoubleOrNull()
                if (seconds == null || !seconds.isFinite()) {
                    mutableState.value = state.value.copy(error = "Enter a number for duration and delay.")
                    return
                }
                update.put(name, seconds)
            }
        }
        edit.easing?.let { update.put("easing", it) }
        edit.durationMode?.let { update.put("durationMode", it) }
        edit.reverse?.let { update.put("direction", if (it) "bToA" else "aToB") }
        send("updateTiming", JSONObject().put("timingUpdate", update))
    }
    fun saveTemplate(name: String) = send("saveTemplate", JSONObject().put("name", name))
    fun loadTemplate(template: FocusRackTimingViewState) = send("loadTemplate", JSONObject().put("template", JSONObject(template.json)))
    fun deleteTemplate(template: FocusRackTimingViewState) = send("deleteTemplate", JSONObject().put("name", template.name))

    fun close() {
        if (closed) return
        closed = true
        poller?.cancel()
        afWriteJob?.cancel()
        nativeWriteJob?.cancel()
        afInput.set(null)
        nativeInput.set(null)
        owner?.let(wire::close)
        pendingCapture = null
        mutableThumbnails.value = emptyMap()
    }

    private fun send(kind: String, request: JSONObject = JSONObject()) {
        if (closed) return
        val handle = owner ?: return
        request.put("kind", kind)
        observation?.let {
            request.put("observation", it)
            request.put("movieFocusMode", it.opt("movieFocusMode") ?: JSONObject.NULL)
            request.put("photography", it.optBoolean("photography", false))
            if (!request.has("afSettings")) it.optJSONObject("afSettings")?.let { input -> request.put("afSettings", input) }
            request.put("nativeAFInterfaceLocked", it.optBoolean("nativeAFInterfaceLocked"))
            request.put("nativeAFPointLocked", it.optBoolean("nativeAFPointLocked"))
            request.put("nativeAFCoordinateSpaceAvailable", it.optBoolean("nativeAFCoordinateSpaceAvailable"))
            request.put("nativeAFUnrelatedCommandPending", it.optBoolean("nativeAFUnrelatedCommandPending"))
        }
        val reply = runCatching { wire.step(handle, request.toString())?.let(::JSONObject) }.getOrNull()
        if (reply == null) {
            // Cancellation remains a synchronous JNI intent even if state decoding failed.
            runCatching { wire.step(handle, "{\"kind\":\"stop\"}") }
            mutableState.value = state.value.copy(error = "Focus Rack is unavailable; stop requested.", primaryEnabled = false,
                canChangeFocusMode = false, canAutofocus = false, canNativeAutofocus = false,
                nativeAF = state.value.nativeAF.copy(canSet = false, canRun = false, canGoToA = false, canGoToB = false),
                pullAToB = state.value.pullAToB?.copy(enabled = false), pullBToA = state.value.pullBToA?.copy(enabled = false),
                calibration = state.value.calibration?.copy(enabled = false))
            return
        }
        reply.optJSONObject("state")?.let { snapshot ->
            val caps = snapshot.getJSONObject("capabilities")
            val primary = snapshot.getJSONObject("primary")
            val transition = snapshot.getJSONObject("transition")
            val programMarks = snapshot.getJSONObject("program").getJSONArray("marks")
            val markPositions = (0 until programMarks.length()).associate { index ->
                programMarks.getJSONObject(index).let { it.getString("id") to it.getInt("stepPosition") }
            }
            val identities = snapshot.getJSONArray("captures")
            val marks = (0 until identities.length()).mapNotNull { index ->
                val mark = identities.getJSONObject(index)
                val id = mark.getString("markID")
                markPositions[id]?.let { position -> FocusRackMarkViewState(id, position,
                    mark.getLong("revision"), mark.getLong("frameSequence")) }
            }
            val validCaptures = marks.associate { it.id to it.revision }
            mutableThumbnails.value = mutableThumbnails.value.filterKeys { validCaptures[it] == captures[it] }
            pendingCapture?.let { (id, sequence, image) ->
                marks.firstOrNull { it.id == id && it.frameSequence == sequence && captures[id] != it.revision }?.let {
                    mutableThumbnails.value = mutableThumbnails.value + (id to image)
                    pendingCapture = null
                }
            }
            captures = validCaptures
            val sharedBusy = snapshot.getBoolean("busy")
            if (!sharedBusy) stopPending = false
            val sharedMode = reply.optString("focusMode", "timedRack")
            selectedFocusMode.set(sharedMode)
            val sharedModePending = reply.optBoolean("focusModeSwitchPending")
            if (!sharedModePending && (sharedMode == pendingFocusMode || reply.nullableString("error") != null)) pendingFocusMode = null
            val modePending = sharedModePending || pendingFocusMode != null
            mutableState.value = FocusRackViewState(
                focusMode = sharedMode,
                focusModeSwitchPending = modePending,
                canChangeFocusMode = reply.optBoolean("canChangeFocusMode") && !stopPending && !modePending,
                afSettingsPending = reply.optBoolean("afSettingsPending"),
                afSettingsRestoring = reply.optBoolean("afSettingsRestoring"),
                afSettingsFailure = reply.nullableString("afSettingsFailure"),
                nativeAFDisabledReason = reply.nullableString("nativeAFDisabledReason"),
                nativeAF = reply.optJSONObject("nativeAF")?.let { native ->
                    NativeAFRackViewState(
                        hasA = native.optJSONObject("a") != null, hasB = native.optJSONObject("b") != null,
                        selectingMark = native.nullableString("selectingMark"), startDelay = native.optDouble("startDelay"),
                        busy = native.optBoolean("busy"),
                        canSet = native.optBoolean("canSet"),
                        canGoToA = native.optBoolean("canGoToA"), canGoToB = native.optBoolean("canGoToB"),
                        canRun = native.optBoolean("canRun"), canCancel = native.optBoolean("canCancel"),
                        message = native.optString("message"), failure = native.nullableString("failure"))
                } ?: NativeAFRackViewState(),
                canNativeAutofocus = reply.optBoolean("canNativeAutofocus") && !stopPending && !modePending,
                phase = if (stopPending) "stopping" else snapshot.getString("phase"),
                message = snapshot.getString("message"), recovery = snapshot.nullableString("recoveryInstruction"),
                admissionMessage = snapshot.nullableString("admissionMessage"),
                error = reply.nullableString("error") ?: snapshot.nullableString("admissionMessage"),
                position = if (snapshot.isNull("stepPosition")) null else snapshot.getInt("stepPosition"), marks = marks,
                fromMark = transition.getString("fromMark"), toMark = transition.getString("toMark"),
                duration = transition.getDouble("duration"), delay = transition.getDouble("delay"), easing = transition.getString("easing"),
                recording = observation?.optBoolean("recording") == true,
                durationMode = transition.optString("durationMode", "timed"),
                estimatedDuration = if (snapshot.isNull("estimatedDuration")) null else snapshot.getDouble("estimatedDuration"),
                timingWarning = snapshot.nullableString("timingWarning"),
                timingWarningIsEstimate = snapshot.optBoolean("timingWarningIsEstimate"),
                primaryTitle = primary.getString("title"), primaryDetail = primary.nullableString("detail"),
                pullAToB = snapshot.optJSONObject("pullAToB")?.action(),
                pullBToA = snapshot.optJSONObject("pullBToA")?.action(),
                calibration = snapshot.optJSONObject("calibration")?.action(),
                preparationRecommended = snapshot.optBoolean("preparationRecommended"),
                preparingLens = snapshot.optBoolean("preparingLens"),
                playbackInstruction = snapshot.nullableString("playbackInstruction"),
                canGoToA = caps.optBoolean("canGoToA"), canGoToB = caps.optBoolean("canGoToB"), primaryEnabled = primary.getBoolean("enabled") && !stopPending,
                canCaptureA = caps.getBoolean("canCaptureA"), canCaptureB = caps.getBoolean("canCaptureB"),
                canNudge = caps.getBoolean("canNudge"), canEdit = caps.getBoolean("canEditTiming"),
                canReset = caps.getBoolean("canReset"), canAutofocus = caps.optBoolean("canAutofocus") && !modePending, canPause = caps.getBoolean("canPause"), canStop = caps.getBoolean("canStop"), active = snapshot.getBoolean("busy"),
                completed = snapshot.getInt("completedSteps"), total = snapshot.getInt("totalSteps"),
                remainingDelay = snapshot.optDouble("remainingDelay", 0.0),
                nudgeProgress = snapshot.optJSONObject("nudgeProgress")?.let {
                    FocusRackNudgeProgressViewState(it.getBoolean("towardNear"), it.getInt("steps"), it.getInt("percent"))
                })
        }
        reply.nullableString("nativeAFCheckpointJSON")?.let(nativeCheckpoint::set)
        reply.optJSONObject("afSettingsChange")?.let { change ->
            reply.optJSONObject("afSettingsExpectedValues")?.let { change.put("expectedValues", it) }
            executeAFSetting(change)
        }
        reply.optJSONObject("nativeAFChange")?.let(::executeNativeTarget)
        val saved = reply.optString("templatesJSON").takeIf { it.isNotEmpty() && it != "null" }
        if (saved != null && saved != persistedTemplates) {
            // Swift validates and emits this timing-only schema. The shell stores the bytes verbatim.
            preferences.edit().putString(TEMPLATES_KEY, saved).apply()
            persistedTemplates = saved
        }
        reply.nullableString("calibrationJSON")?.let { checkpoint ->
            if (checkpoint != persistedCalibration) {
                // Swift validates and scopes timing evidence; Kotlin stores its bytes unchanged.
                preferences.edit().putString(CALIBRATION_KEY, checkpoint).apply()
                persistedCalibration = checkpoint
            }
        }
        reply.optJSONArray("templates")?.let { values ->
            mutableTemplates.value = (0 until values.length()).map { index ->
                values.getJSONObject(index).let { FocusRackTimingViewState(it.getString("name"), it.toString()) }
            }
        }
    }
    private fun executeNativeTarget(change: JSONObject) {
        val id = change.getLong("id")
        if (nativeEffectID == id || nativeWriteJob?.isActive == true) return
        val handle = owner ?: return
        val writer = nativeWriter ?: return
        nativeEffectID = id
        val admitted = {
            val input = nativeInput.get()
            val age = input?.let { observationNanos() - it.second }
            !closed && !afSuspended && input != null && age != null && age in 0..500_000_000L && runCatching {
                val latest = JSONObject(input.first)
                // Carry elapsed adapter time into Swift's frame-age check, without sharing a mutable JSONObject.
                latest.put("frameAgeSeconds", latest.optDouble("frameAgeSeconds", 999.0) + age / 1e9)
                val request = JSONObject().put("kind", "nativeAFAdmission").put("nativeAFRequestID", id)
                    .put("observation", latest).put("movieFocusMode", latest.opt("movieFocusMode"))
                    .put("photography", latest.optBoolean("photography"))
                    .put("afSettings", latest.optJSONObject("afSettings"))
                    .put("nativeAFInterfaceLocked", latest.optBoolean("nativeAFInterfaceLocked"))
                    .put("nativeAFPointLocked", latest.optBoolean("nativeAFPointLocked"))
                    .put("nativeAFCoordinateSpaceAvailable", latest.optBoolean("nativeAFCoordinateSpaceAvailable"))
                    .put("nativeAFUnrelatedCommandPending", latest.optBoolean("nativeAFUnrelatedCommandPending"))
                wire.step(handle, request.toString())?.let(::JSONObject)?.optBoolean("allowed") == true
            }.getOrDefault(false)
        }
        nativeWriteJob = scope.launch {
            val completion = JSONObject().put("nativeAFRequestID", id)
            try {
                if (!admitted() || !writer(change, admitted))
                    completion.put("nativeAFFailure", "Target selection was cancelled before the camera accepted it.")
            } catch (error: Exception) {
                completion.put("nativeAFFailure", error.message ?: "The camera did not accept the target.")
            } finally {
                nativeCompletionInput()?.let { fresh ->
                    afInput.set(fresh.toString())
                    afInputAt.set(observationNanos())
                    observation?.put("afSettings", fresh)
                    observation?.let { latest ->
                        nativeInput.get()?.second?.let { observedAt -> nativeInput.set(latest.toString() to observedAt) }
                    }
                    completion.put("afSettings", fresh)
                }
                send("nativeAFComplete", completion)
                nativeWriteJob = null
            }
        }
    }

    private fun executeAFSetting(change: JSONObject) {
        val id = change.getLong("id")
        if (afEffectID == id || afWriteJob?.isActive == true) return
        val handle = owner ?: return
        val writer = afWriter ?: return
        afEffectID = id
        val changeJSON = change.toString()
        val admitted = {
            val input = afInput.get()
            val age = observationNanos() - afInputAt.get()
            !closed && !afSuspended && input != null && age in 0..500_000_000L && runCatching {
                val request = JSONObject().put("kind", "afSettingsAdmission")
                    .put("afChange", JSONObject(changeJSON)).put("afSettings", JSONObject(input))
                wire.step(handle, request.toString())?.let(::JSONObject)?.optBoolean("allowed") == true
            }.getOrDefault(false)
        }
        afWriteJob = scope.launch {
            try {
                if (!admitted()) {
                    send("afSettingsDeferred", JSONObject().put("afChange", change))
                } else {
                    val confirmed = writer(change, admitted)
                    afInput.set(confirmed.toString())
                    afInputAt.set(observationNanos())
                    observation?.put("afSettings", confirmed)
                    send("afSettingsComplete", JSONObject().put("afChange", change).put("afSettings", confirmed))
                }
            } catch (error: Exception) {
                send("afSettingsComplete", JSONObject().put("afChange", change)
                    .put("afFailure", error.message ?: "The camera did not confirm the AF setting."))
            } finally {
                afWriteJob = null
            }
        }
    }

    private fun JSONObject.action(): FocusRackActionViewState = FocusRackActionViewState(
        getString("title"), nullableString("detail"), getBoolean("enabled") && !stopPending,
        nullableString("disabledReason"))
    private fun JSONObject.nullableString(key: String): String? = if (!has(key) || isNull(key)) null else getString(key)
    private companion object {
        const val TEMPLATES_KEY = "focusRack.timingTemplates.v1"
        const val CALIBRATION_KEY = "focusRack.calibration.v1"
    }
}
