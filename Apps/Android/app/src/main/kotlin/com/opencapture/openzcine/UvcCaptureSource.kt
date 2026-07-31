// LENS_FACING_EXTERNAL — the whole point of this file — is still behind
// CameraX's opt-in marker.
@file:OptIn(ExperimentalLensFacing::class)

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalLensFacing
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine

private const val TAG = "UvcCapture"

/**
 * A live frame whose payload is already a decoded bitmap.
 *
 * HDMI capture delivers RGBA pixels; wrapping them as [LiveFrame] with an
 * empty [LiveFrame.jpegData] and the bitmap alongside lets the existing pump
 * present them without a JPEG encode/decode round trip per frame.
 */
class BitmapLiveFrame(
    timestampNanos: Long,
    val bitmap: Bitmap,
    measuredFramesPerSecond: Double?,
) : LiveFrame(
    timestampNanos = timestampNanos,
    jpegData = EMPTY_PAYLOAD,
    measuredFramesPerSecond = measuredFramesPerSecond,
) {
    private companion object {
        val EMPTY_PAYLOAD = ByteArray(0)
    }
}

/**
 * The CameraX selector for a USB (UVC) capture device — an HDMI capture cable.
 *
 * A function rather than a top-level val, and with the androidx OptIn beside
 * the file-level Kotlin one: lint's experimental checker only honours the
 * androidx form, and only over a function body.
 */
@androidx.annotation.OptIn(ExperimentalLensFacing::class)
private fun externalCameraSelector(): CameraSelector =
    CameraSelector.Builder().requireLensFacing(CameraSelector.LENS_FACING_EXTERNAL).build()

/** Resolves the process camera provider without blocking the caller's thread. */
private suspend fun cameraProvider(context: Context): ProcessCameraProvider =
    suspendCancellableCoroutine { continuation ->
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener(
            {
                // get() cannot block here: the listener only runs once the
                // future is complete. Failures surface as the thrown cause.
                runCatching { future.get() }
                    .onSuccess { if (continuation.isActive) continuation.resume(it) }
                    .onFailure { if (continuation.isActive) continuation.cancel(it) }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

/**
 * Whether a UVC capture device is currently attached and enumerated.
 *
 * Camera2/CameraX only lists one where the vendor shipped the AOSP
 * external-camera HAL, so "no device" is the common answer on many phones
 * even with a working cable — the wizard copy says so.
 */
suspend fun hasExternalUvcCamera(context: Context): Boolean =
    runCatching { cameraProvider(context).hasCamera(externalCameraSelector()) }
        .getOrDefault(false)

/**
 * Streams an attached UVC capture device (HDMI capture cable) as live frames.
 *
 * Picture only: there is no PTP session behind these frames, so the monitor
 * runs with [CaptureOnlyCameraSession] beside it. CameraX handles device
 * attach/detach through the bound lifecycle; on detach the stream simply
 * stops emitting until the device returns.
 */
class UvcFrameSource(
    private val context: Context,
) : LiveFrameSource {
    private val frameSink =
        MutableSharedFlow<LiveFrame>(
            extraBufferCapacity = 1,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
    override val frames: Flow<LiveFrame> = frameSink

    private val analysisExecutor = Executor { it.run() }
    private var provider: ProcessCameraProvider? = null
    private var analysis: ImageAnalysis? = null

    // Analyzer-thread state (CameraX serializes analyze calls).
    private var lastFrameNanos = 0L
    private var smoothedFps: Double? = null
    // Reused bitmap ring: a fresh 1080p ARGB allocation per frame is ~250 MB/s
    // of GC churn at 30 fps. Depth 3 outruns the single conflated frame the
    // pump holds plus the one being presented.
    private var ring = arrayOfNulls<Bitmap>(3)
    private var ringIndex = 0

    /** Binds the capture device and starts emitting. Main thread (CameraX bind rule). */
    suspend fun start(lifecycleOwner: LifecycleOwner) {
        if (analysis != null) return
        val resolvedProvider = cameraProvider(context)
        val resolvedAnalysis =
            ImageAnalysis.Builder()
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            // The default analysis target is 640×480 — useless for
                            // a monitor. Ask for 1080p-class or the nearest the
                            // capture device offers.
                            ResolutionStrategy(
                                Size(1920, 1080),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                            )
                        )
                        .build()
                )
                .build()
        resolvedAnalysis.setAnalyzer(analysisExecutor) { image ->
            try {
                emitFrame(image)
            } finally {
                // `ImageProxy` owns the camera frame; releasing it promptly keeps
                // CameraX delivering instead of stalling on a retained buffer.
                image.close()
            }
        }
        // Bind only this use case: pairing's credential scanner is another
        // CameraX client in the same activity and must never be torn down.
        resolvedProvider.bindToLifecycle(lifecycleOwner, externalCameraSelector(), resolvedAnalysis)
        provider = resolvedProvider
        analysis = resolvedAnalysis
        Log.i(TAG, "UVC capture bound")
    }

    fun close() {
        analysis?.clearAnalyzer()
        analysis?.let { provider?.unbind(it) }
        analysis = null
        provider = null
    }

    private fun emitFrame(image: ImageProxy) {
        val now = System.nanoTime()
        if (lastFrameNanos != 0L) {
            val instant = 1_000_000_000.0 / (now - lastFrameNanos).coerceAtLeast(1L)
            val previous = smoothedFps
            smoothedFps = if (previous == null) instant else previous * 0.9 + instant * 0.1
        }
        lastFrameNanos = now

        // RGBA rows can carry stride padding; copy at the padded width, then
        // crop — the stock CameraX recipe, with the padded target reused.
        val plane = image.planes[0]
        val paddedWidth = plane.rowStride / 4
        val slot = ringIndex
        ringIndex = (ringIndex + 1) % ring.size
        val reusable = ring[slot]
        val padded =
            if (reusable != null && reusable.width == paddedWidth && reusable.height == image.height) {
                reusable
            } else {
                Bitmap.createBitmap(paddedWidth, image.height, Bitmap.Config.ARGB_8888).also {
                    ring[slot] = it
                }
            }
        padded.copyPixelsFromBuffer(plane.buffer)
        val bitmap =
            if (paddedWidth == image.width) {
                padded
            } else {
                Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
            }
        frameSink.tryEmit(
            BitmapLiveFrame(
                timestampNanos = now,
                bitmap = bitmap,
                measuredFramesPerSecond = smoothedFps,
            )
        )
    }
}

/**
 * The session beside an HDMI capture feed: connected-looking so the monitor
 * chrome mounts, but with no control link at all — the all-null property
 * snapshot from the [CameraSession] defaults keeps every readout honest, and
 * every command reports itself unsupported rather than pretending.
 */
class CaptureOnlyCameraSession(displayName: String) : CameraSession {
    private val mutableState =
        MutableStateFlow<CameraSessionState>(
            CameraSessionState.Connected(
                CameraIdentity(name = displayName, model = displayName, serialNumber = "")
            )
        )

    override val state = mutableState.asStateFlow()
    override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY).asStateFlow()

    override suspend fun connect() = Unit

    override suspend fun setRecording(recording: Boolean) {
        throw CameraRecordingException.Unsupported
    }

    override suspend fun disconnect() {
        mutableState.value = CameraSessionState.Disconnected
    }
}
