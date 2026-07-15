package com.opencapture.openzcine.frameio

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.net.URL
import java.nio.file.Files
import java.security.cert.Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

class FrameioHttpClientTest {
    @Test
    fun `stalled upload write disconnects and reports a sanitized timeout`() = runBlocking {
        val source = Files.createTempFile("frameio-http", ".mp4")
        try {
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val output = BlockingOutputStream()
            val connection = FakeHttpsConnection(output)
            val client =
                UrlConnectionFrameioHttpClient(
                    connectionFactory = { connection },
                    uploadWriteTimeoutMillis = 50L,
                )

            val failure =
                runCatching {
                    withTimeout(1_000L) {
                        client.putUploadPart(
                            uploadURL = "https://uploads.example.invalid/part?signature=secret",
                            source = source,
                            offset = 0,
                            byteCount = 4,
                            contentType = "video/mp4",
                        ) {}
                    }
                }.exceptionOrNull()

            val timeout = assertIs<SocketTimeoutException>(failure)
            assertTrue(connection.disconnectCalls > 0)
            assertTrue(output.closed)
            assertFalse(timeout.message.orEmpty().contains("secret"))
            assertFalse(timeout.message.orEmpty().contains(source.toString()))
        } finally {
            Files.deleteIfExists(source)
        }
    }

    @Test
    fun `caller cancellation disconnects a blocked upload write promptly`() = runBlocking {
        val source = Files.createTempFile("frameio-http", ".mp4")
        try {
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val output = BlockingOutputStream()
            val connection = FakeHttpsConnection(output)
            val client =
                UrlConnectionFrameioHttpClient(
                    connectionFactory = { connection },
                    uploadWriteTimeoutMillis = 10_000L,
                )
            val upload =
                launch(Dispatchers.Default) {
                    client.putUploadPart(
                        uploadURL = "https://uploads.example.invalid/part",
                        source = source,
                        offset = 0,
                        byteCount = 4,
                        contentType = "video/mp4",
                    ) {}
                }
            assertTrue(output.entered.await(1, TimeUnit.SECONDS))

            withTimeout(1_000L) {
                upload.cancelAndJoin()
            }

            assertTrue(upload.isCancelled)
            assertTrue(connection.disconnectCalls > 0)
            assertTrue(output.closed)
        } finally {
            Files.deleteIfExists(source)
        }
    }

    @Test
    fun `stalled output close remains inside the network write deadline`() = runBlocking {
        val source = Files.createTempFile("frameio-http", ".mp4")
        try {
            Files.write(source, byteArrayOf(1, 2, 3, 4))
            val output = BlockingCloseOutputStream()
            val connection = FakeHttpsConnection(output)
            val client =
                UrlConnectionFrameioHttpClient(
                    connectionFactory = { connection },
                    uploadWriteTimeoutMillis = 50L,
                )

            val failure =
                runCatching {
                    withTimeout(1_000L) {
                        client.putUploadPart(
                            uploadURL = "https://uploads.example.invalid/part",
                            source = source,
                            offset = 0,
                            byteCount = 4,
                            contentType = "video/mp4",
                        ) {}
                    }
                }.exceptionOrNull()

            assertIs<SocketTimeoutException>(failure)
            assertTrue(output.closeEntered.await(1, TimeUnit.SECONDS))
            assertTrue(output.closed)
            assertTrue(connection.disconnectCalls > 0)
        } finally {
            Files.deleteIfExists(source)
        }
    }

    @Test
    fun `ranged upload sends exact bytes and private non-redirecting request`() = runBlocking {
        val source = Files.createTempFile("frameio-http", ".mp4")
        try {
            val bytes = ByteArray(10) { it.toByte() }
            Files.write(source, bytes)
            val output = ByteArrayOutputStream()
            val connection = FakeHttpsConnection(output)
            val client = UrlConnectionFrameioHttpClient(connectionFactory = { connection })
            val progress = mutableListOf<Long>()

            val response =
                client.putUploadPart(
                    uploadURL = "https://uploads.example.invalid/part",
                    source = source,
                    offset = 2,
                    byteCount = 4,
                    contentType = "video/mp4",
                    onBytesSent = progress::add,
                )

            assertEquals(200, response.statusCode)
            assertContentEquals(byteArrayOf(2, 3, 4, 5), output.toByteArray())
            assertEquals("PUT", connection.requestMethod)
            assertEquals("private", connection.getRequestProperty("x-amz-acl"))
            assertEquals("video/mp4", connection.getRequestProperty("Content-Type"))
            assertEquals(4L, connection.fixedLength)
            assertFalse(connection.instanceFollowRedirects)
            assertEquals(listOf(4L), progress)
        } finally {
            Files.deleteIfExists(source)
        }
    }

    private class BlockingOutputStream : OutputStream() {
        val entered = CountDownLatch(1)
        private val released = CountDownLatch(1)

        @Volatile var closed = false
            private set

        override fun write(value: Int) {
            write(byteArrayOf(value.toByte()), 0, 1)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            entered.countDown()
            released.await()
            throw IOException("unit connection closed")
        }

        override fun close() {
            closed = true
            released.countDown()
        }

        fun release() {
            released.countDown()
        }
    }

    private class BlockingCloseOutputStream : OutputStream() {
        private val bytes = ByteArrayOutputStream()
        val closeEntered = CountDownLatch(1)
        private val released = CountDownLatch(1)

        @Volatile var closed = false
            private set

        override fun write(value: Int) {
            bytes.write(value)
        }

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            bytes.write(buffer, offset, length)
        }

        override fun close() {
            closeEntered.countDown()
            released.await()
            closed = true
            bytes.close()
        }

        fun release() {
            released.countDown()
        }
    }

    private class FakeHttpsConnection(
        private val uploadOutput: OutputStream,
    ) : HttpsURLConnection(URL("https://uploads.example.invalid/part")) {
        var disconnectCalls = 0
            private set
        var fixedLength: Long? = null
            private set

        override fun connect() = Unit

        override fun disconnect() {
            disconnectCalls += 1
            when (uploadOutput) {
                is BlockingOutputStream -> uploadOutput.release()
                is BlockingCloseOutputStream -> uploadOutput.release()
            }
        }

        override fun usingProxy(): Boolean = false

        override fun getOutputStream(): OutputStream = uploadOutput

        override fun getResponseCode(): Int = 200

        override fun getInputStream() = ByteArrayInputStream(ByteArray(0))

        override fun setFixedLengthStreamingMode(contentLength: Long) {
            fixedLength = contentLength
            super.setFixedLengthStreamingMode(contentLength)
        }

        override fun getCipherSuite(): String = "TLS_UNIT"

        override fun getLocalCertificates(): Array<Certificate>? = null

        override fun getServerCertificates(): Array<Certificate> = emptyArray()
    }
}
