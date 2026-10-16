package com.opencapture.openzcine

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.gyro.AndroidGyroSample
import com.opencapture.openzcine.gyro.encodeGyroBatch
import com.opencapture.openzcine.gyro.decodeGyroMountPresets
import com.opencapture.openzcine.gyro.GyroCalibrationSession
import com.opencapture.openzcine.gyro.SwiftGyroCalibrationNative
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Base64

@RunWith(AndroidJUnit4::class)
class GyroLoggingJNITest {
    @Test fun nativeTakeExportsTimestampedGyroAndRetiresOwner() {
        assertTrue("The staged Swift library must be installed.", SwiftCore.isAvailable)
        assertEquals(listOf("unconfigured"), decodeGyroMountPresets(SwiftCore.gyroMountPresets(false)).map { it.id })
        val mount = decodeGyroMountPresets(SwiftCore.gyroMountPresets(true)).first { it.id == "rearLeft" }
        val owner = SwiftCore.gyroCreate()
        try {
            assertNull(SwiftCore.gyroObserve(owner, false, 2.0, 123.0, "Test camera", "unknown"))
            SwiftCore.gyroObserve(owner, false, 2.0, 123.0, "Test camera")
            SwiftCore.gyroIngest(owner, encodeGyroBatch(List(200) { sample(it) }))
            val start = JSONObject(requireNotNull(SwiftCore.gyroObserve(owner, true, 2.0, 123.0, "Test camera", mount.id)))
            assertTrue(start.getBoolean("active"))
            val middle = JSONObject(requireNotNull(SwiftCore.gyroIngest(owner, encodeGyroBatch(List(100) { sample(it + 200) }))))
            SwiftCore.gyroObserve(owner, false, 3.0, 124.0, "Test camera", "frontUp")
            val finish = JSONObject(requireNotNull(SwiftCore.gyroIngest(owner, encodeGyroBatch(List(201) { sample(it + 300) }))))
            val updates = finish.getJSONArray("updates")
            val summary = updates.getJSONObject(updates.length() - 1).getJSONObject("summary")
            assertEquals(501, summary.getInt("sampleCount"))
            assertEquals(5.0, summary.getDouble("duration"), 0.000001)
            assertEquals("normal", summary.getString("termination"))
            assertEquals(mount.id, summary.getJSONObject("descriptor").getString("mountPreset"))
            assertFalse(finish.getBoolean("active"))
            val bytes = listOf(start, middle, finish).flatMap { reply ->
                val values = reply.getJSONArray("updates")
                (0 until values.length()).map { values.getJSONObject(it) }
                    .filter { it.getString("kind") == "appended" }
                    .flatMap { Base64.getDecoder().decode(it.getString("data")).toList() }
            }.toByteArray()
            assertTrue(bytes.toString(Charsets.UTF_8).contains("orientation,${mount.orientation}\n"))
            val recovery = SwiftCore.gyroRecoveryCreate()
            assertEquals(bytes.size.toLong(), SwiftCore.gyroRecoveryAccept(recovery, bytes))
            val recovered = JSONObject(requireNotNull(SwiftCore.gyroRecoveryFinish(recovery,
                summary.getJSONObject("descriptor").toString())))
            assertEquals(mount.id, recovered.getJSONObject("descriptor").getString("mountPreset"))
            assertEquals(501, recovered.getInt("sampleCount"))
        } finally { SwiftCore.gyroClose(owner) }
        assertNull(SwiftCore.gyroPoll(owner, 6.0))
    }

    @Test fun calibratedMountVerifiesThenTransformsExportsAndRecoversThroughJNI() {
        assertTrue(SwiftCore.isAvailable)
        assertFalse(SwiftCore.gyroCalibrationValidate("{}"))
        val calibration = GyroCalibrationSession(SwiftGyroCalibrationNative)
        calibration.start()
        val phoneDown = listOf(
            doubleArrayOf(-0.650242925741664, 0.7144469826058991, 0.25835952966408415),
            doubleArrayOf(-0.32094868811558713, 0.6826561820666128, 0.6564849401799853),
            doubleArrayOf(0.2024125651194706, 0.9226911384671543, 0.32813140123423484),
        )
        try {
            for (pose in 0..2) {
                val base = pose * 2.0
                val vector = phoneDown[pose]
                for (index in 0 until 40) {
                    calibration.add(JSONObject().put("phoneDown", JSONObject()
                        .put("x", vector[0]).put("y", vector[1]).put("z", vector[2]))
                        .put("phoneTimestamp", base + index / 30.0)
                        .put("rollDegrees", if (pose == 2) 45.0 else 0.0)
                        .put("pitchDegrees", if (pose == 0) 0.0 else 30.0)
                        .put("cameraTimestamp", base + (index / 6) / 5.0).toString())
                }
                calibration.capture(base + 1.3)
                assertNull(calibration.state.error)
                if (pose < 2) assertNull(calibration.state.calibration)
            }
            val saved = requireNotNull(calibration.state.calibration)
            assertTrue(SwiftCore.gyroCalibrationValidate(saved))
            val owner = SwiftCore.gyroCreate()
            try {
                assertNull(SwiftCore.gyroObserve(owner, false, 9.0, 123.0, "Test camera", "unconfigured", "{}"))
                SwiftCore.gyroObserve(owner, false, 9.0, 123.0, "Test camera")
                SwiftCore.gyroIngest(owner, encodeGyroBatch(List(200) {
                    AndroidGyroSample(9.0 + it / 100.0, 1.0, 2.0, 3.0)
                }))
                val start = JSONObject(requireNotNull(SwiftCore.gyroObserve(owner, true, 11.0, 125.0,
                    "Test camera", "rearLeft", saved)))
                SwiftCore.gyroObserve(owner, false, 11.0, 125.0, "Test camera", "frontUp")
                val finish = JSONObject(requireNotNull(SwiftCore.gyroIngest(owner, encodeGyroBatch(List(201) {
                    AndroidGyroSample(11.0 + it / 100.0, 1.0, 2.0, 3.0)
                }))))
                val updates = finish.getJSONArray("updates")
                val summary = updates.getJSONObject(updates.length() - 1).getJSONObject("summary")
                val descriptor = summary.getJSONObject("descriptor")
                assertEquals("rearLeft", descriptor.getString("mountPreset"))
                assertTrue(SwiftCore.gyroCalibrationValidate(descriptor.getJSONObject("mountCalibration").toString()))
                val bytes = listOf(start, finish).flatMap { reply ->
                    val values = reply.getJSONArray("updates")
                    (0 until values.length()).map { values.getJSONObject(it) }
                        .filter { it.getString("kind") == "appended" }
                        .flatMap { Base64.getDecoder().decode(it.getString("data")).toList() }
                }.toByteArray()
                val text = bytes.toString(Charsets.UTF_8)
                assertTrue(text.contains("orientation,XYZ\n"))
                assertTrue(text.contains(",-1.553729628,0.673574866,3.336498335\n"))
                val recovery = SwiftCore.gyroRecoveryCreate()
                assertEquals(bytes.size.toLong(), SwiftCore.gyroRecoveryAccept(recovery, bytes))
                val recovered = JSONObject(requireNotNull(SwiftCore.gyroRecoveryFinish(recovery, descriptor.toString())))
                assertTrue(SwiftCore.gyroCalibrationValidate(recovered.getJSONObject("descriptor")
                    .getJSONObject("mountCalibration").toString()))
            } finally { SwiftCore.gyroClose(owner) }
        } finally { calibration.cancel() }
    }

    private fun sample(index: Int): AndroidGyroSample = AndroidGyroSample(index / 100.0, 1.0, 2.0, 3.0)
}
