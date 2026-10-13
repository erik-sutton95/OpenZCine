package com.opencapture.openzcine.gyro

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Base64
import java.util.UUID

/** A finalized, app-private motion artifact and its shared-core summary. */
internal data class GyroLogEntry(val summary: JSONObject, val file: File) {
    val descriptor: JSONObject get() = summary.getJSONObject("descriptor")
    val id: String get() = descriptor.getString("id")
    val cameraLabel: String get() = descriptor.getString("cameraLabel")
    val startDateMillis: Long get() = descriptor.getDouble("startDate").toLong()
    val duration: Double get() = summary.getDouble("duration")
    val partial: Boolean get() = summary.getBoolean("isPartial")
}

/** Native files only: take boundaries, GCSV encoding and recovery validation stay in Swift. */
internal class GyroLogStore(private val root: File, private val native: GyroNative) {
    private val writers = mutableMapOf<String, RandomAccessFile>()
    private var lastFlush = 0L

    init { if (!root.exists() && !root.mkdirs()) throw IOException("Could not create gyro storage.") }

    fun apply(reply: JSONObject) {
        val updates = reply.getJSONArray("updates")
        for (index in 0 until updates.length()) {
            val update = updates.getJSONObject(index)
            val id = UUID.fromString(update.getString("id")).toString().uppercase()
            when (update.getString("kind")) {
                "opened" -> {
                    val descriptor = update.getJSONObject("descriptor")
                    atomicWrite(File(root, "$id.json"), descriptor.toString())
                    writers[id] = RandomAccessFile(File(root, "$id.partial"), "rw")
                }
                "appended" -> {
                    val writer = writers[id] ?: throw IOException("Gyro log is not open.")
                    writer.write(Base64.getDecoder().decode(update.getString("data")))
                }
                "finished" -> finish(id, update.getJSONObject("summary"))
            }
        }
    }

    fun flush(nowMillis: Long) {
        if (nowMillis - lastFlush < 1_000) return
        writers.values.forEach { it.fd.sync() }
        lastFlush = nowMillis
    }

    fun close() {
        writers.values.forEach { writer -> runCatching { writer.fd.sync() }; runCatching { writer.close() } }
        writers.clear()
    }

    fun entries(): List<GyroLogEntry> = root.listFiles().orEmpty()
        .filter { it.name.endsWith(".summary.json") }
        .map { file ->
            val summary = JSONObject(file.readText())
            val filename = summary.getJSONObject("descriptor").getString("filename")
            require(File(filename).name == filename) { "Invalid gyro filename." }
            GyroLogEntry(summary, File(root, filename))
        }.filter { it.file.isFile }.sortedByDescending { it.startDateMillis }

    fun delete(entry: GyroLogEntry) {
        check(!writers.containsKey(entry.id)) { "A recording gyro log cannot be deleted." }
        if (!entry.file.delete()) throw IOException("Could not delete the gyro log.")
        File(root, "${entry.id}.summary.json").delete()
        File(root, "${entry.id}.json").delete()
    }

    fun recover() {
        var failures = 0
        for (file in root.listFiles().orEmpty().filter { it.name.endsWith(".partial") }) {
            try { recoverFile(file) } catch (_: Exception) { failures += 1 }
        }
        if (failures > 0) throw IOException("Some interrupted gyro logs could not be recovered. Saved logs remain available.")
    }

    private fun recoverFile(file: File) {
            val id = UUID.fromString(file.name.removeSuffix(".partial")).toString().uppercase()
            val descriptor = File(root, "$id.json").readText()
            val owner = native.recoveryCreate()
            var validLength = 0L
            var summary: String? = null
            try {
                file.inputStream().use { input ->
                    val buffer = ByteArray(16_384)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        validLength = native.recoveryAccept(owner, buffer.copyOf(count))
                        if (validLength < 0) throw IOException("The partial gyro log has an invalid header.")
                    }
                }
            } finally { summary = native.recoveryFinish(owner, descriptor) }
            val recovered = summary ?: throw IOException("The partial gyro log could not be recovered.")
            RandomAccessFile(file, "rw").use { it.setLength(validLength); it.fd.sync() }
            finish(id, JSONObject(recovered))
    }

    private fun finish(id: String, summary: JSONObject) {
        writers.remove(id)?.let { writer -> try { writer.fd.sync() } finally { writer.close() } }
        val filename = summary.getJSONObject("descriptor").getString("filename")
        require(File(filename).name == filename) { "Invalid gyro filename." }
        val partial = File(root, "$id.partial")
        val destination = File(root, filename)
        atomicWrite(File(root, "$id.summary.json"), summary.toString())
        if (!partial.renameTo(destination)) throw IOException("Could not finish the gyro log.")
    }

    private fun atomicWrite(destination: File, value: String) {
        val temporary = File(root, "${destination.name}.tmp")
        temporary.outputStream().use { output -> output.write(value.toByteArray()); output.fd.sync() }
        if (!temporary.renameTo(destination)) throw IOException("Could not save gyro metadata.")
    }
}
