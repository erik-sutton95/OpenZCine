package com.opencapture.openzcine.pairing

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
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
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldColors
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

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

/** The manual-entry twin of [CameraWifiTranscriptParser], same shared-core authority. */
internal fun interface CameraWifiManualParser {
    /** Returns a validated shared-core wire result, or null when either field is invalid. */
    fun parse(ssid: String, key: String): String?
}

/** Production [CameraWifiManualParser] — validation stays in Swift, as it does on iOS. */
internal object SwiftCameraWifiManualParser : CameraWifiManualParser {
    override fun parse(ssid: String, key: String): String? =
        if (SwiftCore.isAvailable) SwiftCore.manualCameraWifiCredentials(ssid, key) else null
}

/** Validates typed Connection-wizard details into a candidate, or null when incomplete. */
internal fun cameraWifiManualCandidate(
    parser: CameraWifiManualParser,
    ssid: String,
    key: String,
): CameraWifiScanCandidate? = CameraWifiCredentialsWire.decode(parser.parse(ssid, key))

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

    /**
     * Typed SSID/key entry — always reachable, and the only path when OCR cannot run.
     *
     * [canReturnToScan] is false when the operator arrived from a permanent OCR
     * fault, so the surface never offers a scan that provably cannot work.
     */
    data class ManualEntry(val canReturnToScan: Boolean) : CameraWifiScannerState

    data class Candidate(val value: CameraWifiScanCandidate) : CameraWifiScannerState

    data class Failure(val reason: CameraWifiScannerFailure) : CameraWifiScannerState
}

internal enum class CameraWifiScannerFailure {
    CAMERA_UNAVAILABLE,

    /** A recoverable OCR state — a fresh recognizer may work. */
    RECOGNIZER_UNAVAILABLE,

    /** This build cannot run on-device OCR on this device; retrying is pointless. */
    RECOGNIZER_UNSUPPORTED,
    CORE_UNAVAILABLE,
}

/** Whether a failure panel should offer "Try again", or only manual entry. */
internal fun cameraWifiScannerFailureIsRetryable(failure: CameraWifiScannerFailure): Boolean =
    when (failure) {
        CameraWifiScannerFailure.CAMERA_UNAVAILABLE,
        CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE,
        -> true
        CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED,
        CameraWifiScannerFailure.CORE_UNAVAILABLE,
        -> false
    }

/** Closed diagnostic token for a scanner failure, or null when it carries no incident. */
internal fun cameraWifiScannerDiagnosticPhase(failure: CameraWifiScannerFailure): String? =
    when (failure) {
        CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE -> "failed.scannerRecognizer"
        CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED -> "failed.scannerRecognizerUnsupported"
        CameraWifiScannerFailure.CAMERA_UNAVAILABLE,
        CameraWifiScannerFailure.CORE_UNAVAILABLE,
        -> null
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
    onDiagnosticPhase: (String) -> Unit = {},
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val controller = remember { CameraWifiScannerController(SwiftCameraWifiTranscriptParser) }
    val debugCandidate = remember(context) { CameraWifiScannerDemo.initialCandidate(context) }
    var scannerState by remember {
        mutableStateOf<CameraWifiScannerState>(CameraWifiScannerState.Scanning)
    }
    // Bumped by every retry so the recognizer is rebuilt from scratch instead of
    // reusing a remembered failure — "Try again" must always do new work.
    var scanAttempt by remember { mutableIntStateOf(0) }
    val currentDiagnosticPhase by rememberUpdatedState(onDiagnosticPhase)

    fun fail(reason: CameraWifiScannerFailure) {
        if (scannerState is CameraWifiScannerState.Failure) return
        cameraWifiScannerDiagnosticPhase(reason)?.let(currentDiagnosticPhase)
        scannerState = CameraWifiScannerState.Failure(reason)
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
            fail(CameraWifiScannerFailure.CORE_UNAVAILABLE)
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
                val manual = scannerState as? CameraWifiScannerState.ManualEntry
                // A keyboard takes over half of the ~400dp landscape canvas. The
                // header is read once, so drop it while typing rather than make
                // the operator scroll blind between the fields and Use details.
                val keyboardOpen = WindowInsets.ime.getBottom(LocalDensity.current) > 0
                if (!keyboardOpen) {
                    Text(
                        text =
                            stringResource(
                                if (manual != null) R.string.wifi_scanner_manual_title
                                else R.string.wifi_scanner_title,
                            ),
                        color = PopupColors.title,
                        fontSize = 20.sp,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text =
                            stringResource(
                                if (manual != null) R.string.wifi_scanner_manual_intro
                                else R.string.wifi_scanner_intro,
                            ),
                        color = PopupColors.detail,
                        fontSize = 15.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                }

                fun useManualEntry(canReturnToScan: Boolean) {
                    controller.close()
                    scannerState = CameraWifiScannerState.ManualEntry(canReturnToScan)
                }

                when {
                    scannerState is CameraWifiScannerState.Closed -> Unit

                    // Manual entry needs no camera, so it outranks the permission
                    // panel: a denied camera must never dead-end pairing.
                    manual != null ->
                        CameraWifiManualEntryPanel(
                            compact = compact,
                            onSubmit = { candidate ->
                                scannerState = CameraWifiScannerState.Closed
                                onConfirmed(candidate)
                            },
                        )

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
                            attempt = scanAttempt,
                            onTranscript = { transcript ->
                                controller.acceptTranscript(transcript)?.let { candidate ->
                                    // First fully-validated frame hands off to
                                    // the connect popup, like iOS onCapture.
                                    controller.close()
                                    scannerState = CameraWifiScannerState.Closed
                                    onConfirmed(candidate)
                                }
                            },
                            onFailure = ::fail,
                        )

                    scannerState is CameraWifiScannerState.Failure -> {
                        val failure = (scannerState as CameraWifiScannerState.Failure).reason
                        CameraWifiScannerFailurePanel(
                            failure = failure,
                            onRetry = {
                                controller.rescan()
                                // A fresh recognizer, not the remembered failure.
                                scanAttempt += 1
                                scannerState = CameraWifiScannerState.Scanning
                            },
                        )
                    }
                }

                // One action row, iOS `scanActions`: typed entry is reachable from
                // every state the scanner can be in, so OCR is never the only way
                // to pair. CORE_UNAVAILABLE is the exception — manual entry
                // validates through the same missing Swift core, so it cannot help.
                val failureReason = (scannerState as? CameraWifiScannerState.Failure)?.reason
                val secondaryAction: Pair<Int, () -> Unit>? =
                    when {
                        scannerState is CameraWifiScannerState.Closed -> null
                        manual != null ->
                            (R.string.wifi_scanner_back_to_scan to
                                {
                                    controller.rescan()
                                    scanAttempt += 1
                                    scannerState = CameraWifiScannerState.Scanning
                                })
                                .takeIf { manual.canReturnToScan }
                        failureReason == CameraWifiScannerFailure.CORE_UNAVAILABLE -> null
                        else ->
                            R.string.wifi_scanner_enter_manually to
                                {
                                    useManualEntry(
                                        canReturnToScan =
                                            failureReason == null ||
                                                cameraWifiScannerFailureIsRetryable(failureReason),
                                    )
                                }
                    }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    secondaryAction?.let { (label, action) ->
                        Box(Modifier.weight(1f)) {
                            PopupCancelButton(text = stringResource(label), onClick = action)
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        PopupCancelButton(
                            text = stringResource(R.string.action_cancel),
                            onClick = ::dismiss,
                        )
                    }
                }
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
    attempt: Int,
    onTranscript: (String) -> Unit,
    onFailure: (CameraWifiScannerFailure) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CameraWifiCameraPreview(
            attempt = attempt,
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
                    CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED ->
                        stringResource(R.string.wifi_scanner_recognizer_unsupported)
                    CameraWifiScannerFailure.CORE_UNAVAILABLE ->
                        stringResource(R.string.wifi_scanner_core_unavailable)
                },
            color = PopupColors.detail,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
        // A permanent fault gets no "Try again": the operator is sent to typed
        // entry instead of a button that provably does nothing.
        if (cameraWifiScannerFailureIsRetryable(failure)) {
            PopupFilledButton(
                text = stringResource(R.string.action_try_again),
                onClick = onRetry,
            )
        }
    }
}

/**
 * Typed SSID/key entry, mirroring the iOS scanner's manual form.
 *
 * Neither field is ever logged or persisted here; both are validated by the
 * shared Swift policy and handed straight to the connect popup.
 */
@Composable
private fun CameraWifiManualEntryPanel(
    compact: Boolean,
    onSubmit: (CameraWifiScanCandidate) -> Unit,
) {
    // Deliberately NOT rememberSaveable: a saved-instance bundle would write the
    // camera's Wi-Fi key to disk in the activity's saved state.
    var ssid by remember { mutableStateOf("") }
    var key by remember { mutableStateOf("") }
    var submissionAttempted by remember { mutableStateOf(false) }
    val candidate = cameraWifiManualCandidate(SwiftCameraWifiManualParser, ssid, key)

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 10.dp),
    ) {
        OutlinedTextField(
            value = ssid,
            onValueChange = {
                ssid = it
                submissionAttempted = false
            },
            singleLine = true,
            label = { Text(stringResource(R.string.wifi_scanner_network_ssid)) },
            keyboardOptions =
                KeyboardOptions(
                    autoCorrectEnabled = false,
                    capitalization = KeyboardCapitalization.Characters,
                    imeAction = ImeAction.Next,
                ),
            colors = manualFieldColors(),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = key,
            onValueChange = {
                key = it
                submissionAttempted = false
            },
            singleLine = true,
            label = { Text(stringResource(R.string.wifi_scanner_network_key)) },
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions =
                KeyboardOptions(
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
            colors = manualFieldColors(),
            modifier = Modifier.fillMaxWidth(),
        )
        if (submissionAttempted && candidate == null) {
            Text(
                text = stringResource(R.string.wifi_scanner_manual_invalid),
                color = PopupColors.failure,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        PopupFilledButton(
            text = stringResource(R.string.wifi_scanner_use_details),
            onClick = {
                submissionAttempted = true
                candidate?.let(onSubmit)
            },
        )
    }
}

/** Keeps the manual fields legible on the popup's forced-light card. */
@Composable
private fun manualFieldColors(): TextFieldColors =
    OutlinedTextFieldDefaults.colors(
        focusedTextColor = PopupColors.title,
        unfocusedTextColor = PopupColors.title,
        cursorColor = PopupColors.actionBlue,
        focusedBorderColor = PopupColors.actionBlue,
        unfocusedBorderColor = PopupColors.detail,
        focusedLabelColor = PopupColors.actionBlue,
        unfocusedLabelColor = PopupColors.detail,
        focusedContainerColor = PopupColors.card,
        unfocusedContainerColor = PopupColors.card,
    )

/** Logcat tag for the scanner's on-device OCR faults. Never carries recognized text. */
internal const val CAMERA_WIFI_SCANNER_LOG_TAG: String = "OpenZCineWifiScan"

/**
 * How many consecutive ML Kit frame failures the scanner absorbs before it calls
 * OCR unavailable.
 *
 * The bundled Latin recognizer links its model and `libmlkit_google_ocr_pipeline.so`
 * into the app but loads them lazily on the first `process()` call, so the opening
 * frames can legitimately fail while that pipeline warms up. Treating the first
 * failure as fatal is what made a warm-up blip look like a permanently broken
 * recognizer.
 */
internal const val CAMERA_WIFI_RECOGNIZER_WARMUP_TOLERANCE: Int = 4

/**
 * Whether an ML Kit fault can ever clear on this device+build, or never will.
 *
 * A permanent fault means the packaged app cannot run on-device OCR here (the
 * model, its native library, or its classes are absent for this ABI/build), so
 * "Try again" would be busywork. Everything else is treated as recoverable.
 */
internal enum class CameraWifiRecognizerFault {
    /** No amount of retrying will make this build recognize text on this device. */
    PERMANENT,

    /** A warm-up, memory, or per-frame condition that a fresh attempt may clear. */
    TRANSIENT,
}

/**
 * Classifies an ML Kit failure from its *type* only.
 *
 * Exception messages are deliberately never inspected or stored: ML Kit builds
 * some of them from the input it was handed, and this scanner's input is a frame
 * of the operator's Wi-Fi key.
 */
internal fun cameraWifiRecognizerFault(cause: Throwable): CameraWifiRecognizerFault =
    when {
        // Model/native library absent for this ABI, or R8 removed the pipeline
        // classes from the release package. Neither recovers at runtime.
        cause is UnsatisfiedLinkError -> CameraWifiRecognizerFault.PERMANENT
        cause is NoClassDefFoundError -> CameraWifiRecognizerFault.PERMANENT
        cause is ClassNotFoundException -> CameraWifiRecognizerFault.PERMANENT
        cause is MlKitException -> cameraWifiMlKitFault(cause.errorCode)
        else -> CameraWifiRecognizerFault.TRANSIENT
    }

/**
 * The ML Kit error-code half of [cameraWifiRecognizerFault].
 *
 * Split out because `MlKitException`'s constructor reaches into `android.text`,
 * which a JVM unit test cannot run — the codes themselves are plain constants.
 */
internal fun cameraWifiMlKitFault(errorCode: Int): CameraWifiRecognizerFault =
    when (errorCode) {
        // NOT_FOUND: the bundled asset is missing from this package.
        // UNIMPLEMENTED: this device cannot run the operation at all.
        MlKitException.NOT_FOUND,
        MlKitException.UNIMPLEMENTED,
        -> CameraWifiRecognizerFault.PERMANENT
        else -> CameraWifiRecognizerFault.TRANSIENT
    }

/** Maps a fault onto the scanner state machine's failure reason. */
internal fun cameraWifiScannerFailure(fault: CameraWifiRecognizerFault): CameraWifiScannerFailure =
    when (fault) {
        CameraWifiRecognizerFault.PERMANENT ->
            CameraWifiScannerFailure.RECOGNIZER_UNSUPPORTED
        CameraWifiRecognizerFault.TRANSIENT ->
            CameraWifiScannerFailure.RECOGNIZER_UNAVAILABLE
    }

/**
 * Records the recognizer fault locally without touching frames or transcripts.
 *
 * The category and the exception's own stack are exactly what a beta tester can
 * pull with `adb logcat -s OpenZCineWifiScan`; the closed breadcrumb the caller
 * raises is what reaches an anonymous report.
 */
internal fun logCameraWifiRecognizerFault(stage: String, cause: Throwable) {
    // A diagnostic must never be able to take the scanner down with it (and
    // android.util.Log is an unmocked stub under JVM unit tests).
    runCatching {
        Log.w(
            CAMERA_WIFI_SCANNER_LOG_TAG,
            "on-device OCR fault: stage=$stage fault=${cameraWifiRecognizerFault(cause)} " +
                "type=${cause.javaClass.name}",
            cause,
        )
    }
}

/**
 * Tolerates the bundled recognizer's lazy warm-up before declaring OCR unusable.
 *
 * A permanent fault surfaces immediately; a recoverable one only after
 * [tolerance] consecutive failures with no successful frame in between.
 */
internal class CameraWifiRecognizerHealth(
    private val tolerance: Int = CAMERA_WIFI_RECOGNIZER_WARMUP_TOLERANCE,
) {
    private val consecutiveFailures = AtomicInteger(0)

    /** Clears the warm-up budget — the pipeline has produced at least one frame. */
    fun recordSuccess() {
        consecutiveFailures.set(0)
    }

    /** Returns the failure to surface, or null while the warm-up budget remains. */
    fun recordFailure(cause: Throwable): CameraWifiScannerFailure? {
        val fault = cameraWifiRecognizerFault(cause)
        val failures = consecutiveFailures.incrementAndGet()
        if (fault == CameraWifiRecognizerFault.TRANSIENT && failures <= tolerance) return null
        return cameraWifiScannerFailure(fault)
    }
}

/**
 * Opens the bundled Latin text recognizer, or null when ML Kit cannot initialize
 * (missing model, broken native load).
 *
 * The cause is never swallowed: it is classified, logged locally, and handed to
 * [onFault] so the caller can pick a permanent or retryable failure and raise a
 * closed diagnostic breadcrumb. Callers must never crash the scanner UI.
 */
internal fun openCameraWifiTextRecognizer(
    onFault: (CameraWifiRecognizerFault) -> Unit = {},
): TextRecognizer? =
    try {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    } catch (cause: Throwable) {
        // ML Kit has been observed to throw NullPointerException inside getClient
        // when the on-device stack is unavailable; also catch Error (e.g. UnsatisfiedLink).
        logCameraWifiRecognizerFault(stage = "getClient", cause = cause)
        onFault(cameraWifiRecognizerFault(cause))
        null
    }

/** Binds a temporary rear-camera preview and releases it when the scanner leaves composition. */
@Composable
private fun CameraWifiCameraPreview(
    attempt: Int,
    onTranscript: (String) -> Unit,
    onFailure: (CameraWifiScannerFailure) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val mainExecutor = remember(context) { ContextCompat.getMainExecutor(context) }
    val analysisExecutor = remember(attempt) { Executors.newSingleThreadExecutor() }
    // Keyed on [attempt] so every retry builds a genuinely new recognizer rather
    // than replaying a remembered failure.
    var openFault by remember(attempt) { mutableStateOf<CameraWifiRecognizerFault?>(null) }
    val recognizer =
        remember(attempt) { openCameraWifiTextRecognizer(onFault = { openFault = it }) }
    val health = remember(attempt) { CameraWifiRecognizerHealth() }
    val currentFailure by rememberUpdatedState(onFailure)

    // Surface a soft failure once if the recognizer never opens — do not throw
    // during composition (Play Vitals: NPE in TextRecognition.getClient).
    LaunchedEffect(recognizer, openFault) {
        if (recognizer == null) {
            currentFailure(
                cameraWifiScannerFailure(openFault ?: CameraWifiRecognizerFault.TRANSIENT),
            )
        }
    }
    if (recognizer == null) {
        // Failure panel is owned by the overlay state machine via [onFailure].
        return
    }

    val previewView =
        remember(context) {
            PreviewView(context).apply {
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                scaleType = PreviewView.ScaleType.FIT_CENTER
            }
        }
    val viewfinderDescription = stringResource(R.string.wifi_scanner_viewfinder_description)
    val currentTranscript by rememberUpdatedState(onTranscript)

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
                                        health = health,
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
    private val health: CameraWifiRecognizerHealth,
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
                    health.recordSuccess()
                    if (active.isOpen()) onTranscript(result.text)
                }
                .addOnFailureListener(mainExecutor) { cause -> reportFailure("process", cause) }
                .addOnCompleteListener {
                    // `ImageProxy` owns the camera frame. Releasing it here keeps
                    // CameraX from queuing or retaining credential-bearing frames.
                    active.releaseFrame { image.close() }
                }
        } catch (cause: Exception) {
            active.releaseFrame { image.close() }
            reportFailure("submit", cause)
        }
    }

    /** Logs every fault locally but only escalates past the recognizer's warm-up budget. */
    private fun reportFailure(stage: String, cause: Throwable) {
        logCameraWifiRecognizerFault(stage = stage, cause = cause)
        val failure = health.recordFailure(cause) ?: return
        if (active.isOpen()) onFailure(failure)
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
