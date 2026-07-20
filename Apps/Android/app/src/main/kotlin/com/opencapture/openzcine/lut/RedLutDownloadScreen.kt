package com.opencapture.openzcine.lut

import android.annotation.SuppressLint
import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.URLUtil
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.settings.SettingsLinkAction
import java.io.File
import java.util.zip.ZipInputStream
import kotlinx.coroutines.Dispatchers
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
 * Internet hop (leave camera AP) is requested via [onRequestInternetHop] when
 * the gate reports [RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT].
 */
@Composable
internal fun RedLutDownloadScreen(
    lutLibrary: AndroidLutLibrary,
    onRequestInternetHop: (() -> Unit)? = null,
    onClose: () -> Unit,
    onImported: (count: Int) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val gate = remember(context) { RedLutDownloadGate(context.applicationContext) }
    var readiness by remember { mutableStateOf(gate.readiness()) }
    var phase by remember { mutableStateOf<RedDownloadPhase>(RedDownloadPhase.Gateway) }
    var progress by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(Unit) {
        while (true) {
            readiness = gate.readiness()
            delay(1_500)
        }
    }

    BackHandler(onBack = onClose)

    Box(Modifier.fillMaxSize().background(LiveDesign.background)) {
        when (val current = phase) {
            RedDownloadPhase.Gateway ->
                RedDownloadGateway(
                    readiness = readiness,
                    onContinue = {
                        // iOS presents RED's public IPP2 page whenever internet
                        // is available — no private authorization endpoint.
                        when (readiness.network) {
                            RedLutNetworkAvailability.AVAILABLE,
                            RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE,
                            -> phase = RedDownloadPhase.Browsing
                            RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT ->
                                if (onRequestInternetHop != null) onRequestInternetHop()
                                else phase = RedDownloadPhase.Browsing
                            RedLutNetworkAvailability.NO_INTERNET -> Unit
                        }
                    },
                    onHop = onRequestInternetHop,
                    onClose = onClose,
                )
            RedDownloadPhase.Browsing ->
                RedDownloadWebView(
                    onDownloadStarted = { phase = RedDownloadPhase.Downloading },
                    onProgress = { progress = it },
                    onFileReady = { file ->
                        phase = RedDownloadPhase.Importing
                        scope.launch {
                            val count =
                                withContext(Dispatchers.IO) {
                                    importRedZipOrCube(context, lutLibrary, file)
                                }
                            runCatching { file.delete() }
                            phase =
                                if (count > 0) {
                                    onImported(count)
                                    RedDownloadPhase.Success(count)
                                } else {
                                    RedDownloadPhase.Failed(
                                        "We downloaded RED's file but couldn't read any LUTs from it.",
                                    )
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
                    onClose = onClose,
                )
            RedDownloadPhase.Importing ->
                RedStatusPage(
                    title = "Adding LUTs…",
                    body = null,
                    progress = null,
                    primary = null,
                    onClose = onClose,
                )
            is RedDownloadPhase.Success ->
                RedStatusPage(
                    title =
                        if (current.count == 1) "1 RED LUT added"
                        else "${current.count} RED LUTs added",
                    body = "Find them under the RED tab in the LUT picker.",
                    progress = null,
                    primary = "Done" to onClose,
                    onClose = onClose,
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
                    secondary = "Close" to onClose,
                    onClose = onClose,
                )
        }

        if (phase == RedDownloadPhase.Browsing || phase == RedDownloadPhase.Gateway) {
            TextButton(
                onClick = onClose,
                modifier = Modifier.align(Alignment.TopStart).padding(8.dp),
            ) {
                Text("✕", color = LiveDesign.text, fontSize = 20.sp)
            }
        }
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
    onContinue: () -> Unit,
    onHop: (() -> Unit)?,
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
        if (blocked) {
            Text(
                "Internet required",
                style = chromeStyle(20f, FontWeight.Bold),
                color = LiveDesign.text,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                readiness.network.operatorMessage,
                style = chromeStyle(14f, FontWeight.Normal),
                color = LiveDesign.muted,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(20.dp))
            if (
                readiness.network == RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT &&
                    onHop != null
            ) {
                CapsuleButton("Download over internet", onClick = onHop)
                Spacer(Modifier.height(8.dp))
                Text(
                    "We'll hop off the camera's Wi‑Fi to download, then reconnect your camera automatically.",
                    style = chromeStyle(12f, FontWeight.Normal),
                    color = LiveDesign.muted,
                    textAlign = TextAlign.Center,
                )
            }
            Spacer(Modifier.height(16.dp))
            CapsuleButton("Close", onClick = onClose, bright = false)
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
) {
    TextButton(
        onClick = onClick,
        modifier =
            Modifier
                .fillMaxWidth()
                .height(44.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(if (bright) LiveDesign.glassBright else LiveDesign.glass),
    ) {
        Text(label, color = LiveDesign.text, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
    }
}

@Composable
private fun RedStatusPage(
    title: String,
    body: String?,
    progress: Float?,
    primary: Pair<String, () -> Unit>?,
    secondary: Pair<String, () -> Unit>? = null,
    onClose: () -> Unit,
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

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun RedDownloadWebView(
    onDownloadStarted: () -> Unit,
    onProgress: (Float) -> Unit,
    onFileReady: (File) -> Unit,
    onFailed: (String) -> Unit,
) {
    val context = LocalContext.current
    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                layoutParams =
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                webChromeClient = WebChromeClient()
                webViewClient =
                    object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean = false
                    }
                setDownloadListener(
                    DownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
                        onDownloadStarted()
                        try {
                            val request =
                                DownloadManager.Request(Uri.parse(url)).apply {
                                    setMimeType(mimeType)
                                    addRequestHeader("User-Agent", userAgent)
                                    val cookies = CookieManager.getInstance().getCookie(url)
                                    if (!cookies.isNullOrBlank()) {
                                        addRequestHeader("Cookie", cookies)
                                    }
                                    setNotificationVisibility(
                                        DownloadManager.Request.VISIBILITY_VISIBLE,
                                    )
                                    val name =
                                        URLUtil.guessFileName(url, contentDisposition, mimeType)
                                    setDestinationInExternalFilesDir(
                                        ctx,
                                        Environment.DIRECTORY_DOWNLOADS,
                                        name,
                                    )
                                    setTitle(name)
                                }
                            val manager =
                                ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                            val id = manager.enqueue(request)
                            // Poll download completion on a background path.
                            Thread {
                                    try {
                                        val file =
                                            awaitDownload(ctx, manager, id, onProgress)
                                                ?: run {
                                                    onFailed("The download did not complete.")
                                                    return@Thread
                                                }
                                        onFileReady(file)
                                    } catch (error: Exception) {
                                        onFailed(error.message ?: "Download failed.")
                                    }
                                }
                                .start()
                        } catch (error: Exception) {
                            onFailed(error.message ?: "Could not start the download.")
                        }
                    },
                )
                loadUrl(RED_IPP2_PRESETS_URL)
            }
        },
        modifier = Modifier.fillMaxSize(),
        onRelease = { view -> view.destroy() },
    )
}

private fun awaitDownload(
    context: Context,
    manager: DownloadManager,
    id: Long,
    onProgress: (Float) -> Unit,
): File? {
    val query = DownloadManager.Query().setFilterById(id)
    while (true) {
        manager.query(query).use { cursor ->
            if (!cursor.moveToFirst()) return null
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val total =
                cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val soFar =
                cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                )
            if (total > 0) onProgress(soFar.toFloat() / total.toFloat())
            when (status) {
                DownloadManager.STATUS_SUCCESSFUL -> {
                    val uriString =
                        cursor.getString(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI),
                        ) ?: return null
                    val uri = Uri.parse(uriString)
                    val path = uri.path ?: return null
                    return File(path)
                }
                DownloadManager.STATUS_FAILED -> return null
                else -> Thread.sleep(250)
            }
        }
    }
}

/**
 * Imports a RED zip (or a lone .cube) into the RED stored-LUT category.
 * Returns how many cubes were accepted.
 */
internal suspend fun importRedZipOrCube(
    context: Context,
    library: AndroidLutLibrary,
    file: File,
): Int =
    withContext(Dispatchers.IO) {
        if (file.name.endsWith(".cube", ignoreCase = true)) {
            return@withContext if (library.importRedCubeFile(file) != null) 1 else 0
        }
        var imported = 0
        runCatching {
            ZipInputStream(file.inputStream().buffered()).use { zip ->
                var entry = zip.nextEntry
                var count = 0
                while (entry != null && count < 64) {
                    if (!entry.isDirectory && entry.name.endsWith(".cube", ignoreCase = true)) {
                        val bytes = zip.readBytes()
                        if (bytes.size in 1..(8 * 1024 * 1024)) {
                            val temp =
                                File.createTempFile("red-lut-", ".cube", context.cacheDir)
                            temp.writeBytes(bytes)
                            if (library.importRedCubeFile(temp) != null) imported += 1
                            temp.delete()
                        }
                        count += 1
                    }
                    zip.closeEntry()
                    entry = zip.nextEntry
                }
            }
        }
        imported
    }
