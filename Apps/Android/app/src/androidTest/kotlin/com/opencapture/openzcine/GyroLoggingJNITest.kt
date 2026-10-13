package com.opencapture.openzcine

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.gyro.AndroidGyroSample
import com.opencapture.openzcine.gyro.encodeGyroBatch
import com.opencapture.openzcine.gyro.decodeGyroMountPresets
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

    private fun sample(index: Int): AndroidGyroSample = AndroidGyroSample(index / 100.0, 1.0, 2.0, 3.0)
}
