package com.opencapture.openzcine.gyro

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
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
            assertEquals(2, store.entries().size)
            assertTrue(File(root, "${damaged.getString("id")}.partial").exists())
            assertTrue(File(root, recoverable.getString("filename")).isFile)
            assertTrue(native.openRecoveries.isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun `active log cannot be deleted and finalized bytes are retained`() {
        val root = Files.createTempDirectory("gyro-store-test").toFile()
        try {
            val store = GyroLogStore(root, RecoveryNative())
            val descriptor = descriptor()
            val id = descriptor.getString("id")
            store.apply(reply(JSONObject().put("kind", "opened").put("id", id).put("descriptor", descriptor)))
            assertTrue(runCatching { store.delete(GyroLogEntry(summary(descriptor, "normal"),
                File(root, descriptor.getString("filename")))) }.isFailure)
            store.apply(reply(
                JSONObject().put("kind", "appended").put("id", id)
                    .put("data", Base64.getEncoder().encodeToString("valid gyro".toByteArray())),
                JSONObject().put("kind", "finished").put("id", id).put("summary", summary(descriptor, "normal")),
            ))
            val entry = store.entries().single()
            assertEquals("valid gyro", entry.file.readText())
            store.delete(entry)
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
        .put("termination", reason).put("isPartial", reason != "normal")

    private fun reply(vararg updates: JSONObject): JSONObject = JSONObject().put("updates", JSONArray(updates.toList()))

    private inner class RecoveryNative : GyroNative {
        val openRecoveries = mutableMapOf<String, Boolean>()
        override fun recoveryCreate(): String = UUID.randomUUID().toString().also { openRecoveries[it] = false }
        override fun recoveryAccept(owner: String, bytes: ByteArray): Long {
            openRecoveries[owner] = bytes.contentEquals("valid gyro".toByteArray())
            return if (openRecoveries[owner] == true) bytes.size.toLong() else -1
        }
        override fun recoveryFinish(owner: String, descriptor: String): String? =
            if (openRecoveries.remove(owner) == true) summary(JSONObject(descriptor), "recovered").toString() else null
        override fun create(): String = error("Not used")
        override fun ingest(owner: String, bytes: ByteArray): String? = error("Not used")
        override fun observe(owner: String, recording: Boolean, timestamp: Double, dateSeconds: Double, cameraLabel: String): String? = error("Not used")
        override fun poll(owner: String, timestamp: Double): String? = error("Not used")
        override fun finish(owner: String, reason: String, timestamp: Double): String? = error("Not used")
        override fun close(owner: String) = Unit
    }
}
