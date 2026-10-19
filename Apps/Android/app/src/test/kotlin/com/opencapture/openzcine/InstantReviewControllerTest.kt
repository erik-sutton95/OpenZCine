package com.opencapture.openzcine

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageBitmapConfig
import androidx.compose.ui.graphics.colorspace.ColorSpace
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** JVM coverage: a cancelled review job never writes its late image. */
class InstantReviewControllerTest {
    private class FakeImage(val handle: Int) : ImageBitmap {
        override val width = 1
        override val height = 1
        override val config = ImageBitmapConfig.Argb8888
        override val hasAlpha = false
        override val colorSpace: ColorSpace = ColorSpaces.Srgb

        override fun readPixels(
            buffer: IntArray,
            startX: Int,
            startY: Int,
            width: Int,
            height: Int,
            bufferOffset: Int,
            stride: Int,
        ) {}

        override fun prepareToDraw() {}
    }

    /** No embedded thumbnail; each full read finishes only when its gate opens, cancelled or not. */
    private class FakeSession(private val handles: ArrayDeque<Int>) : CameraSession {
        override val state: StateFlow<CameraSessionState> =
            MutableStateFlow(
                CameraSessionState.Connected(
                    CameraIdentity(name = "Z6III", model = "Z6III", serialNumber = "1"),
                ),
            )
        override val recordingState: StateFlow<CameraRecordingState> =
            MutableStateFlow(CameraRecordingState.STANDBY)
        val gates = mutableMapOf<Int, CompletableDeferred<Unit>>()

        override suspend fun connect() = Unit

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() = Unit

        override suspend fun resolveNewestStillHandle(): Int? = handles.removeFirstOrNull()

        override suspend fun stillFullImage(handle: Int): ByteArray? {
            val gate = gates.getOrPut(handle) { CompletableDeferred() }
            // Like a transport that finishes its in-flight read after the caller is cancelled.
            return withContext(NonCancellable) {
                gate.await()
                byteArrayOf(handle.toByte())
            }
        }
    }

    private fun controller(session: FakeSession) =
        InstantReviewController(session, decode = { FakeImage(it.first().toInt()) })

    @Test
    fun aDismissedReviewIsNotBroughtBackByItsLateFullImage() = runTest {
        val session = FakeSession(ArrayDeque(listOf(1)))
        val review = controller(session)
        review.onCaptureRunCompleted(this, enabled = true, infoLine = null)
        advanceUntilIdle()
        review.dismiss()
        session.gates.getValue(1).complete(Unit)
        advanceUntilIdle()
        assertNull(review.review.value)
    }

    @Test
    fun anOlderRunCannotOverwriteTheNewerReview() = runTest {
        val session = FakeSession(ArrayDeque(listOf(1, 2)))
        val review = controller(session)
        review.onCaptureRunCompleted(this, enabled = true, infoLine = null)
        advanceUntilIdle()
        review.onCaptureRunCompleted(this, enabled = true, infoLine = null)
        advanceUntilIdle()
        session.gates.getValue(2).complete(Unit)
        advanceUntilIdle()
        session.gates.getValue(1).complete(Unit)
        advanceUntilIdle()
        assertEquals(2, review.review.value?.handle)
        assertEquals(2, (review.review.value?.image as FakeImage).handle)
    }
}
