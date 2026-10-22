package com.opencapture.openzcine

import android.content.SharedPreferences
import android.graphics.Bitmap
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.openzcine.bridge.SwiftCore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Raw real-frame metadata only; Swift owns all focus eligibility decisions. */
internal fun focusRackFocusJSON(focus: LiveFocusInfo?): JSONObject? =
    focus?.takeUnless { it.isDebugFixture }?.let {
        JSONObject().put("trackingAFActive", it.trackingAFActive)
            .put("subjectDetectionActive", it.subjectDetectionActive)
            .put("boxCount", it.boxes.size)
            .put("selectedBoxIndex", it.selectedBoxIndex ?: JSONObject.NULL)
    }

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
    private val traceSink: (String) -> Unit = {},
) {
    private var owner: String? = null
    private val mutableState = MutableStateFlow(FocusRackViewState())
    val state: StateFlow<FocusRackViewState> = mutableState
    private val mutableThumbnails = MutableStateFlow<Map<String, Bitmap>>(emptyMap())
    val thumbnails: StateFlow<Map<String, Bitmap>> = mutableThumbnails
    private val mutableTemplates = MutableStateFlow<List<FocusRackTimingViewState>>(emptyList())
    val templates: StateFlow<List<FocusRackTimingViewState>> = mutableTemplates
    private var observation: JSONObject? = null
    private var closed = false
    private var poller: Job? = null
    private var persistedTemplates: String? = null
    private var pendingCapture: Triple<String, Long, Bitmap>? = null
    private var captures: Map<String, Long> = emptyMap()
    private var stopPending = false

    /** Allocates the inert native owner only when the operator first opens Focus Rack. */
    fun activate() {
        if (closed) return
        if (owner == null) owner = runCatching { wire.create(connectionOwner,
            preferences.getString(TEMPLATES_KEY, "[]") ?: "[]") }.getOrNull()
        if (owner == null) {
            mutableState.value = state.value.copy(error = "Focus Rack is unavailable in this build.")
            return
        }
        if (poller?.isActive != true) poller = scope.launch {
            while (!closed) { send("poll"); delay(100) }
        }
    }

    fun observe(value: JSONObject) { observation = value; send("observe") }
    fun capture(id: String, candidate: Pair<Long, Bitmap>?) {
        if (candidate == null) return
        pendingCapture = Triple(id, candidate.first, candidate.second)
        send("capture", JSONObject().put("markID", id).put("expectedFrameSequence", candidate.first))
    }
    fun nudge(near: Boolean, steps: Int) = send("nudge", JSONObject().put("towardNear", near).put("steps", steps))
    fun primary() = send("primary")
    fun run(direction: String) = send("run", JSONObject().put("direction", direction))
    fun goTo(mark: String) = send("goTo", JSONObject().put("markID", mark))
    fun stop() {
        stopPending = state.value.active
        if (stopPending) mutableState.value = state.value.copy(phase = "stopping", primaryEnabled = false)
        send("stop")
    }
    fun reset() = send("reset")
    fun externalFocus() = send("externalFocus")
    fun interrupt() = send("interrupt")
    fun closePanel() {
        observation?.put("foregroundOwner", false)
        pendingCapture = null
        send("closePanel")
        poller?.cancel()
        mutableThumbnails.value = emptyMap()
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
        owner?.let(wire::close)
        pendingCapture = null
        mutableThumbnails.value = emptyMap()
    }

    private fun send(kind: String, request: JSONObject = JSONObject()) {
        if (closed) return
        val handle = owner ?: return
        val wasActive = state.value.active
        request.put("kind", kind)
        observation?.let { request.put("observation", it) }
        val reply = runCatching { wire.step(handle, request.toString())?.let(::JSONObject) }.getOrNull()
        if (reply == null) {
            // Cancellation remains a synchronous JNI intent even if state decoding failed.
            runCatching { wire.step(handle, "{\"kind\":\"stop\"}") }
            mutableState.value = state.value.copy(error = "Focus Rack is unavailable; stop requested.", primaryEnabled = false,
                pullAToB = state.value.pullAToB?.copy(enabled = false), pullBToA = state.value.pullBToA?.copy(enabled = false))
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
                    mark.getLong("revision"), mark.getString("sessionID"), mark.getLong("frameSequence")) }
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
            mutableState.value = FocusRackViewState(phase = if (stopPending) "stopping" else snapshot.getString("phase"),
                message = snapshot.getString("message"), recovery = snapshot.nullableString("recoveryInstruction"),
                admissionMessage = snapshot.nullableString("admissionMessage"),
                error = reply.nullableString("error") ?: snapshot.nullableString("admissionMessage"),
                position = if (snapshot.isNull("stepPosition")) null else snapshot.getInt("stepPosition"), marks = marks,
                fromMark = transition.getString("fromMark"), toMark = transition.getString("toMark"),
                duration = transition.getDouble("duration"), delay = transition.getDouble("delay"), easing = transition.getString("easing"),
                durationMode = transition.optString("durationMode", "timed"),
                estimatedDuration = if (snapshot.isNull("estimatedDuration")) null else snapshot.getDouble("estimatedDuration"),
                primaryTitle = primary.getString("title"), primaryDetail = primary.nullableString("detail"),
                primaryDisabledReason = primary.nullableString("disabledReason"),
                pullAToB = snapshot.optJSONObject("pullAToB")?.action(),
                pullBToA = snapshot.optJSONObject("pullBToA")?.action(),
                playbackInstruction = snapshot.nullableString("playbackInstruction"),
                canGoToA = caps.optBoolean("canGoToA"), canGoToB = caps.optBoolean("canGoToB"), primaryEnabled = primary.getBoolean("enabled") && !stopPending,
                canCaptureA = caps.getBoolean("canCaptureA"), canCaptureB = caps.getBoolean("canCaptureB"),
                canNudge = caps.getBoolean("canNudge"), canEdit = caps.getBoolean("canEditTiming"),
                canReset = caps.getBoolean("canReset"), canAutofocus = caps.optBoolean("canAutofocus"), canPause = caps.getBoolean("canPause"), canStop = caps.getBoolean("canStop"), active = snapshot.getBoolean("busy"),
                completed = snapshot.getInt("completedSteps"), total = snapshot.getInt("totalSteps"),
                minimumDuration = if (snapshot.isNull("minimumDuration")) null else snapshot.getDouble("minimumDuration"),
                remainingDelay = snapshot.optDouble("remainingDelay", 0.0),
                nudgeProgress = snapshot.optJSONObject("nudgeProgress")?.let {
                    FocusRackNudgeProgressViewState(it.getBoolean("towardNear"), it.getInt("steps"), it.getInt("percent"))
                })
        }
        if (BuildConfig.DEBUG) {
            reply.nullableString("traceJSON")?.let { trace -> runCatching { traceSink(trace) } }
            if (wasActive && !state.value.active) send("diagnostics")
        }
        val saved = reply.optString("templatesJSON").takeIf { it.isNotEmpty() && it != "null" }
        if (saved != null && saved != persistedTemplates) {
            // Swift validates and emits this timing-only schema. The shell stores the bytes verbatim.
            preferences.edit().putString(TEMPLATES_KEY, saved).apply()
            persistedTemplates = saved
        }
        reply.optJSONArray("templates")?.let { values ->
            mutableTemplates.value = (0 until values.length()).map { index ->
                values.getJSONObject(index).let { FocusRackTimingViewState(it.getString("name"), it.toString()) }
            }
        }
    }
    private fun JSONObject.action(): FocusRackActionViewState = FocusRackActionViewState(
        getString("title"), nullableString("detail"), getBoolean("enabled") && !stopPending,
        nullableString("disabledReason"))
    private fun JSONObject.nullableString(key: String): String? = if (!has(key) || isNull(key)) null else getString(key)
    private companion object { const val TEMPLATES_KEY = "focusRack.timingTemplates.v1" }
}
