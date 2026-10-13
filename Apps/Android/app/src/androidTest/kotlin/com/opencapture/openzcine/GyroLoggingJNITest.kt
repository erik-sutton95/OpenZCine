package com.opencapture.openzcine

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.gyro.AndroidGyroSample
import com.opencapture.openzcine.gyro.encodeGyroBatch
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GyroLoggingJNITest {
    @Test fun nativeTakeExportsTimestampedGyroAndRetiresOwner() {
        assertTrue("The staged Swift library must be installed.", SwiftCore.isAvailable)
        val owner = SwiftCore.gyroCreate()
        try {
            SwiftCore.gyroObserve(owner, false, 2.0, 123.0, "Test camera")
            SwiftCore.gyroIngest(owner, encodeGyroBatch(List(200) { sample(it) }))
            val start = JSONObject(requireNotNull(SwiftCore.gyroObserve(owner, true, 2.0, 123.0, "Test camera")))
            assertTrue(start.getBoolean("active"))
            SwiftCore.gyroIngest(owner, encodeGyroBatch(List(100) { sample(it + 200) }))
            SwiftCore.gyroObserve(owner, false, 3.0, 124.0, "Test camera")
            val finish = JSONObject(requireNotNull(SwiftCore.gyroIngest(owner, encodeGyroBatch(List(201) { sample(it + 300) }))))
            val updates = finish.getJSONArray("updates")
            val summary = updates.getJSONObject(updates.length() - 1).getJSONObject("summary")
            assertEquals(501, summary.getInt("sampleCount"))
            assertEquals(5.0, summary.getDouble("duration"), 0.000001)
            assertEquals("normal", summary.getString("termination"))
            assertFalse(finish.getBoolean("active"))
        } finally { SwiftCore.gyroClose(owner) }
        assertNull(SwiftCore.gyroPoll(owner, 6.0))
    }

    private fun sample(index: Int): AndroidGyroSample = AndroidGyroSample(index / 100.0, 1.0, 2.0, 3.0)
}
