package com.opencapture.openzcine.pairing

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.annotation.OptIn as AndroidxOptIn
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** JNI payload separator shared with `AndroidCameraWiFiScreenParserWire` in Swift. */
internal const val CAMERA_WIFI_CREDENTIAL_WIRE_SEPARATOR: Char = '\u001F'

/** The narrow OCR-policy seam backed by the shared Swift core in production. */
internal fun interface CameraWifiTranscriptParser {
    /** Returns a validated shared-core wire result, or null when OCR is incomplete or invalid. */
    fun parse(transcript: String): String?
}

/** Production [CameraWifiTranscriptParser] — no camera credential policy exists in Kotlin. */
internal object SwiftCameraWifiTranscriptParser : CameraWifiTranscriptParser {
    override fun parse(transcript: String): String? =
        if (SwiftCore.isAvailable) SwiftCore.parseCameraWifiScreen(transcript) else null
}

/**
 * A transient camera-AP credential candidate.
 *
 * The value intentionally redacts its diagnostic representation: OCR keys must
 * never reach logs, test failure output, accessibility diagnostics, or crash
 * reports through a generated `toString()` implementation.
 */
internal class CameraWifiScanCandidate(
    val ssid: String,
    val key: String,
    val isDebugFixture: Boolean = false,
) {
    override fun equals(other: Any?): Boolean =
        other is CameraWifiScanCandidate &&
            ssid == other.ssid &&
            key == other.key &&
            isDebugFixture == other.isDebugFixture

    override fun hashCode(): Int =
        ((31 * ssid.hashCode()) + key.hashCode()) * 31 + isDebugFixture.hashCode()

    override fun toString(): String = "CameraWifiScanCandidate(redacted)"
}

/** Structural decoder for the already-validated Swift OCR result. */
internal object CameraWifiCredentialsWire {
    /**
     * Decodes exactly two nonempty fields. Nikon format validation and OCR
     * correction have already occurred in Swift's `CameraWiFiScreenParser`.
     */
    fun decode(payload: String?): CameraWifiScanCandidate? {
        val fields = payload?.split(CAMERA_WIFI_CREDENTIAL_WIRE_SEPARATOR) ?: return null
        if (fields.size != 2 || fields.any(String::isBlank)) return null
        return CameraWifiScanCandidate(ssid = fields[0], key = fields[1])
    }
}

/**
 * Owns the scanner's secret-bearing transition: only the first complete
 * shared-core result can become a candidate until the operator explicitly
 * rescans. It holds no frames and never writes credentials to storage.
 */
internal class CameraWifiScannerController(
    private val parser: CameraWifiTranscriptParser,
) {
    private var awaitingConfirmation: Boolean = false

    /** Converts one ML Kit transcript into a candidate only when fully validated by Swift. */
    fun acceptTranscript(transcript: String): CameraWifiScanCandidate? {
        if (awaitingConfirmation) return null
        val candidate = CameraWifiCredentialsWire.decode(parser.parse(transcript)) ?: return null
        awaitingConfirmation = true
        return candidate
    }

    /** Clears the confirmation gate for an intentional fresh scan. */
    fun rescan() {
        awaitingConfirmation = false
    }

    /** Prevents any later analyzer callback from retaining a result after dismissal. */
    fun close() {
        awaitingConfirmation = true
    }
}

private sealed interface CameraWifiScannerState {
    data object Scanning : CameraWifiScannerState

    /** Releases any candidate from Compose state while the overlay closes. */
    data object Closed : CameraWifiScannerState

    data class Candidate(val value: CameraWifiScanCandidate) : CameraWifiScannerState

    data class Failure(val reason: CameraWifiScannerFailure) : CameraWifiScannerState
}

private enum class CameraWifiScannerFailure {
    CAMERA_UNAVAILABLE,
    RECOGNIZER_UNAVAILABLE,
    CORE_UNAVAILABLE,
}

/**
 * Full-screen local scanner for a camera's Connection wizard.
 *
 * CameraX owns the rear-camera lifecycle; bundled ML Kit runs recognition on
 * device only; each transcript crosses the smallest possible Swift boundary.
 * The candidate remains in memory only until the operator confirms, rescans,
 * or dismisses this surface.
 */
@Composable
internal fun CameraWifiScannerOverlay(
    onConfirmed: (CameraWifiScanCandidate) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val controller = remember { CameraWifiScannerController(SwiftCameraWifiTranscriptParser) }
    val debugCandidate = remember(context) { CameraWifiScannerDemo.initialCandidate(context) }
    var scannerState by remember {
        mutableStateOf<CameraWifiScannerState>(CameraWifiScannerState.Scanning)
    }
    LaunchedEffect(debugCandidate) {
        debugCandidate?.let { candidate ->
            controller.close()
            scannerState = CameraWifiScannerState.Closed
            onConfirmed(candidate)
        }
    }
    var cameraPermissionGranted by remember {
        mutableStateOf(context.hasCameraPermission())
    }
    var requestedCameraPermission by rememberSaveable { mutableStateOf(false) }
    var cameraPermissionDenials by rememberSaveable { mutableIntStateOf(0) }

    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            cameraPermissionGranted = granted
            cameraPermissionDenials = if (granted) 0 else cameraPermissionDenials + 1
        }

    fun dismiss() {
        controller.close()
        scannerState = CameraWifiScannerState.Closed
        onDismiss()
    }

    fun requestCameraPermission() {
        requestedCameraPermission = true
        permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    val needsLiveCamera = scannerState is CameraWifiScannerState.Scanning
    LaunchedEffect(needsLiveCamera, cameraPermissionGranted, requestedCameraPermission) {
        if (needsLiveCamera && !cameraPermissionGranted && !requestedCameraPermission) {
            requestCameraPermission()
        }
    }
    LaunchedEffect(needsLiveCamera, cameraPermissionGranted) {
        if (needsLiveCamera && cameraPermissionGranted && !SwiftCore.isAvailable) {
            scannerState = CameraWifiScannerState.Failure(CameraWifiScannerFailure.CORE_UNAVAILABLE)
        }
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                cameraPermissionGranted = context.hasCameraPermission()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    DisposableEffect(Unit) {
        onDispose { controller.close() }
    }

    Box(
        modifier =
            Modifier.fillMaxSize()
                .background(PopupColors.scrim)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        BoxWithConstraints(
            modifier = Modifier.widthIn(max = 360.dp),
            contentAlignment = Alignment.Center,
        ) {
            val compact = maxHeight < 480.dp
            Column(
                modifier =
                    Modifier.fillMaxWidth()
                        .heightIn(max = maxHeight)
                        .shadow(24.dp, RoundedCornerShape(24.dp))
                        .clip(RoundedCornerShape(24.dp))
                        .background(PopupColors.card)
                        .verticalScroll(rememberScrollState())
                        .padding(if (compact) 14.dp else 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 12.dp),
            ) {
                Text(
                    text = stringResource(R.string.wifi_scanner_title),
                    color = PopupColors.title,
                    fontSize = 20.sp,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                    textAlign = TextAlign.Center,
                )
                Text(
                    text = stringResource(R.string.wifi_scanner_intro),
                    color = PopupColors.detail,
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    textAlign = TextAlign.Center,
                )

                when {
                    scannerState is CameraWifiScannerState.Closed -> Unit

                    !cameraPermissionGranted ->
                        CameraWifiScannerPermissionPanel(
                            permanentlyDenied =
                                shouldOpenCameraPermissionSettings(
                                    denialCount = cameraPermissionDenials,
                                    canRequestAgain = context.canRequestCameraPermissionAgain(),
                                ),
                            onRetry = ::requestCameraPermission,
                            onOpenSettings = { context.openApplicationSettings() },
                        )

                    scannerState is CameraWifiScannerState.Scanning ->
                        CameraWifiScannerPreview(
                            compact = compact,
                            onTranscript = { transcript ->
                                controller.acceptTranscript(transcript)?.let { candidate ->
                                    // First fully-validated frame hands off to
                                    // the connect popup, like iOS onCapture.
                                    controller.close()
                                    scannerState = CameraWifiScannerState.Closed
                                    onConfirmed(candidate)
                                }
                            },
                            onFailure = { reason ->
                                scannerState = CameraWifiScannerState.Failure(reason)
                            },
                        )

                    scannerState is CameraWifiScannerState.Failure -> {
                        val failure = (scannerState as CameraWifiScannerState.Failure).reason
                        CameraWifiScannerFailurePanel(
                            failure = failure,
                            onRetry = {
                                controller.rescan()
                                scannerState = CameraWifiScannerState.Scanning
                            },
                        )
                    }
                }

                PopupCancelButton(
                    text = stringResource(R.string.action_cancel),
                    onClick = ::dismiss,
                )
            }
        }
    }
}

@Composable
private fun CameraWifiScannerPermissionPanel(
    permanentlyDenied: Boolean,
    onRetry: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Column(
        modifier =
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(PopupColors.field)
                .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = stringResource(R.string.wifi_scanner_permission_title),
            color = PopupColors.title,
            fontSize = 14.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
        )
        Text(
            text =
                if (permanentlyDenied) {
                    stringResource(R.string.wifi_scanner_permission_settings)
                } else {
                    stringResource(R.string.wifi_scanner_permission_privacy)
                },
            color = PopupColors.detail,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
        PopupFilledButton(
            text =
                stringResource(
                    if (permanentlyDenied) {
                        R.string.wifi_scanner_open_android_settings
                    } else {
                        R.string.wifi_scanner_allow_camera
                    },
                ),
            onClick = if (permanentlyDenied) onOpenSettings else onRetry,
        )
    }
}

@Composable
private fun CameraWifiScannerPreview(
    compact: Boolean,
    onTranscript: (String) -> Unit,
    onFailure: (CameraWifiScannerFailure) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CameraWifiCameraPreview(
            onTranscript = onTranscript,
            onFailure = onFailure,
            modifier =
                if (compact) {
                    Modifier.fillMaxWidth().height(122.dp)
                } else {
                    Modifier.fillMaxWidth().aspectRatio(4f / 3f)
                },
        )
        Text(
            text = stringResource(R.string.wifi_scanner_searching),
            color = PopupColors.detail,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun CameraWifiScannerFailurePanel(
    failure: CameraWifiScannerFailure,
    onRetry: () -> Unit,
) {
    Column(
        modifier =
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(PopupColors.field)
                .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = stringResource(R.string.wifi_scanner_failure_title),
            color = PopupColors.failure,
            fontSize = 15.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
        )
        Text(
            text =
                when (failure) {
                    CameraWifiScannerFailure.CAMERA_UNAVAILABLE ->
                        stringResource(R.string.wifi_scanner_camera_unavailable)
                    CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE ->
                        stringResource(R.string.wifi_scanner_recognizer_unavailable)
                    CameraWifiScannerFailure.CORE_UNAVAILABLE ->
                        stringResource(R.string.wifi_scanner_core_unavailable)
                },
            color = PopupColors.detail,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
        if (failure != CameraWifiScannerFailure.CORE_UNAVAILABLE) {
            PopupFilledButton(
                text = stringResource(R.string.action_try_again),
                onClick = onRetry,
            )
        }
    }
}

/** Binds a temporary rear-camera preview and releases it when the scanner leaves composition. */
@Composable
private fun CameraWifiCameraPreview(
    onTranscript: (String) -> Unit,
    onFailure: (CameraWifiScannerFailure) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val mainExecutor = remember(context) { ContextCompat.getMainExecutor(context) }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    val recognizer = remember { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    val previewView =
        remember(context) {
            PreviewView(context).apply {
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                scaleType = PreviewView.ScaleType.FIT_CENTER
            }
        }
    val viewfinderDescription = stringResource(R.string.wifi_scanner_viewfinder_description)
    val currentTranscript by rememberUpdatedState(onTranscript)
    val currentFailure by rememberUpdatedState(onFailure)

    DisposableEffect(lifecycleOwner, previewView, recognizer, analysisExecutor) {
        var disposed = false
        var provider: ProcessCameraProvider? = null
        var preview: Preview? = null
        var analysis: ImageAnalysis? = null
        val active = CameraWifiAnalysisGate()
        val cameraProvider = ProcessCameraProvider.getInstance(context)
        cameraProvider.addListener(
            {
                if (disposed) return@addListener
                try {
                    val resolvedProvider = cameraProvider.get()
                    val resolvedPreview = Preview.Builder().build().also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                    val resolvedAnalysis =
                        ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                            .also {
                                it.setAnalyzer(
                                    analysisExecutor,
                                    CameraWifiTextAnalyzer(
                                        recognizer = recognizer,
                                        mainExecutor = mainExecutor,
                                        active = active,
                                        onTranscript = { currentTranscript(it) },
                                        onFailure = { currentFailure(it) },
                                    ),
                                )
                            }
                    if (disposed) {
                        resolvedAnalysis.clearAnalyzer()
                        return@addListener
                    }
                    // Bind only this temporary scanner's use cases. Pairing can
                    // coexist with other CameraX clients in the activity, so
                    // this scanner must never tear down their preview or analysis.
                    resolvedProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        resolvedPreview,
                        resolvedAnalysis,
                    )
                    provider = resolvedProvider
                    preview = resolvedPreview
                    analysis = resolvedAnalysis
                } catch (_: Exception) {
                    if (!disposed) currentFailure(CameraWifiScannerFailure.CAMERA_UNAVAILABLE)
                }
            },
            mainExecutor,
        )
        onDispose {
            disposed = true
            active.stop()
            analysis?.clearAnalyzer()
            val useCases: Array<UseCase> = listOfNotNull(preview, analysis).toTypedArray()
            if (useCases.isNotEmpty()) provider?.unbind(*useCases)
            recognizer.close()
            analysisExecutor.shutdown()
        }
    }

    AndroidView(
        factory = { previewView },
        modifier =
            modifier
                .clip(RoundedCornerShape(16.dp))
                .border(1.dp, StartupColors.border.copy(alpha = 0.26f), RoundedCornerShape(16.dp))
                .clearAndSetSemantics { contentDescription = viewfinderDescription },
    )
}

/** Keeps CameraX latest-wins and closes every frame after its on-device OCR task completes. */
@AndroidxOptIn(markerClass = [ExperimentalGetImage::class])
private class CameraWifiTextAnalyzer(
    private val recognizer: TextRecognizer,
    private val mainExecutor: Executor,
    private val active: CameraWifiAnalysisGate,
    private val onTranscript: (String) -> Unit,
    private val onFailure: (CameraWifiScannerFailure) -> Unit,
) : ImageAnalysis.Analyzer {
    override fun analyze(image: ImageProxy) {
        if (!active.tryAcquireFrame()) {
            image.close()
            return
        }
        val mediaImage = image.image
        if (mediaImage == null) {
            active.releaseFrame { image.close() }
            return
        }
        try {
            val input = InputImage.fromMediaImage(mediaImage, image.imageInfo.rotationDegrees)
            recognizer.process(input)
                .addOnSuccessListener(mainExecutor) { result ->
                    if (active.isOpen()) onTranscript(result.text)
                }
                .addOnFailureListener(mainExecutor) {
                    if (active.isOpen()) onFailure(CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE)
                }
                .addOnCompleteListener {
                    // `ImageProxy` owns the camera frame. Releasing it here keeps
                    // CameraX from queuing or retaining credential-bearing frames.
                    active.releaseFrame { image.close() }
                }
        } catch (_: Exception) {
            active.releaseFrame { image.close() }
            if (active.isOpen()) onFailure(CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE)
        }
    }
}

/**
 * Thread-safe ownership for the current CameraX frame.
 *
 * Disposing the scanner closes this gate before CameraX is unbound. In-flight
 * OCR may finish, but it cannot publish a candidate and its frame is always
 * released through [releaseFrame].
 */
internal class CameraWifiAnalysisGate {
    private val open = AtomicBoolean(true)
    private val processing = AtomicBoolean(false)

    /** Claims the latest frame only while this scanner remains visible. */
    fun tryAcquireFrame(): Boolean = open.get() && processing.compareAndSet(false, true)

    /** Whether analyzer callbacks may still update scanner state. */
    fun isOpen(): Boolean = open.get()

    /** Stops new analysis and prevents any in-flight result from being published. */
    fun stop() {
        open.set(false)
    }

    /** Closes the current CameraX frame and releases this analyzer's slot. */
    fun releaseFrame(closeFrame: () -> Unit) {
        try {
            closeFrame()
        } finally {
            processing.set(false)
        }
    }
}

private fun Context.hasCameraPermission(): Boolean =
    checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

/**
 * Android's rationale result is ambiguous after a first denial on some devices.
 * Keep one clear retry in-app before directing the operator to Settings.
 */
internal fun shouldOpenCameraPermissionSettings(
    denialCount: Int,
    canRequestAgain: Boolean,
): Boolean = denialCount > 1 && !canRequestAgain

private fun Context.canRequestCameraPermissionAgain(): Boolean =
    findActivity()?.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) == true

private fun Context.openApplicationSettings() {
    startActivity(
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
}

private tailrec fun Context.findActivity(): Activity? =
    when (this) {
        is Activity -> this
        is ContextWrapper -> baseContext.findActivity()
        else -> null
    }
