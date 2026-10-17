package com.opencapture.openzcine.gyro

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Base64
import java.util.UUID

class GyroLogStoreTest {
    @Test fun `one damaged partial preserves saved logs and other recoverable files`() {
        val root = Files.createTempDirectory("gyro-store-test").toFile()
        try {
            val native = RecoveryNative()
            val store = GyroLogStore(root, native)
            val saved = descriptor()
            store.apply(reply(
                JSONObject().put("kind", "opened").put("id", saved.getString("id")).put("descriptor", saved),
                JSONObject().put("kind", "appended").put("id", saved.getString("id"))
                    .put("data", Base64.getEncoder().encodeToString("valid gyro".toByteArray())),
                JSONObject().put("kind", "finished").put("id", saved.getString("id"))
                    .put("summary", summary(saved, "normal")),
            ))
            val damaged = descriptor()
            File(root, "${damaged.getString("id")}.json").writeText(damaged.toString())
            File(root, "${damaged.getString("id")}.partial").writeBytes(byteArrayOf())
            val recoverable = descriptor()
            File(root, "${recoverable.getString("id")}.json").writeText(recoverable.toString())
            File(root, "${recoverable.getString("id")}.partial").writeText("valid gyro")
            assertTrue(runCatching { store.recover() }.isFailure)
            val entries = store.entries().associateBy { it.id }
            assertEquals(3, entries.size)
            assertTrue(entries.getValue(saved.getString("id")).canShare)
            assertEquals("Recovered · partial", entries.getValue(recoverable.getString("id")).health)
            val incomplete = entries.getValue(damaged.getString("id"))
            assertFalse(incomplete.canShare)
            assertNull(incomplete.summary)
            assertEquals("Incomplete file", incomplete.health)
            assertTrue(File(root, "${damaged.getString("id")}.partial").exists())
            assertTrue(File(root, recoverable.getString("filename")).isFile)
            assertTrue(native.openRecoveries.isEmpty())
            store.delete(incomplete)
            assertFalse(File(root, "${incomplete.id}.partial").exists())
            assertFalse(File(root, "${incomplete.id}.json").exists())
            assertEquals(2, store.entries().size)
            assertEquals("valid gyro", entries.getValue(saved.getString("id")).file.readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun `active log cannot be deleted and finalized bytes are retained`() {
        val root = Files.createTempDirectory("gyro-store-test").toFile()
        try {
            val store = GyroLogStore(root, RecoveryNative())
            val descriptor = descriptor()
            val id = descriptor.getString("id")
            store.apply(reply(JSONObject().put("kind", "opened").put("id", id).put("descriptor", descriptor)))
            val active = store.entries().single()
            assertTrue(active.active)
            assertFalse(active.canShare)
            assertEquals("Recording / post-roll", active.health)
            assertTrue(runCatching { store.delete(active) }.isFailure)
            store.apply(reply(
                JSONObject().put("kind", "appended").put("id", id)
                    .put("data", Base64.getEncoder().encodeToString("valid gyro".toByteArray())),
                JSONObject().put("kind", "finished").put("id", id).put("summary", summary(descriptor, "normal")),
            ))
            val entry = store.entries().single()
            assertFalse(entry.active)
            assertTrue(entry.canShare)
            assertEquals("valid gyro", entry.file.readText())
            store.delete(entry)
            assertTrue(store.entries().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun `damaged final metadata leaves that file deletable and healthy logs shareable`() {
        val root = Files.createTempDirectory("gyro-store-test").toFile()
        try {
            val store = GyroLogStore(root, RecoveryNative())
            val healthy = descriptor()
            val damaged = descriptor()
            for (descriptor in listOf(healthy, damaged)) {
                val id = descriptor.getString("id")
                File(root, "$id.json").writeText(descriptor.toString())
                File(root, descriptor.getString("filename")).writeText("valid gyro")
                File(root, "$id.summary.json").writeText(summary(descriptor, "normal").toString())
            }
            File(root, "${damaged.getString("id")}.summary.json").writeText("{broken")
            val entries = store.entries().associateBy { it.id }
            assertEquals(2, entries.size)
            assertTrue(entries.getValue(healthy.getString("id")).canShare)
            val incomplete = entries.getValue(damaged.getString("id"))
            assertFalse(incomplete.canShare)
            assertEquals("Incomplete file", incomplete.health)
            store.delete(incomplete)
            assertEquals(healthy.getString("id"), store.entries().single().id)
        } finally { root.deleteRecursively() }
    }

    @Test fun `failed append recovery keeps only persisted complete rows and their statistics`() {
        val root = Files.createTempDirectory("gyro-store-test").toFile()
        try {
            val native = RecoveryNative()
            val store = GyroLogStore(root, native) { file, bytes ->
                file.write(bytes, 0, 12)
                throw IOException("Injected partial write")
            }
            val descriptor = descriptor()
            val id = descriptor.getString("id")
            val intendedSummary = summary(descriptor, "normal").put("sampleCount", 100)
            assertTrue(runCatching { store.apply(reply(
                JSONObject().put("kind", "opened").put("id", id).put("descriptor", descriptor),
                JSONObject().put("kind", "appended").put("id", id)
                    .put("data", Base64.getEncoder().encodeToString("valid gyrotruncated row".toByteArray())),
                JSONObject().put("kind", "finished").put("id", id).put("summary", intendedSummary),
            )) }.isFailure)
            store.abort()
            val recovered = store.entries().single()
            assertEquals("valid gyro", recovered.file.readText())
            assertEquals(2, requireNotNull(recovered.summary).getInt("sampleCount"))
            assertEquals("Recovered · partial", recovered.health)
            assertTrue(recovered.canShare)
            assertFalse(recovered.active)
            assertTrue(native.openRecoveries.isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun `failed recovery after write error releases the incomplete file for deletion`() {
        val root = Files.createTempDirectory("gyro-store-test").toFile()
        try {
            val native = RecoveryNative()
            val store = GyroLogStore(root, native) { file, _ ->
                file.write("bad header".toByteArray())
                throw IOException("Injected write failure")
            }
            val descriptor = descriptor()
            val id = descriptor.getString("id")
            assertTrue(runCatching { store.apply(reply(
                JSONObject().put("kind", "opened").put("id", id).put("descriptor", descriptor),
                JSONObject().put("kind", "appended").put("id", id)
                    .put("data", Base64.getEncoder().encodeToString("valid gyro".toByteArray())),
            )) }.isFailure)
            assertTrue(runCatching { store.abort() }.isFailure)
            val incomplete = store.entries().single()
            assertFalse(incomplete.active)
            assertFalse(incomplete.canShare)
            assertEquals("bad header", incomplete.file.readText())
            assertTrue(native.openRecoveries.isEmpty())
            store.delete(incomplete)
            assertTrue(store.entries().isEmpty())
        } finally { root.deleteRecursively() }
    }

    private fun descriptor(): JSONObject {
        val id = UUID.randomUUID().toString().uppercase()
        return JSONObject().put("id", id).put("cameraLabel", "Test camera").put("startDate", 123_000)
            .put("filename", "$id.gcsv").put("approximateStartOffset", 2.0).put("isPartial", false)
    }

    private fun summary(descriptor: JSONObject, reason: String): JSONObject = JSONObject()
        .put("descriptor", descriptor).put("sampleCount", 2).put("duration", 0.01)
        .put("measuredRate", 100).put("largestGap", 0.01).put("rejectedSampleCount", 0)
        .put("approximateStartOffset", 2.0)
        .put("termination", reason).put("isPartial", reason != "normal")

    private fun reply(vararg updates: JSONObject): JSONObject = JSONObject().put("updates", JSONArray(updates.toList()))

    private inner class RecoveryNative : GyroNative {
        override fun mountPresets(naturalPortrait: Boolean): String = error("Not used")
        val openRecoveries = mutableMapOf<String, Boolean>()
        override fun recoveryCreate(): String = UUID.randomUUID().toString().also { openRecoveries[it] = false }
        override fun recoveryAccept(owner: String, bytes: ByteArray): Long {
            openRecoveries[owner] = bytes.toString(Charsets.UTF_8).startsWith("valid gyro")
            return if (openRecoveries[owner] == true) "valid gyro".length.toLong() else -1
        }
        override fun recoveryFinish(owner: String, descriptor: String): String? =
            if (openRecoveries.remove(owner) == true) summary(JSONObject(descriptor), "recovered").toString() else null
        override fun create(): String = error("Not used")
        override fun ingest(owner: String, bytes: ByteArray): String? = error("Not used")
        override fun observe(owner: String, recording: Boolean, timestamp: Double, dateSeconds: Double,
            cameraLabel: String, mountPreset: String, calibrationJSON: String): String? = error("Not used")
        override fun poll(owner: String, timestamp: Double): String? = error("Not used")
        override fun finish(owner: String, reason: String): String? = error("Not used")
        override fun close(owner: String) = Unit
    }
}
