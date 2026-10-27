package com.opencapture.openzcine

import com.opencapture.opencine.gyro.FakeGyroNative
import com.opencapture.opencine.gyro.GyroLogStore
import com.opencapture.opencine.gyro.GyroPreferences
import com.opencapture.opencine.gyro.GyroTakeStatus
import com.opencapture.opencine.gyro.MemorySharedPreferences
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import org.json.JSONObject

class GyroAdoptionTest {
    private val root = Files.createTempDirectory("openzcine-gyro-adoption").toFile()

    @AfterTest
    fun cleanup() {
        root.deleteRecursively()
    }

    @Test
    fun upgradeKeepsLogsToggleAndCalibration() {
        val host = openZCineGyroHostConfiguration(root)
        assertEquals("OpenZCine", host.appName)
        assertEquals(File(root, "gyro-logs"), host.logRoot)
        assertEquals("gyro-logging", host.preferencesName)
        val native = FakeGyroNative()
        val prefs = MemorySharedPreferences()
        val legacy = requireNotNull(host.legacy)
        prefs.edit()
            .putBoolean(legacy.enabled, true)
            .putString(legacy.mountPreset, "rearDown")
            .putString(legacy.calibration, FakeGyroNative.DEFAULT_CALIBRATION)
            .apply()
        writeFinishedTake(host.logRoot)
        writeInterruptedTake(host.logRoot)

        val preferences = GyroPreferences(prefs, host.keys, host.legacy, native)
        val store = GyroLogStore(host.logRoot, native)
        store.recover()

        assertTrue(preferences.enabled)
        assertFalse(prefs.contains(legacy.mountPreset))
        assertEquals(
            JSONObject(FakeGyroNative.DEFAULT_CALIBRATION).toString(),
            preferences.calibrationJSON("nikon-123")?.let(::JSONObject)?.toString(),
        )
        assertNull(preferences.calibrationJSON("nikon-456"))
        val entries = store.entries().associateBy { it.id }
        assertEquals(2, entries.size)
        assertEquals(GyroTakeStatus.NotCalibrated, entries.getValue(FINISHED_ID).status)
        assertEquals(GyroTakeStatus.CutShort, entries.getValue(INTERRUPTED_ID).status)
        assertNotNull(entries.getValue(INTERRUPTED_ID).summary)
    }

    @Test
    fun disconnectRestoresBeforeClosing() = runTest {
        val events = mutableListOf<String>()

        disconnectAfterGyroPreparation(
            isArmed = true,
            prepare = { events += "prepare" },
            disconnect = { events += "disconnect" },
        )

        assertEquals(listOf("prepare", "disconnect"), events)
    }

    @Test
    fun unarmedDisconnectDoesNotPrepare() = runTest {
        val events = mutableListOf<String>()

        disconnectAfterGyroPreparation(
            isArmed = false,
            prepare = { events += "prepare" },
            disconnect = { events += "disconnect" },
        )

        assertEquals(listOf("disconnect"), events)
    }

    @Test
    fun cleanModeKeepsGyroTakeWarnings() {
        assertTrue(gyroPillVisibleInCleanMode(com.opencapture.opencine.gyro.GyroPillKind.MOUNT_MOVED))
        assertTrue(gyroPillVisibleInCleanMode(com.opencapture.opencine.gyro.GyroPillKind.GAPS))
        assertTrue(gyroPillVisibleInCleanMode(com.opencapture.opencine.gyro.GyroPillKind.ERROR))
        assertFalse(gyroPillVisibleInCleanMode(com.opencapture.opencine.gyro.GyroPillKind.RECORDING))
    }

    private fun writeFinishedTake(root: File) {
        if (!root.exists()) check(root.mkdirs())
        val descriptor = descriptor(FINISHED_ID)
        File(root, "$FINISHED_ID.json").writeText(descriptor.toString())
        File(root, descriptor.getString("filename")).writeText(FakeGyroNative.HEADER)
        File(root, "$FINISHED_ID.summary.json").writeText(summary(descriptor, "normal").toString())
    }

    private fun writeInterruptedTake(root: File) {
        if (!root.exists()) check(root.mkdirs())
        val descriptor = descriptor(INTERRUPTED_ID)
        File(root, "$INTERRUPTED_ID.json").writeText(descriptor.toString())
        File(root, "$INTERRUPTED_ID.partial").writeText(FakeGyroNative.HEADER)
    }

    private fun descriptor(id: String): JSONObject =
        JSONObject()
            .put("id", id)
            .put("cameraLabel", "Nikon ZR")
            .put("writer", "OpenZCine")
            .put("startDate", 1_760_000_000_000.0)
            .put("filename", "OpenZCine-$id.gcsv")
            .put("approximateStartOffset", 2.0)
            .put("isPartial", false)
            .put("mountPreset", "unconfigured")

    private fun summary(descriptor: JSONObject, termination: String): JSONObject =
        JSONObject()
            .put("descriptor", descriptor)
            .put("sampleCount", 0)
            .put("duration", 0.0)
            .put("measuredRate", 100.0)
            .put("largestGap", 0.0)
            .put("rejectedSampleCount", 0)
            .put("termination", termination)
            .put("isPartial", termination != "normal")
            .put("approximateStartOffset", 2.0)

    private companion object {
        const val FINISHED_ID = "11111111-1111-1111-1111-111111111111"
        const val INTERRUPTED_ID = "22222222-2222-2222-2222-222222222222"
    }
}
