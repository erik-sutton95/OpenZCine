package com.opencapture.openzcine.gyro

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class GyroCalibrationSessionTest {
    @Test fun `only a validated independent third pose publishes a result and retires its owner`() {
        val native = CalibrationNative()
        val session = GyroCalibrationSession(native)
        session.start()
        session.add("observation copied from sensors")
        assertEquals("observation copied from sensors", native.observation)
        for (count in 1..2) {
            native.reply = reply(count)
            session.capture(count.toDouble())
            assertTrue(session.state.active)
            assertNull(session.state.calibration)
            assertTrue(native.closed.isEmpty())
        }
        native.reply = reply(2, error = "Hold still and verify again.")
        session.capture(3.0)
        assertEquals(2, session.state.poseCount)
        assertEquals("Hold still and verify again.", session.state.error)
        native.reply = reply(2)
        session.add("fresh readings do not erase the capture error")
        assertEquals("Hold still and verify again.", session.state.error)
        native.reply = reply(3, calibration = JSONObject().put("opaqueCoreValue", 1))
        session.capture(4.0)
        assertFalse(session.state.active)
        assertEquals("{\"opaqueCoreValue\":1}", session.state.calibration)
        assertEquals(listOf("owner-1"), native.closed)
        session.cancel()
        assertEquals(listOf("owner-1"), native.closed)
    }

    @Test fun `cancel and restart cannot reuse a retired owner or old observations`() {
        val native = CalibrationNative()
        val session = GyroCalibrationSession(native)
        session.start()
        session.cancel()
        session.add("late sensor callback")
        session.capture(1.0)
        assertNull(native.observation)
        assertEquals(0, native.captures)
        session.start()
        session.start()
        assertEquals(listOf("owner-1", "owner-2"), native.closed)
        session.capture(2.0)
        assertEquals("owner-3", native.captureOwner)
    }

    @Test fun `unvalidated or premature native results are never exposed`() {
        for (count in listOf(2, 3)) {
            val native = CalibrationNative().apply {
                valid = false
                reply = this@GyroCalibrationSessionTest.reply(count, calibration = JSONObject().put("opaqueCoreValue", 1))
            }
            val session = GyroCalibrationSession(native)
            session.start()
            assertTrue(runCatching { session.capture(1.0) }.isFailure)
            assertNull(session.state.calibration)
            session.cancel()
            assertEquals(listOf("owner-1"), native.closed)
        }
    }

    @Test fun `camera clock conversion preserves frame age across device sleep`() {
        val camera = cameraCalibrationTimestamp(42_000_000_000, 145_000_000_000, 45_000_000_000)
        assertEquals(142.0, camera, 0.0)
        assertEquals(3.0, 145.0 - camera, 0.0)
        assertEquals(42.0, cameraCalibrationTimestamp(42_000_000_000, 45_000_000_000, 45_000_000_000), 0.0)
    }

    private fun reply(count: Int, calibration: JSONObject? = null, error: String? = null): String =
        JSONObject().put("poseCount", count).put("calibration", calibration ?: JSONObject.NULL)
            .put("error", error ?: JSONObject.NULL).toString()

    private inner class CalibrationNative : GyroCalibrationNative {
        var reply: String = this@GyroCalibrationSessionTest.reply(0)
        var valid = true
        var observation: String? = null
        var captures = 0
        var captureOwner: String? = null
        val closed = mutableListOf<String>()
        private var created = 0
        override fun create(): String = "owner-${++created}"
        override fun add(owner: String, observationJSON: String): String? {
            observation = observationJSON
            return reply
        }
        override fun capture(owner: String, timestamp: Double): String? {
            ++captures
            captureOwner = owner
            return reply
        }
        override fun close(owner: String) { closed += owner }
        override fun validate(calibrationJSON: String): Boolean = valid
    }
}
