package com.opencapture.openzcine.frameio

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Bounded response returned by the Android HTTPS transport adapter. */
internal class FrameioHttpResponse(val statusCode: Int, val body: String) {
    // Adobe token responses and Frame.io error bodies must never be interpolated into logs.
    override fun toString(): String = "FrameioHttpResponse(statusCode=$statusCode, body=redacted)"
}

/** Android HTTPS I/O seam; endpoint and OAuth policy remain in the Swift core. */
internal interface FrameioHttpClient {
    suspend fun execute(
        request: FrameioHttpRequest,
        bearerToken: String? = null,
        contentType: String? = null,
    ): FrameioHttpResponse

    suspend fun putUploadPart(
        uploadURL: String,
        source: Path,
        offset: Long,
        byteCount: Long,
        contentType: String,
        /**
         * Reports bytes written for this part. The transport calls this from
         * its I/O context, so the suspend seam lets a UI owner return state
         * mutations to its UI dispatcher before the callback completes.
         */
        onBytesSent: suspend (Long) -> Unit,
    ): FrameioHttpResponse
}

/**
 * `HttpURLConnection` transport for Adobe IMS, Frame.io V4, and Frame.io's
 * HTTPS pre-signed upload URLs. It never logs authorization headers, form
 * data, callback codes, tokens, or media paths.
 */
internal object AndroidFrameioHttpClient : FrameioHttpClient {
    override suspend fun execute(
        request: FrameioHttpRequest,
        bearerToken: String?,
        contentType: String?,
    ): FrameioHttpResponse =
        withContext(Dispatchers.IO) {
            val coroutineContext = currentCoroutineContext()
            coroutineContext.ensureActive()
            val connection = openHTTPS(request.url)
            try {
                connection.requestMethod = request.method
                connection.setRequestProperty("Accept", "application/json")
                bearerToken?.let { token ->
                    require(token.isSafeHeaderValue()) { "Frame.io requires a safe bearer token." }
                    connection.setRequestProperty("Authorization", "Bearer $token")
                }
                request.body?.let { body ->
                    connection.doOutput = true
                    connection.setRequestProperty(
                        "Content-Type",
                        contentType ?: "application/json; charset=utf-8",
                    )
                    val bytes = body.toByteArray(Charsets.UTF_8)
                    connection.setFixedLengthStreamingMode(bytes.size)
                    connection.outputStream.use { stream -> stream.write(bytes) }
                }
                coroutineContext.ensureActive()
                FrameioHttpResponse(connection.responseCode, connection.readBoundedResponse())
            } finally {
                connection.disconnect()
            }
        }

    override suspend fun putUploadPart(
        uploadURL: String,
        source: Path,
        offset: Long,
        byteCount: Long,
        contentType: String,
        onBytesSent: suspend (Long) -> Unit,
    ): FrameioHttpResponse =
        withContext(Dispatchers.IO) {
            val coroutineContext = currentCoroutineContext()
            coroutineContext.ensureActive()
            require(byteCount > 0) { "Upload part byte count must be positive." }
            val sourcePath = source.toAbsolutePath().normalize()
            require(
                Files.isRegularFile(sourcePath, LinkOption.NOFOLLOW_LINKS) &&
                    !Files.isSymbolicLink(sourcePath),
            ) { "Frame.io source must be a regular approved cache artifact." }
            val sourceSize = Files.size(sourcePath)
            require(offset >= 0 && offset <= sourceSize && byteCount <= sourceSize - offset) {
                "Frame.io upload part exceeds its approved source artifact."
            }
            require(contentType.isSafeMediaType()) { "Frame.io requires a safe media type." }

            val connection = openHTTPS(uploadURL)
            try {
                connection.requestMethod = "PUT"
                connection.doOutput = true
                connection.setRequestProperty("x-amz-acl", "private")
                connection.setRequestProperty("Content-Type", contentType)
                connection.setFixedLengthStreamingMode(byteCount)
                FileChannel.open(sourcePath, StandardOpenOption.READ).use { channel ->
                    channel.position(offset)
                    connection.outputStream.use { output ->
                        val buffer = ByteBuffer.allocate(COPY_BUFFER_BYTES)
                        var remaining = byteCount
                        var sent = 0L
                        while (remaining > 0) {
                            coroutineContext.ensureActive()
                            buffer.clear()
                            buffer.limit(minOf(buffer.capacity().toLong(), remaining).toInt())
                            val count = channel.read(buffer)
                            if (count <= 0) throw IOException("Approved upload source ended early.")
                            output.write(buffer.array(), 0, count)
                            remaining -= count.toLong()
                            sent += count.toLong()
                            onBytesSent(sent)
                        }
                    }
                }
                coroutineContext.ensureActive()
                FrameioHttpResponse(connection.responseCode, connection.readBoundedResponse())
            } finally {
                connection.disconnect()
            }
        }

    private fun openHTTPS(value: String): HttpsURLConnection {
        require(value.isHTTPS()) { "Frame.io requires an absolute HTTPS URL without user info or fragments." }
        val url = URI(value).toURL()
        return (url.openConnection() as? HttpsURLConnection)
            ?.apply {
                connectTimeout = REQUEST_TIMEOUT_MILLIS
                readTimeout = REQUEST_TIMEOUT_MILLIS
                instanceFollowRedirects = false
            }
            ?: throw IOException("Frame.io URL did not open an HTTPS connection.")
    }

    private fun HttpURLConnection.readBoundedResponse(): String {
        val stream = if (responseCode in 200..299) inputStream else errorStream
        return stream?.use { input -> input.readUtf8Bounded(MAXIMUM_RESPONSE_BYTES) }.orEmpty()
    }

    private fun java.io.InputStream.readUtf8Bounded(maximumBytes: Int): String {
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        val output = ByteArrayOutputStream()
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            if (output.size() > maximumBytes - count) {
                throw IOException("Frame.io response exceeded the safe response limit.")
            }
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private const val REQUEST_TIMEOUT_MILLIS = 20_000
    private const val COPY_BUFFER_BYTES = 128 * 1024
    private const val MAXIMUM_RESPONSE_BYTES = 1_048_576
}
