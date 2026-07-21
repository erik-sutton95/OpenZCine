package com.opencapture.openzcine.lut

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioHopAvailability
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Canonical RED IPP2 Output Presets page — same URL as iOS RedDownloadView. */
internal const val RED_IPP2_PRESETS_URL =
    "https://www.reddigitalcinema.com/download/ipp2-output-presets"

/**
 * Full-screen RED download flow ported from iOS [RedDownloadView]:
 * gateway (terms / blocked / hop) → RED's real page in WebView → operator
 * accepts terms and downloads → we import cubes into the RED category.
 *
 * Camera-AP internet hop reuses [FrameioDeliveryController.beginInternetHop]
 * (leave AP → wait for validated internet) and [endInternetHop] on dismiss
 * (rejoin saved camera Wi‑Fi + reconnect session).
 */
@Composable
internal fun RedLutDownloadScreen(
    lutLibrary: AndroidLutLibrary,
    frameioController: FrameioDeliveryController? = null,
    onClose: () -> Unit,
    onImported: (count: Int) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val gate = remember(context) { RedLutDownloadGate(context.applicationContext) }
    var readiness by remember { mutableStateOf(gate.readiness()) }
    var phase by remember { mutableStateOf<RedDownloadPhase>(RedDownloadPhase.Gateway) }
    var progress by remember { mutableFloatStateOf(0f) }
    var hopBusy by remember { mutableStateOf(false) }
    var hopError by remember { mutableStateOf<String?>(null) }
    val hopState = frameioController?.internetHopState ?: FrameioInternetHopState.Idle
    val hopAvailability =
        frameioController?.cameraHopAvailability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
    /**
     * Dismiss immediately. Camera rejoin runs from [DisposableEffect] after the cover is gone
     * (iOS ends the hop on disappear). Never await hop completion before [onClose] — rejoin can
     * take many seconds and made Close appear broken.
     */
    fun finishAndClose() {
        onClose()
    }

    // iOS `onDisappear { model.endInternetHop() }` — rejoin after leave, not before.
    DisposableEffect(frameioController) {
        val controller = frameioController
        onDispose {
            if (controller != null && controller.isInternetHopActive) {
                endInternetHopAfterDismiss(controller)
            }
        }
    }

    fun requestInternetHop() {
        val controller = frameioController
        if (controller == null) {
            hopError =
                "OpenZCine can't leave the camera Wi‑Fi from this surface. Reconnect from Your cameras on home Wi‑Fi to download RED LUTs."
            return
        }
        if (hopAvailability != FrameioHopAvailability.READY) {
            hopError =
                hopAvailability.operatorMessage.ifBlank {
                    "OpenZCine can't hop off this camera connection automatically."
                }
            return
        }
        scope.launch {
            hopBusy = true
            hopError = null
            val ok =
                try {
                    controller.beginInternetHop()
                } catch (_: Exception) {
                    false
                }
            hopBusy = false
            if (!ok) {
                hopError =
                    controller.errorMessage
                        ?: "OpenZCine couldn't leave the camera Wi‑Fi for an internet route."
            }
            // Poll gate immediately — hop success should expose validated internet.
            readiness = gate.readiness()
            if (ok && readiness.network == RedLutNetworkAvailability.AVAILABLE) {
                // Stay on gateway with active terms Continue (iOS post-hop unblock).
            }
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            readiness = gate.readiness()
            // After a successful hop, Frame.io marks Online while the phone is
            // on home Wi‑Fi / cellular — refresh hop-facing error when network flips.
            if (readiness.network == RedLutNetworkAvailability.AVAILABLE) {
                hopError = null
            }
            delay(1_000)
        }
    }

    // Mid-hop: surface controller progress until Online or Failed.
    val switchingNetworks =
        hopBusy ||
            hopState is FrameioInternetHopState.LeavingCamera ||
            hopState is FrameioInternetHopState.WaitingForInternet

    // Always allow leave — hop rejoin continues in the background after dismiss.
    BackHandler { finishAndClose() }

    Box(Modifier.fillMaxSize().background(LiveDesign.background)) {
        when (val current = phase) {
            RedDownloadPhase.Gateway ->
                RedDownloadGateway(
                    readiness = readiness,
                    switchingNetworks = switchingNetworks,
                    hopError = hopError,
                    canHop =
                        frameioController != null &&
                            hopAvailability == FrameioHopAvailability.READY,
                    onContinue = {
                        when (readiness.network) {
                            RedLutNetworkAvailability.AVAILABLE,
                            RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE,
                            -> phase = RedDownloadPhase.Browsing
                            RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT ->
                                requestInternetHop()
                            RedLutNetworkAvailability.NO_INTERNET -> Unit
                        }
                    },
                    onHop = ::requestInternetHop,
                    onClose = ::finishAndClose,
                )
            RedDownloadPhase.Browsing ->
                RedDownloadWebView(
                    onDownloadStarted = { phase = RedDownloadPhase.Downloading },
                    onProgress = { progress = it },
                    onFileReady = { file ->
                        phase = RedDownloadPhase.Importing
                        scope.launch {
                            val result =
                                withContext(Dispatchers.IO) {
                                    importRedZipOrCube(context, lutLibrary, file)
                                }
                            runCatching { file.delete() }
                            phase =
                                if (result.importedCount > 0) {
                                    onImported(result.importedCount)
                                    RedDownloadPhase.Success(result.importedCount)
                                } else {
                                    RedDownloadPhase.Failed(result.failureMessage)
                                }
                        }
                    },
                    onFailed = { phase = RedDownloadPhase.Failed(it) },
                )
            RedDownloadPhase.Downloading ->
                RedStatusPage(
                    title = "Downloading from RED…",
                    body = null,
                    progress = progress,
                    primary = null,
                    secondary = "Cancel" to ::finishAndClose,
                )
            RedDownloadPhase.Importing ->
                RedStatusPage(
                    title = "Adding LUTs…",
                    body = null,
                    progress = null,
                    primary = null,
                    secondary = "Cancel" to ::finishAndClose,
                )
            is RedDownloadPhase.Success ->
                RedStatusPage(
                    title =
                        if (current.count == 1) "1 RED LUT added"
                        else "${current.count} RED LUTs added",
                    body = "Find them under the RED tab in the LUT picker.",
                    progress = null,
                    primary = "Done" to ::finishAndClose,
                    secondary = null,
                )
            is RedDownloadPhase.Failed ->
                RedStatusPage(
                    title = "Download failed",
                    body = current.message,
                    progress = null,
                    primary =
                        "Retry" to {
                            phase = RedDownloadPhase.Gateway
                            progress = 0f
                        },
                    secondary = "Close" to ::finishAndClose,
                )
        }

        // Above the WebView (AndroidView) so ✕ always receives taps.
        RedCloseChip(
            onClick = ::finishAndClose,
            modifier =
                Modifier
                    .align(Alignment.TopStart)
                    .zIndex(2f)
                    .statusBarsPadding()
                    .padding(start = 8.dp, top = 4.dp),
        )
    }
}

/**
 * Ends a camera-AP internet hop after the RED cover is already gone.
 *
 * Uses a composition-independent scope so work survives [onClose] tearing down
 * [rememberCoroutineScope].
 */
private fun endInternetHopAfterDismiss(controller: FrameioDeliveryController) {
    CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
        try {
            withContext(NonCancellable) { controller.endInternetHop() }
        } catch (_: Exception) {
            // Rejoin best-effort; operator already left the RED surface.
        }
    }
}

/** Top-leading close control that stays above WebView hit targets. */
@Composable
private fun RedCloseChip(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier =
            modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(LiveDesign.glassBright.copy(alpha = 0.92f))
                .clickable(
                    interactionSource = interaction,
                    indication = null,
                    role = Role.Button,
                    onClick = onClick,
                ),
        contentAlignment = Alignment.Center,
    ) {
        Text("✕", color = LiveDesign.text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
    }
}

private sealed interface RedDownloadPhase {
    data object Gateway : RedDownloadPhase

    data object Browsing : RedDownloadPhase

    data object Downloading : RedDownloadPhase

    data object Importing : RedDownloadPhase

    data class Success(val count: Int) : RedDownloadPhase

    data class Failed(val message: String) : RedDownloadPhase
}

@Composable
private fun RedDownloadGateway(
    readiness: RedLutDownloadReadiness,
    switchingNetworks: Boolean,
    hopError: String?,
    canHop: Boolean,
    onContinue: () -> Unit,
    onHop: () -> Unit,
    onClose: () -> Unit,
) {
    // Match iOS: only block when there is no internet path (camera AP / offline).
    val blocked =
        readiness.network == RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT ||
            readiness.network == RedLutNetworkAvailability.NO_INTERNET
    Column(
        Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 36.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (blocked || switchingNetworks) {
            Text(
                "Internet required",
                style = chromeStyle(20f, FontWeight.Bold),
                color = LiveDesign.text,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            if (switchingNetworks) {
                // iOS mid-hop: ProgressView + "Switching networks…"
                CircularProgressIndicator(
                    color = LiveDesign.accent,
                    modifier = Modifier.size(28.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    "Switching networks…",
                    style = chromeStyle(14f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                    textAlign = TextAlign.Center,
                )
            } else {
                Text(
                    hopError ?: readiness.network.operatorMessage,
                    style = chromeStyle(14f, FontWeight.Normal),
                    color = LiveDesign.muted,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                if (readiness.network == RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT) {
                    CapsuleButton(
                        "Download over internet",
                        onClick = onHop,
                        enabled = canHop,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (canHop) {
                            "We'll hop off the camera's Wi‑Fi to download, then reconnect your camera automatically."
                        } else {
                            "Automatic hop needs a saved camera access-point profile with its Wi‑Fi key. Connect over the camera AP after pairing, or leave Wi‑Fi and open RED from home internet."
                        },
                        style = chromeStyle(12f, FontWeight.Normal),
                        color = LiveDesign.muted,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
            CapsuleButton(
                if (switchingNetworks) "Cancel" else "Close",
                onClick = onClose,
                bright = false,
            )
        } else {
            Text(
                "RED provides its IPP2 Output Presets for free, but you must accept RED's terms on RED's own site.",
                style = chromeStyle(15f, FontWeight.Medium),
                color = LiveDesign.text,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                "We'll open RED's real download page. Accept their terms there, then start the download — we'll import the LUTs automatically.",
                style = chromeStyle(13f, FontWeight.Normal),
                color = LiveDesign.muted,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(24.dp))
            CapsuleButton("Continue to RED's page", onClick = onContinue)
            Spacer(Modifier.height(12.dp))
            CapsuleButton("Close", onClick = onClose, bright = false)
        }
    }
}

@Composable
private fun CapsuleButton(
    label: String,
    onClick: () -> Unit,
    bright: Boolean = true,
    enabled: Boolean = true,
) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        modifier =
            Modifier
                .fillMaxWidth()
                .height(44.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(
                    when {
                        !enabled -> LiveDesign.glass.copy(alpha = 0.5f)
                        bright -> LiveDesign.glassBright
                        else -> LiveDesign.glass
                    },
                ),
    ) {
        Text(
            label,
            color = if (enabled) LiveDesign.text else LiveDesign.muted,
            fontWeight = FontWeight.SemiBold,
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun RedStatusPage(
    title: String,
    body: String?,
    progress: Float?,
    primary: Pair<String, () -> Unit>?,
    secondary: Pair<String, () -> Unit>? = null,
) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (progress == null && primary == null) {
            CircularProgressIndicator(color = LiveDesign.accent, modifier = Modifier.size(36.dp))
            Spacer(Modifier.height(16.dp))
        }
        Text(
            title,
            style = chromeStyle(18f, FontWeight.Bold),
            color = LiveDesign.text,
            textAlign = TextAlign.Center,
        )
        body?.let {
            Spacer(Modifier.height(10.dp))
            Text(
                it,
                style = chromeStyle(13f, FontWeight.Normal),
                color = LiveDesign.muted,
                textAlign = TextAlign.Center,
            )
        }
        progress?.let {
            Spacer(Modifier.height(16.dp))
            LinearProgressIndicator(
                progress = { it.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(0.7f),
                color = LiveDesign.accent,
                trackColor = LiveDesign.glass,
            )
        }
        primary?.let { (label, action) ->
            Spacer(Modifier.height(20.dp))
            CapsuleButton(label, onClick = action)
        }
        secondary?.let { (label, action) ->
            Spacer(Modifier.height(10.dp))
            CapsuleButton(label, onClick = action, bright = false)
        }
    }
}

/**
 * iOS-parity RED page: injects the same loading cover + T&C helper so the
 * operator only sees RED’s full-screen terms modal (accept + download at the
 * bottom). Intercepts `window.open` / attachment navigations and fetches the
 * zip in-process with page cookies — system [DownloadManager] is not used
 * (it misses RED’s popup path and often drops auth on S3).
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun RedDownloadWebView(
    onDownloadStarted: () -> Unit,
    onProgress: (Float) -> Unit,
    onFileReady: (File) -> Unit,
    onFailed: (String) -> Unit,
) {
    val context = LocalContext.current
    val fetchLock = remember { Any() }
    var fetchStarted by remember { mutableStateOf(false) }

    fun startAuthorizedFetch(url: String, userAgent: String?) {
        synchronized(fetchLock) {
            if (fetchStarted) return
            if (!isAllowedRedDownloadUrl(url)) {
                onFailed("RED's download came from an unexpected site and was blocked.")
                return
            }
            fetchStarted = true
        }
        onDownloadStarted()
        Thread {
                try {
                    val file =
                        fetchRedZip(
                            context = context,
                            url = url,
                            userAgent = userAgent,
                            onProgress = onProgress,
                        )
                    if (file != null) {
                        onFileReady(file)
                    } else {
                        onFailed("RED's download produced no file. Please try again.")
                    }
                } catch (error: Exception) {
                    onFailed(error.message ?: "Download failed.")
                }
            }
            .start()
    }

    AndroidView(
        factory = { ctx ->
            CookieManager.getInstance().setAcceptCookie(true)
            WebView(ctx).apply {
                layoutParams =
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                setBackgroundColor(android.graphics.Color.parseColor("#12100d"))
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.javaScriptCanOpenWindowsAutomatically = true
                settings.setSupportMultipleWindows(true)
                // RED may set session cookies then redirect the zip to S3.
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                webChromeClient =
                    object : WebChromeClient() {
                        override fun onCreateWindow(
                            view: WebView?,
                            isDialog: Boolean,
                            isUserGesture: Boolean,
                            resultMsg: android.os.Message?,
                        ): Boolean {
                            // RED’s accept button uses window.open(zipUrl). Capture the URL
                            // via a transient WebView and never display a popup store page.
                            val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false
                            val popup =
                                WebView(ctx).apply {
                                    settings.javaScriptEnabled = true
                                    webViewClient =
                                        object : WebViewClient() {
                                            private fun capture(url: String?) {
                                                val target = url?.takeIf {
                                                    it.isNotBlank() && !it.startsWith("about:")
                                                } ?: return
                                                if (isAllowedRedDownloadUrl(target)) {
                                                    startAuthorizedFetch(
                                                        target,
                                                        settings.userAgentString,
                                                    )
                                                }
                                            }

                                            override fun shouldOverrideUrlLoading(
                                                v: WebView?,
                                                request: WebResourceRequest?,
                                            ): Boolean {
                                                capture(request?.url?.toString())
                                                return true
                                            }

                                            override fun onPageStarted(
                                                v: WebView?,
                                                url: String?,
                                                favicon: android.graphics.Bitmap?,
                                            ) {
                                                capture(url)
                                            }
                                        }
                                }
                            transport.webView = popup
                            resultMsg.sendToTarget()
                            return true
                        }
                    }
                webViewClient =
                    object : WebViewClient() {
                        override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                            view?.evaluateJavascript(RED_LOADING_JS, null)
                        }

                        override fun onPageFinished(view: WebView?, url: String?) {
                            view?.evaluateJavascript(RED_LOADING_JS, null)
                            view?.evaluateJavascript(RED_HELPER_JS, null)
                        }

                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean {
                            val target = request?.url ?: return false
                            val disposition =
                                request.requestHeaders?.entries
                                    ?.firstOrNull {
                                        it.key.equals("Content-Disposition", ignoreCase = true)
                                    }
                                    ?.value
                                    ?.lowercase()
                            val looksLikeFile =
                                target.lastPathSegment?.endsWith(".zip", ignoreCase = true) == true ||
                                    disposition?.contains("attachment") == true
                            if (looksLikeFile && isAllowedRedDownloadUrl(target.toString())) {
                                startAuthorizedFetch(
                                    target.toString(),
                                    settings.userAgentString,
                                )
                                return true
                            }
                            return false
                        }

                        override fun onReceivedError(
                            view: WebView?,
                            request: WebResourceRequest?,
                            error: android.webkit.WebResourceError?,
                        ) {
                            if (request?.isForMainFrame != true || fetchStarted) return
                            onFailed(
                                error?.description?.toString()
                                    ?: "RED's page didn't load. Check your internet connection and try again.",
                            )
                        }
                    }
                // Fallback if RED ever uses a direct download navigation instead of window.open.
                setDownloadListener(
                    DownloadListener { url, userAgent, _, _, _ ->
                        startAuthorizedFetch(url, userAgent)
                    },
                )
                loadUrl(RED_IPP2_PRESETS_URL)
            }
        },
        modifier = Modifier.fillMaxSize(),
        onRelease = { view -> view.destroy() },
    )
}

/** Same host allowlist as iOS RedWebView.Coordinator.isAllowedDownloadURL. */
internal fun isAllowedRedDownloadUrl(url: String): Boolean {
    val uri =
        try {
            java.net.URI(url)
        } catch (_: Exception) {
            return false
        }
    val scheme = uri.scheme?.lowercase() ?: return false
    if (scheme != "http" && scheme != "https") return false
    val host = uri.host?.lowercase() ?: return false
    if (host == "reddigitalcinema.com" || host.endsWith(".reddigitalcinema.com")) return true
    if (host == "red.com" || host.endsWith(".red.com")) return true
    val path = uri.path.orEmpty().lowercase()
    if (host == "s3.amazonaws.com" && path.startsWith("/red-4/")) {
        return true
    }
    if (host == "red-4.s3.amazonaws.com") return true
    return false
}

/**
 * Cookie-bound HTTPS fetch of RED’s zip into app cache. Mirrors iOS
 * `URLSession` download with cached page cookies + UA.
 */
internal fun fetchRedZip(
    context: Context,
    url: String,
    userAgent: String?,
    onProgress: (Float) -> Unit,
): File? {
    val agent =
        userAgent?.takeIf { it.isNotBlank() }
            ?: "Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36"
    val connection =
        (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
            instanceFollowRedirects = true
            connectTimeout = 30_000
            readTimeout = 120_000
            requestMethod = "GET"
            setRequestProperty("User-Agent", agent)
            // Prefer the request-host jar, then RED's storefront (session often lives there
            // before the S3 redirect).
            val cookies = cookiesForRedDownload(url)
            if (!cookies.isNullOrBlank()) {
                setRequestProperty("Cookie", cookies)
            }
            setRequestProperty("Accept", "*/*")
            setRequestProperty("Referer", RED_IPP2_PRESETS_URL)
        }
    try {
        connection.connect()
        val code = connection.responseCode
        if (code !in 200..299) {
            throw IllegalStateException("RED returned HTTP $code. Please try again.")
        }
        val total = connection.contentLengthLong.takeIf { it > 0 } ?: -1L
        val destination = File(context.cacheDir, "red-ipp2-presets.zip")
        if (destination.exists()) destination.delete()
        connection.inputStream.use { input ->
            destination.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var written = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    written += read
                    if (total > 0) {
                        onProgress((written.toFloat() / total.toFloat()).coerceIn(0f, 1f))
                    }
                }
            }
        }
        onProgress(1f)
        if (destination.length() <= 0L) return null
        if (!destination.looksLikeZipArchive()) {
            val head =
                destination.inputStream().use { stream ->
                    val peek = ByteArray(64)
                    val n = stream.read(peek)
                    if (n <= 0) "" else String(peek, 0, n, Charsets.ISO_8859_1)
                }
            destination.delete()
            if (head.trimStart().startsWith("<") || head.contains("html", ignoreCase = true)) {
                throw IllegalStateException(
                    "RED returned a web page instead of the LUT archive. Accept the terms again and retry.",
                )
            }
            throw IllegalStateException(
                "RED's download was not a zip archive. Please try again.",
            )
        }
        return destination
    } finally {
        connection.disconnect()
    }
}

/** WebView cookie jar for the download URL and the RED storefront origin. */
internal fun cookiesForRedDownload(url: String): String? {
    val jar = CookieManager.getInstance()
    val direct = jar.getCookie(url)?.takeIf { it.isNotBlank() }
    if (direct != null) return direct
    return jar.getCookie("https://www.reddigitalcinema.com")?.takeIf { it.isNotBlank() }
        ?: jar.getCookie("https://reddigitalcinema.com")?.takeIf { it.isNotBlank() }
        ?: jar.getCookie("https://www.red.com")?.takeIf { it.isNotBlank() }
}

/** True when [File] starts with the local-file ZIP signature `PK\\x03\\x04` / `PK\\x05\\x06`. */
internal fun File.looksLikeZipArchive(): Boolean {
    if (!isFile || length() < 4L) return false
    return inputStream().use { stream ->
        val sig = ByteArray(4)
        if (stream.read(sig) < 4) return@use false
        sig[0] == 'P'.code.toByte() &&
            sig[1] == 'K'.code.toByte() &&
            (
                (sig[2] == 3.toByte() && sig[3] == 4.toByte()) ||
                    (sig[2] == 5.toByte() && sig[3] == 6.toByte()) ||
                    (sig[2] == 7.toByte() && sig[3] == 8.toByte())
            )
    }
}

/** Port of iOS RedWebView.loadingJS — full-screen cover until the T&C modal is ready. */
private const val RED_LOADING_JS =
    """
    (function () {
      if (window.__zcLoad) return;
      window.__zcLoad = true;
      var css = 'html,body{background:#12100d!important;}'
        + '#__zcLoading{position:fixed;top:0;right:0;bottom:0;left:0;background:#12100d;'
        + 'z-index:2147483647;display:flex;align-items:center;justify-content:center;flex-direction:column;}'
        + '#__zcLoading .s{width:34px;height:34px;border:3px solid rgba(255,255,255,0.25);'
        + 'border-top-color:#fff;border-radius:50%;animation:zcspin 0.8s linear infinite;}'
        + '#__zcLoading .t{color:#f2efe5;font:600 15px -apple-system,system-ui,sans-serif;margin-top:14px;}'
        + '@keyframes zcspin{to{transform:rotate(360deg);}}';
      var s = document.createElement('style');
      s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
      window.__zcCover = function (text) {
        var d = document.getElementById('__zcLoading');
        if (!d) {
          d = document.createElement('div');
          d.id = '__zcLoading';
          (document.body || document.documentElement).appendChild(d);
        }
        d.innerHTML = '<div class="s"></div><div class="t">' + text + '</div>';
      };
      function add() { window.__zcCover('Loading RED\u2019s terms\u2026'); }
      add();
      document.addEventListener('DOMContentLoaded', add);
    })();
    """

/** Port of iOS RedWebView.helperJS — TaC-only modal, cookie reject, auto-open terms. */
private const val RED_HELPER_JS =
    """
    (function () {
      if (window.__zcTc) return;
      window.__zcTc = true;
      var zcNativeOpen = window.open;
      window.open = function () {
        if (window.__zcCover) { window.__zcCover('Downloading from RED\u2026'); }
        return zcNativeOpen ? zcNativeOpen.apply(this, arguments) : null;
      };
      var style = document.createElement('style');
      style.textContent =
        '#terms-and-condition-modal.show{position:fixed!important;top:0!important;right:0!important;bottom:0!important;left:0!important;margin:0!important;padding:0!important;overflow:hidden!important;display:flex!important;}' +
        '#terms-and-condition-modal .modal-dialog{margin:0!important;width:100%!important;max-width:100%!important;height:100%!important;min-height:100%!important;display:flex!important;align-items:stretch!important;}' +
        '#terms-and-condition-modal .modal-content{flex:1 1 auto!important;width:100%!important;height:100%!important;display:flex!important;flex-direction:column!important;border:0!important;border-radius:0!important;}' +
        '#terms-and-condition-modal .modal-header,#terms-and-condition-modal .modal-footer{flex:0 0 auto!important;}' +
        '#terms-and-condition-modal .modal-body{flex:1 1 auto!important;min-height:0!important;overflow-y:auto!important;-webkit-overflow-scrolling:touch!important;padding-bottom:22px!important;}' +
        '#terms-and-condition-modal .modal-header .close,#terms-and-condition-modal .close,#terms-and-condition-modal .btn-close,#terms-and-condition-modal [data-dismiss="modal"],#terms-and-condition-modal [data-bs-dismiss="modal"]{display:none!important;}';
      if (document.head) document.head.appendChild(style);
      if (window.jQuery) {
        window.jQuery(document).on('hide.bs.modal', '#terms-and-condition-modal', function (e) { e.preventDefault(); });
      }
      var selectors = [
        'a.modal-download-button[data-name="IPP2 Output Presets"]',
        'a.modal-download-button[data-target="#terms-and-condition-modal"]',
        'a.modal-download-button'
      ];
      function reveal() { var d = document.getElementById('__zcLoading'); if (d && d.parentNode) d.parentNode.removeChild(d); }
      function cookieBtn() {
        var els = document.querySelectorAll('button, a, [role="button"]');
        for (var i = 0; i < els.length; i++) {
          var t = (els[i].textContent || '').trim().toLowerCase();
          if (t === 'reject all' || t === 'reject') return els[i];
        }
        return null;
      }
      var tries = 0;
      var timer = setInterval(function () {
        tries++;
        var cb = cookieBtn();
        if (cb) { cb.click(); }
        var modal = document.querySelector('#terms-and-condition-modal');
        var open = modal && getComputedStyle(modal).display !== 'none';
        if (open) {
          var wrapper = modal.querySelector('.terms-and-condition-wrapper');
          var loaded = wrapper && wrapper.textContent.trim().length > 40;
          if (loaded && !cookieBtn()) {
            clearInterval(timer);
            setTimeout(reveal, 500);
            return;
          }
          if (tries > 50) { clearInterval(timer); reveal(); return; }
          return;
        }
        for (var i = 0; i < selectors.length; i++) {
          var el = document.querySelector(selectors[i]);
          if (el) { el.click(); break; }
        }
        if (tries > 60) { clearInterval(timer); reveal(); }
      }, 300);
    })();
    """

/** Outcome of importing a RED download (zip or lone cube). */
internal data class RedLutImportResult(
    val importedCount: Int,
    val foundCubeEntries: Int = importedCount,
    val rejectedCubeEntries: Int = 0,
    val detail: String? = null,
) {
    val failureMessage: String
        get() =
            when {
                !detail.isNullOrBlank() -> detail
                foundCubeEntries == 0 ->
                    "We downloaded RED's file but it didn't contain any .cube LUTs."
                rejectedCubeEntries > 0 && importedCount == 0 ->
                    "We found $foundCubeEntries LUT(s) in RED's archive, but none could be validated. Try again, or reinstall if the shared engine is unavailable."
                else ->
                    "We downloaded RED's file but couldn't read any LUTs from it."
            }
}

/**
 * Imports a RED zip (or a lone .cube) into the RED stored-LUT category.
 *
 * Mirrors iOS `LUTFileStore.importZip`: walk every `.cube` entry (nested folders
 * OK, skip `__MACOSX`), keep original basenames for display, and accept up to
 * 512 files / 16 MB each (shared parser limit).
 *
 * **Never uses** [java.util.zip.ZipFile] or [java.util.zip.ZipInputStream].
 * Android 14+ [android.os.ZipPathValidator] rejects RED packs that include a
 * root entry named `/` ("invalid zip entry path: /"). Extraction goes through
 * [RedZipCubeExtractor] (pure local/central-directory walk), then each cube is
 * staged under app-private no-backup storage and validated into the RED library.
 */
internal suspend fun importRedZipOrCube(
    context: Context,
    library: AndroidLutLibrary,
    file: File,
): RedLutImportResult =
    withContext(Dispatchers.IO) {
        if (file.name.endsWith(".cube", ignoreCase = true)) {
            val ok = library.importRedCubeFile(file) != null
            return@withContext RedLutImportResult(
                importedCount = if (ok) 1 else 0,
                foundCubeEntries = 1,
                rejectedCubeEntries = if (ok) 0 else 1,
            )
        }
        if (!file.looksLikeZipArchive()) {
            return@withContext RedLutImportResult(
                importedCount = 0,
                detail = "RED's download was not a readable zip archive. Please try again.",
            )
        }
        val cubes =
            try {
                extractCubeEntriesFromZip(file)
            } catch (error: Exception) {
                return@withContext RedLutImportResult(
                    importedCount = 0,
                    detail =
                        "Couldn't open RED's archive (${error.message ?: "unknown error"}). Please try again.",
                )
            }
        if (cubes.isEmpty()) {
            return@withContext RedLutImportResult(
                importedCount = 0,
                foundCubeEntries = 0,
                detail = "We downloaded RED's file but it didn't contain any .cube LUTs.",
            )
        }
        // Stage cubes under app-private no-backup storage (not the system cache),
        // then hand each file to the RED library importer for Swift validation.
        val stagingRoot =
            File(context.applicationContext.noBackupFilesDir, "red-lut-import-staging")
        val staging = File(stagingRoot, "run-${System.nanoTime()}")
        staging.mkdirs()
        try {
            var imported = 0
            var rejected = 0
            for (cube in cubes) {
                val safeName = sanitizeCubeFileName(cube.fileName)
                val staged = File(staging, safeName)
                try {
                    staged.writeBytes(cube.bytes)
                    if (library.importRedCubeFile(staged) != null) {
                        imported += 1
                    } else {
                        rejected += 1
                    }
                } finally {
                    staged.delete()
                }
            }
            RedLutImportResult(
                importedCount = imported,
                foundCubeEntries = cubes.size,
                rejectedCubeEntries = rejected,
            )
        } finally {
            staging.deleteRecursively()
        }
    }

/**
 * Extracts `.cube` entries from a RED zip without Android's libcore zip APIs.
 *
 * Entry names may include a leading `/` (RED packs) or nested folders; only the
 * final path segment is kept for the on-disk display name.
 */
internal fun extractCubeEntriesFromZip(file: File): List<RedZipCubeEntry> =
    RedZipCubeExtractor.extractCubes(file)

/** Keeps only a safe basename for staging under app-private storage. */
internal fun sanitizeCubeFileName(raw: String): String {
    val base = raw.substringAfterLast('/').substringAfterLast('\\').ifBlank { "lut.cube" }
    val cleaned =
        buildString(base.length) {
            for (ch in base) {
                append(
                    when {
                        ch.isLetterOrDigit() || ch == '.' || ch == '-' || ch == '_' -> ch
                        else -> '_'
                    },
                )
            }
        }
    val withExt =
        if (cleaned.endsWith(".cube", ignoreCase = true)) cleaned else "$cleaned.cube"
    return withExt.take(180).ifBlank { "lut.cube" }
}
