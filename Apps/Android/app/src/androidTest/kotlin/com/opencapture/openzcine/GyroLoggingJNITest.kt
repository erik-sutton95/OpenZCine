package com.opencapture.openzcine

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.gyro.AndroidGyroSample
import com.opencapture.opencine.gyro.GyroNative
import com.opencapture.opencine.gyro.encodeGyroBatch
import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GyroLoggingJNITest {
    @Test fun nativeTakeExportsTimestampedGyroAndRetiresOwner() {
        assertTrue("The staged Swift library must be installed.", SwiftCore.isAvailable)
        assertTrue(GyroNative.isAvailable)
        val owner = GyroNative.loggingCreate("OpenZCine")
        try {
            GyroNative.loggingObserve(owner, false, 2.0, 123.0, "Test camera", "")
            GyroNative.loggingIngest(owner, encodeGyroBatch(List(200) { sample(it) }))
            val start = JSONObject(requireNotNull(
                GyroNative.loggingObserve(owner, true, 2.0, 123.0, "Test camera", "")))
            assertTrue(start.getBoolean("active"))
            val middle = JSONObject(requireNotNull(
                GyroNative.loggingIngest(owner, encodeGyroBatch(List(100) { sample(it + 200) }))))
            GyroNative.loggingObserve(owner, false, 3.0, 124.0, "Test camera", "")
            val finish = JSONObject(requireNotNull(
                GyroNative.loggingIngest(owner, encodeGyroBatch(List(201) { sample(it + 300) }))))
            val updates = finish.getJSONArray("updates")
            val summary = updates.getJSONObject(updates.length() - 1).getJSONObject("summary")
            assertEquals(501, summary.getInt("sampleCount"))
            assertEquals(5.0, summary.getDouble("duration"), 0.000001)
            assertEquals("normal", summary.getString("termination"))
            assertEquals("unconfigured", summary.getJSONObject("descriptor").getString("mountPreset"))
            assertFalse(finish.getBoolean("active"))
            val bytes = appendedBytes(start, middle, finish)
            assertTrue(bytes.toString(Charsets.UTF_8).contains("orientation,XYZ\n"))
            val recovery = GyroNative.recoveryCreate()
            assertEquals(bytes.size.toLong(), GyroNative.recoveryAccept(recovery, bytes))
            val recovered = JSONObject(requireNotNull(GyroNative.recoveryFinish(recovery,
                summary.getJSONObject("descriptor").toString(), Double.NaN)))
            assertEquals(501, recovered.getInt("sampleCount"))
        } finally { GyroNative.loggingClose(owner) }
        assertNull(GyroNative.loggingPoll(owner, 6.0))
    }

    @Test fun calibratedMountVerifiesThenTransformsExportsAndRecoversThroughJNI() {
        assertTrue(SwiftCore.isAvailable)
        assertFalse(GyroNative.calibrationValidate("{}"))
        val saved = completeRing()
        assertTrue(GyroNative.calibrationValidate(saved))
        val owner = GyroNative.loggingCreate("OpenZCine")
        try {
            GyroNative.loggingObserve(owner, false, 9.0, 123.0, "Test camera", "")
            GyroNative.loggingIngest(owner, encodeGyroBatch(List(200) {
                AndroidGyroSample(9.0 + it / 100.0, 1.0, 2.0, 3.0)
            }))
            val start = JSONObject(requireNotNull(GyroNative.loggingObserve(owner, true, 11.0, 125.0,
                "Test camera", saved)))
            GyroNative.loggingObserve(owner, false, 11.0, 125.0, "Test camera", saved)
            val finish = JSONObject(requireNotNull(
                GyroNative.loggingIngest(owner, encodeGyroBatch(List(201) {
                    AndroidGyroSample(11.0 + it / 100.0, 1.0, 2.0, 3.0)
                }))))
            val updates = finish.getJSONArray("updates")
            val summary = updates.getJSONObject(updates.length() - 1).getJSONObject("summary")
            val descriptor = summary.getJSONObject("descriptor")
            assertTrue(GyroNative.calibrationValidate(
                descriptor.getJSONObject("mountCalibration").toString()))
            val text = appendedBytes(start, finish).toString(Charsets.UTF_8)
            assertTrue(text.contains("orientation,XYZ\n"))
            assertTrue(text.contains(",-1.553729628,0.673574866,3.336498335\n"))
            val recovery = GyroNative.recoveryCreate()
            val bytes = appendedBytes(start, finish)
            assertEquals(bytes.size.toLong(), GyroNative.recoveryAccept(recovery, bytes))
            val recovered = JSONObject(requireNotNull(
                GyroNative.recoveryFinish(recovery, descriptor.toString(), Double.NaN)))
            assertTrue(GyroNative.calibrationValidate(recovered.getJSONObject("descriptor")
                .getJSONObject("mountCalibration").toString()))
        } finally { GyroNative.loggingClose(owner) }
    }

    @Test fun interruptedTakesFinalizeThroughJNI() {
        assertTrue(SwiftCore.isAvailable)
        for (reason in listOf("backgrounded", "disconnected", "sensorStalled")) {
            val owner = GyroNative.loggingCreate("OpenZCine")
            try {
                GyroNative.loggingObserve(owner, false, 0.0, 123.0, "Test camera", "")
                GyroNative.loggingIngest(owner, encodeGyroBatch((0 until 200).map(::sample)))
                GyroNative.loggingObserve(owner, true, 2.0, 125.0, "Test camera", "")
                GyroNative.loggingIngest(owner, encodeGyroBatch((200 until 210).map(::sample)))
                val finished = JSONObject(requireNotNull(GyroNative.loggingFinish(owner, reason)))
                assertTrue(finished.getBoolean("finished"))
                assertFalse(finished.getBoolean("active"))
                assertEquals(reason, finished.getString("termination"))
                val updates = finished.getJSONArray("updates")
                val summary = updates.getJSONObject(updates.length() - 1).getJSONObject("summary")
                assertEquals(reason, summary.getString("termination"))
                assertTrue(summary.getBoolean("isPartial"))
                assertEquals(210, summary.getInt("sampleCount"))
            } finally { GyroNative.loggingClose(owner) }
        }
    }

    private fun completeRing(): String {
        val owner = GyroNative.ringCreate()
        val phoneDown = listOf(
            doubleArrayOf(-0.650242925741664, 0.7144469826058991, 0.25835952966408415),
            doubleArrayOf(-0.32094868811558713, 0.6826561820666128, 0.6564849401799853),
            doubleArrayOf(0.2024125651194706, 0.9226911384671543, 0.32813140123423484),
        )
        var calibration: String? = null
        try {
            GyroNative.ringStart(owner, true, 0)
            for (pose in 0..2) {
                val camera = JSONObject(requireNotNull(GyroNative.cameraDown(
                    if (pose == 2) 45.0 else 0.0,
                    when (pose) {
                        0 -> 0.0
                        2 -> 39.23152048359226
                        else -> 30.0
                    },
                )))
                val vector = phoneDown[pose]
                for (index in 0 until 90) {
                    val timestamp = pose * 3.0 + index / 30.0
                    val reply = GyroNative.ringObserve(
                        owner, vector[0], vector[1], vector[2], timestamp,
                        true, camera.getDouble("x"), camera.getDouble("y"), camera.getDouble("z"),
                        timestamp,
                    )?.let(::JSONObject)
                    if (reply?.optString("event") == "completed") {
                        calibration = reply.getJSONObject("calibration").toString()
                    }
                }
            }
            return requireNotNull(calibration)
        } finally { GyroNative.ringClose(owner) }
    }

    private fun appendedBytes(vararg replies: JSONObject): ByteArray =
        replies.flatMap { reply ->
            val values = reply.getJSONArray("updates")
            (0 until values.length()).map { values.getJSONObject(it) }
                .filter { it.getString("kind") == "appended" }
                .flatMap { Base64.getDecoder().decode(it.getString("data")).toList() }
        }.toByteArray()

    private fun sample(index: Int): AndroidGyroSample =
        AndroidGyroSample(index / 100.0, 1.0, 2.0, 3.0)
}
