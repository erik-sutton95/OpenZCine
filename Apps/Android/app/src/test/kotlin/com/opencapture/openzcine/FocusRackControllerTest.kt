package com.opencapture.openzcine

import com.opencapture.opencine.nikon.LiveFocusBox
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.LiveFocusResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import kotlin.test.*

/** Boundary tests: Kotlin renders shared policy and never receives or executes native movement. */
class FocusRackControllerTest {
    @Test
    fun `focus wire preserves independent raw fields and excludes synthetic metadata`() {
        val point = LiveFocusBox(50, 50, 10, 10)
        val focus = LiveFocusInfo(100, 100, LiveFocusResult.FOCUSED,
            subjectDetectionActive = true, trackingAFActive = false, selectedBoxIndex = null, boxes = listOf(point))
        val raw = requireNotNull(focusRackFocusJSON(focus))
        assertFalse(raw.getBoolean("trackingAFActive"))
        assertTrue(raw.getBoolean("subjectDetectionActive"))
        assertEquals(1, raw.getInt("boxCount"))
        assertTrue(raw.isNull("selectedBoxIndex"))

        val selected = requireNotNull(focusRackFocusJSON(focus.copy(
            trackingAFActive = true, subjectDetectionActive = false, selectedBoxIndex = 1, boxes = listOf(point, point))))
        assertTrue(selected.getBoolean("trackingAFActive"))
        assertFalse(selected.getBoolean("subjectDetectionActive"))
        assertEquals(2, selected.getInt("boxCount"))
        assertEquals(1, selected.getInt("selectedBoxIndex"))
        assertNull(focusRackFocusJSON(null))
        assertNull(focusRackFocusJSON(focus.copy(isDebugFixture = true)))
    }

    private class Wire : FocusRackWirePort {
        val requests = mutableListOf<JSONObject>()
        var closed = false
        var busy = true
        var phase = "moving"
        var durationMode = "timed"
        var templates = "[]"
        var createdTemplates: String? = null
        var traceJSON: String? = null
        var calibrationJSON: String? = null
        var nudgeProgress: JSONObject? = null
        var calibration: JSONObject? = null
        var unavailable = false
        override fun create(connectionOwner: Long, templates: String): String {
            assertEquals(42L, connectionOwner)
            createdTemplates = templates
            return "rack-owner"
        }
        override fun close(owner: String) { closed = true }
        override fun step(owner: String, request: String): String {
            requests += JSONObject(request)
            if (unavailable) return "invalid JSON"
            val caps = JSONObject().put("canCaptureA", false).put("canCaptureB", false)
                .put("canNudge", false).put("canEditTiming", !busy).put("canReset", !busy)
                .put("canPause", busy).put("canStop", busy)
            val transition = JSONObject().put("fromMark", "A").put("toMark", "B")
                .put("duration", 24).put("delay", 2).put("easing", "linear").put("durationMode", durationMode)
            val state = JSONObject().put("phase", phase).put("message", "From shared Swift")
                .put("program", JSONObject().put("marks", JSONArray())).put("captures", JSONArray())
                .put("transition", transition).put("stepPosition", JSONObject.NULL)
                .put("completedSteps", 4).put("totalSteps", 94).put("busy", busy)
                .put("capabilities", caps).put("primary", JSONObject().put("title", "Pause")
                    .put("enabled", busy)).put("minimumDuration", 16.6)
            nudgeProgress?.let { state.put("nudgeProgress", it) }
            calibration?.let { state.put("calibration", it) }
            return JSONObject().put("state", state).put("templates", JSONArray(templates))
                .put("templatesJSON", templates).put("traceJSON", traceJSON)
                .put("calibrationJSON", calibrationJSON).toString()
        }
    }

    @Test fun `saved calibration loads once before observations and survives owner replacement`() = runTest {
        val saved = """{"version":1,"key":{"cameraID":"fixture-body"},"commandDurations":{"128":0.08}}"""
        val updated = """{"version":1,"key":{"cameraID":"fixture-body"},"commandDurations":{"128":0.11}}"""
        val preferences = TestSharedPreferences()
        preferences.edit().putString("focusRack.calibration.v1", saved).apply()
        val wire = Wire().apply { busy = false }
        val rack = FocusRackController(42, preferences,
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        assertEquals("loadCalibration", wire.requests.single().getString("kind"))
        assertEquals(saved, wire.requests.single().getString("calibrationJSON"))
        assertFalse(wire.requests.single().has("observation"))
        rack.activate()
        assertEquals(1, wire.requests.count { it.getString("kind") == "loadCalibration" })
        wire.calibrationJSON = updated
        rack.observe(JSONObject().put("cameraID", "fixture-body").put("transport", "usb"))
        assertEquals(updated, preferences.getString("focusRack.calibration.v1", null))
        val raw = wire.requests.last().getJSONObject("observation")
        assertEquals("fixture-body", raw.getString("cameraID"))
        assertEquals("usb", raw.getString("transport"))
        rack.close()

        val replacementWire = Wire().apply { busy = false }
        val replacement = FocusRackController(42, preferences,
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), replacementWire)
        replacement.activate()
        assertEquals(updated, replacementWire.requests.single().getString("calibrationJSON"))
        assertFalse(replacementWire.requests.any { it.getString("kind") in setOf("run", "goTo", "calibrate", "nudge") })
        replacement.close()
    }

    @Test fun `calibration renders shared action and forwards only the semantic intent`() = runTest {
        val wire = Wire().apply { busy = false }
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject())
        assertNull(rack.state.value.calibration) // Older shared payloads omit the action.
        wire.calibration = JSONObject().put("kind", "calibrate").put("title", "Calibrate to B")
            .put("detail", "32-pulse increments · 1/10").put("enabled", true).put("markID", "B")
        rack.observe(JSONObject())
        assertEquals(FocusRackActionViewState("Calibrate to B", "32-pulse increments · 1/10", true),
            rack.state.value.calibration)
        val before = wire.requests.size
        rack.calibrate()
        assertEquals(before + 1, wire.requests.size)
        assertEquals("calibrate", wire.requests.last().getString("kind"))
        assertFalse(wire.requests.last().has("markID"))
        assertFalse(wire.requests.last().has("timingUpdate"))
        wire.busy = true
        rack.observe(JSONObject())
        rack.stop()
        assertFalse(requireNotNull(rack.state.value.calibration).enabled)
        wire.busy = false
        wire.calibration = JSONObject().put("title", "Calibration complete")
            .put("detail", "Fine timing measured").put("enabled", false)
        rack.observe(JSONObject())
        assertEquals(FocusRackActionViewState("Calibration complete", "Fine timing measured", false),
            rack.state.value.calibration)
        wire.calibration?.put("enabled", true)
        rack.observe(JSONObject())
        wire.unavailable = true
        rack.calibrate()
        assertFalse(requireNotNull(rack.state.value.calibration).enabled)
        assertEquals("stop", wire.requests.last().getString("kind"))
        wire.unavailable = false
        wire.calibration = null
        rack.observe(JSONObject())
        assertNull(rack.state.value.calibration)
        rack.close()
    }

    @Test fun `interrupt keeps cached ownership suspended until a new observation`() = runTest {
        val wire = Wire().apply { busy = false }
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject().put("foregroundOwner", true))
        rack.interrupt()
        assertFalse(wire.requests.last().getJSONObject("observation").getBoolean("foregroundOwner"))
        testScheduler.runCurrent()
        val poll = wire.requests.last { it.getString("kind") == "poll" }
        assertFalse(poll.getJSONObject("observation").getBoolean("foregroundOwner"))
        rack.observe(JSONObject().put("foregroundOwner", true))
        assertTrue(wire.requests.last().getJSONObject("observation").getBoolean("foregroundOwner"))
        rack.close()
    }

    @Test fun `debug completion requests and forwards the private native trace`() = runTest {
        val wire = Wire()
        val traces = mutableListOf<String>()
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire,
            traceSink = { traces += it })
        rack.activate()
        rack.observe(JSONObject())
        wire.busy = false
        wire.traceJSON = "{\"events\":[]}"
        rack.observe(JSONObject())
        assertTrue(wire.requests.any { it.getString("kind") == "diagnostics" })
        assertTrue(traces.contains(wire.traceJSON))
        assertFalse(wire.requests.any { it.getString("kind") == "run" })
        rack.close()
    }

    @Test fun `mode and subsequent timing edits preserve shared mode and timed values`() = runTest {
        val wire = Wire().apply { busy = false }
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject())
        rack.timing(FocusRackTimingEdit(durationMode = "fastest"))
        var transition = wire.requests.last().getJSONObject("timingUpdate")
        assertEquals("fastest", transition.getString("durationMode"))
        assertEquals(setOf("durationMode"), transition.keys().asSequence().toSet())
        assertEquals("timed", rack.state.value.durationMode) // Deliberately stale native snapshot.
        rack.timing(FocusRackTimingEdit(delay = "3", reverse = true))
        transition = wire.requests.last().getJSONObject("timingUpdate")
        assertFalse(transition.has("durationMode"))
        assertFalse(transition.has("duration"))
        assertEquals("bToA", transition.getString("direction"))
        assertEquals(3.0, transition.getDouble("delay"))
        rack.timing(FocusRackTimingEdit(durationMode = "timed"))
        assertEquals("timed", wire.requests.last().getJSONObject("timingUpdate").getString("durationMode"))
        rack.close()
    }

    @Test fun `stop acknowledges immediately while stale moving snapshots cannot clear it`() = runTest {
        val wire = Wire()
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject().put("frameSequence", 18).put("frameAgeSeconds", .1))
        assertEquals("moving", rack.state.value.phase)
        rack.stop()
        assertEquals("stop", wire.requests.last().getString("kind"))
        assertEquals("stopping", rack.state.value.phase)
        assertFalse(rack.state.value.primaryEnabled)
        wire.busy = false; wire.phase = "uncertain"
        rack.observe(JSONObject())
        assertEquals("uncertain", rack.state.value.phase)
        rack.close()
        assertTrue(wire.closed)
    }

    @Test fun `nudge progress uses shared percent and survives pending stop until settlement`() = runTest {
        val wire = Wire()
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject())
        assertNull(rack.state.value.nudgeProgress) // Older shared payloads omit the field.
        for (near in listOf(true, false)) {
            wire.nudgeProgress = JSONObject().put("towardNear", near).put("steps", 10).put("percent", 37)
            rack.observe(JSONObject())
            assertEquals(FocusRackNudgeProgressViewState(near, 10, 37), rack.state.value.nudgeProgress)
        }
        rack.stop()
        assertEquals("stopping", rack.state.value.phase)
        assertEquals(FocusRackNudgeProgressViewState(false, 10, 37), rack.state.value.nudgeProgress)
        wire.busy = false
        wire.phase = "stopped"
        wire.nudgeProgress = null
        rack.observe(JSONObject())
        assertNull(rack.state.value.nudgeProgress)
        assertFalse(rack.state.value.active)
        rack.close()
    }

    @Test fun `only validated timing bytes are persisted and restored`() = runTest {
        val prefs = TestSharedPreferences()
        val wire = Wire().apply {
            busy = false
            templates = """[{"name":"Slow","transition":{"fromMark":"A","toMark":"B","duration":24,"delay":2,"easing":"linear"}}]"""
        }
        val rack = FocusRackController(42, prefs,
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject())
        assertEquals(setOf("focusRack.timingTemplates.v1"), prefs.all.keys)
        val saved = prefs.getString("focusRack.timingTemplates.v1", null)!!
        assertEquals(wire.templates, saved)
        assertFalse(saved.contains("stepPosition"))
        assertFalse(saved.contains("captures"))
        assertFalse(saved.contains("phase"))
        rack.loadTemplate(rack.templates.value.single())
        assertEquals("loadTemplate", wire.requests.last().getString("kind"))
        assertEquals("Slow", wire.requests.last().getJSONObject("template").getString("name"))
        rack.close()
        val restoredWire = Wire()
        val restored = FocusRackController(42, prefs,
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), restoredWire)
        restored.activate()
        assertEquals(saved, restoredWire.createdTemplates)
        restored.close()
    }

    @Test fun `typed intent forwarding preserves timing and raw frame identity without platform timestamps`() = runTest {
        val wire = Wire()
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject().put("frameSequence", 19).put("frameAgeSeconds", .02))
        rack.timing(FocusRackTimingEdit(duration = "16.5", delay = "2.25", easing = "easeInOut", reverse = true))
        val request = wire.requests.last()
        val transition = request.getJSONObject("timingUpdate")
        assertEquals("bToA", transition.getString("direction"))
        assertEquals(16.5, transition.getDouble("duration"))
        assertEquals(2.25, transition.getDouble("delay"))
        assertEquals(19, request.getJSONObject("observation").getInt("frameSequence"))
        assertFalse(request.has("timestamp"))
        rack.nudge(true, 10)
        assertEquals(10, wire.requests.last().getInt("steps"))
        assertTrue(wire.requests.last().getBoolean("towardNear"))
        rack.primary()
        assertEquals(listOf("nudge", "primary"), wire.requests.takeLast(2).map { it.getString("kind") })
        rack.close()
        val count = wire.requests.size
        rack.primary()
        assertEquals(count, wire.requests.size)
    }
    @Test fun `explicit positioning uses its own shared intent after a timing edit`() = runTest {
        val wire = Wire().apply { busy = false }
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        rack.observe(JSONObject())
        rack.timing(FocusRackTimingEdit(duration = "10"))
        rack.goTo("B")
        val request = wire.requests.last()
        assertEquals("goTo", request.getString("kind"))
        assertEquals("B", request.getString("markID"))
        assertFalse(request.has("timingUpdate"))
        rack.close()
    }

    @Test fun `direct pull sends one atomic direction request`() = runTest {
        val wire = Wire().apply { busy = false }
        val rack = FocusRackController(42, TestSharedPreferences(),
            CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)), wire)
        rack.activate()
        val before = wire.requests.size
        rack.run("bToA")
        assertEquals(before + 1, wire.requests.size)
        assertEquals("run", wire.requests.last().getString("kind"))
        assertEquals("bToA", wire.requests.last().getString("direction"))
        assertFalse(wire.requests.last().has("timingUpdate"))
        rack.close()
    }
}
