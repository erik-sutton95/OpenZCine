package com.opencapture.openzcine.gyro

import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Owns cancellable staging until Main hands a unique, complete copy to the chooser. */
internal fun shareGyroLog(scope: CoroutineScope, cacheDirectory: File, entry: GyroLogEntry,
    onReady: (File) -> Unit, onFailure: (Exception) -> Unit,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO): Job = scope.launch(Dispatchers.Main.immediate) {
    var ownedDirectory: File? = null
    var shared = false
    try {
        check(entry.canShare) { "This gyro log is not finalized." }
        val staged = withContext(ioDispatcher) {
            ensureActive()
            val id = UUID.randomUUID().toString()
            val staging = File(cacheDirectory, "share/staging/gyro/$id")
            ownedDirectory = staging
            createGyroShareDirectory(staging)
            copyGyroLog(entry.file, File(staging, entry.file.name)) { ensureActive() }
            val ready = File(cacheDirectory, "share/ready/gyro/$id")
            createGyroShareDirectory(ready.parentFile ?: throw IOException("Missing share directory."))
            ensureActive()
            if (!staging.renameTo(ready)) throw IOException("Could not publish the gyro share copy.")
            ownedDirectory = ready
            File(ready, entry.file.name)
        }
        ensureActive()
        onReady(staged)
        // Readers own the published bytes after launch, including across activity replacement.
        shared = true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        ensureActive()
        onFailure(failure)
    } finally {
        if (!shared) withContext(NonCancellable + ioDispatcher) { ownedDirectory?.deleteRecursively() }
    }
}

private fun createGyroShareDirectory(directory: File) {
    if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Could not create gyro share storage.")
}

private fun copyGyroLog(source: File, destination: File, ensureCurrent: () -> Unit) {
    source.inputStream().use { input ->
        destination.outputStream().use { output ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                ensureCurrent()
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
            }
        }
    }
}
