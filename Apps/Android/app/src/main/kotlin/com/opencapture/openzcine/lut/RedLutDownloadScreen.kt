package com.opencapture.openzcine.lut

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.opencapture.opencine.cameracontrols.MonitorLutPackCopy
import com.opencapture.opencine.cameracontrols.MonitorLutPackDownloadScreen
import com.opencapture.opencine.cameracontrols.MonitorLutPackImportResult
import com.opencapture.opencine.cameracontrols.MonitorLutPackInternetHop
import com.opencapture.opencine.cameracontrols.MonitorLutPackNetwork
import com.opencapture.opencine.cameracontrols.MonitorLutPackOutcome
import com.opencapture.opencine.cameracontrols.MonitorLutPackReadiness
import com.opencapture.opencine.cameracontrols.MonitorLutPackSource
import com.opencapture.opencine.cameracontrols.importPack
import com.opencapture.opencine.frameio.FrameioDeliveryController
import com.opencapture.opencine.frameio.FrameioHopAvailability
import com.opencapture.opencine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.R
import java.io.File

/** Canonical RED IPP2 Output Presets page — same URL as iOS RedDownloadView. */
internal const val RED_IPP2_PRESETS_URL =
    "https://www.reddigitalcinema.com/download/ipp2-output-presets"

/**
 * The RED IPP2 Output Presets download: RED's terms page, hosts, scripts and words over the shared
 * LUT pack flow ([MonitorLutPackDownloadScreen]), importing into the RED category. RED's terms
 * forbid bundling the presets, so the operator downloads them from RED's own page.
 *
 * The camera access point hop reuses [FrameioDeliveryController.beginInternetHop] and rejoins the
 * camera after the screen closes.
 */
@Composable
internal fun RedLutDownloadScreen(
    lutLibrary: AndroidLutLibrary,
    frameioController: FrameioDeliveryController? = null,
    onClose: () -> Unit,
    onImported: (count: Int) -> Unit = {},
) {
    val context = LocalContext.current
    val gate = remember(context) { RedLutDownloadGate(context.applicationContext) }
    val staging = remember(context) { File(context.applicationContext.noBackupFilesDir, "red-lut-import-staging") }
    MonitorLutPackDownloadScreen(
        source = RED_LUT_PACK,
        readiness = { gate.readiness().network.packReadiness() },
        hop = frameioController?.let(::RedLutPackHop),
        noHopMessage = "OpenZCine can't leave the camera Wi‑Fi from this surface. Reconnect from Your cameras on " +
            "home Wi‑Fi to download RED LUTs.",
        hopFailedMessage = "OpenZCine couldn't leave the camera Wi‑Fi for an internet route.",
        closeLabel = stringResource(R.string.action_close),
        importPack = { file -> lutLibrary.importPack(StoredLutCategory.RED, file, staging).redOutcome() },
        onClose = onClose,
        onImported = onImported,
    )
}

/** The Frame.io controller's camera access point hop, as the pack flow asks for it. */
private class RedLutPackHop(private val controller: FrameioDeliveryController) : MonitorLutPackInternetHop {
    override val ready: Boolean get() = controller.cameraHopAvailability == FrameioHopAvailability.READY
    override val unavailableMessage: String
        get() = controller.cameraHopAvailability.operatorMessage
            .ifBlank { "OpenZCine can't hop off this camera connection automatically." }
    override val switching: Boolean
        get() = controller.internetHopState is FrameioInternetHopState.LeavingCamera ||
            controller.internetHopState is FrameioInternetHopState.WaitingForInternet
    override val active: Boolean get() = controller.isInternetHopActive
    override val errorMessage: String? get() = controller.errorMessage
    override suspend fun begin(): Boolean = controller.beginInternetHop()
    override fun endAfterDismiss() = controller.endInternetHopAfterDismiss()
}

internal fun RedLutNetworkAvailability.packReadiness(): MonitorLutPackReadiness = MonitorLutPackReadiness(
    when (this) {
        RedLutNetworkAvailability.AVAILABLE -> MonitorLutPackNetwork.AVAILABLE
        RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT -> MonitorLutPackNetwork.ON_CAMERA_ACCESS_POINT
        RedLutNetworkAvailability.NO_INTERNET -> MonitorLutPackNetwork.NO_INTERNET
        RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE -> MonitorLutPackNetwork.POLICY_UNAVAILABLE
    },
    operatorMessage,
)

/** RED's words for what the import made of the download. */
internal fun MonitorLutPackImportResult.redOutcome(): MonitorLutPackOutcome = when {
    importedCount > 0 -> MonitorLutPackOutcome.Imported(importedCount)
    notAnArchive -> MonitorLutPackOutcome.Failed("RED's download was not a readable zip archive. Please try again.")
    archiveError != null -> MonitorLutPackOutcome.Failed("Couldn't open RED's archive ($archiveError). Please try again.")
    foundCubeEntries == 0 -> MonitorLutPackOutcome.Failed("We downloaded RED's file but it didn't contain any .cube LUTs.")
    rejectedCubeEntries > 0 -> MonitorLutPackOutcome.Failed("We found $foundCubeEntries LUT(s) in RED's archive, but none " +
        "could be validated. Try again, or reinstall if the shared engine is unavailable.")
    else -> MonitorLutPackOutcome.Failed("We downloaded RED's file but couldn't read any LUTs from it.")
}

internal val RED_LUT_PACK: MonitorLutPackSource = MonitorLutPackSource(
    pageUrl = RED_IPP2_PRESETS_URL,
    archiveFileName = "red-ipp2-presets.zip",
    isAllowedDownload = ::isAllowedRedDownloadUrl,
    // The session often lives on RED's storefront before the S3 redirect.
    cookieOrigins = listOf("https://www.reddigitalcinema.com", "https://reddigitalcinema.com", "https://www.red.com"),
    loadingScript = RED_LOADING_JS,
    helperScript = RED_HELPER_JS,
    copy = MonitorLutPackCopy(
        intro = "RED provides its IPP2 Output Presets for free, but you must accept RED's terms on RED's own site.",
        introDetail = "We'll open RED's real download page. Accept their terms there, then start the download — " +
            "we'll import the LUTs automatically.",
        continueLabel = "Continue to RED's page",
        hopReady = "We'll hop off the camera's Wi‑Fi to download, then reconnect your camera automatically.",
        hopUnavailable = "Automatic hop needs a saved camera access-point profile with its Wi‑Fi key. Connect over " +
            "the camera AP after pairing, or leave Wi‑Fi and open RED from home internet.",
        downloading = "Downloading from RED…",
        success = { count -> if (count == 1) "1 RED LUT added" else "$count RED LUTs added" },
        successDetail = "Find them under the RED tab in the LUT picker.",
        unexpectedSite = "RED's download came from an unexpected site and was blocked.",
        noFile = "RED's download produced no file. Please try again.",
        pageFailed = "RED's page didn't load. Check your internet connection and try again.",
        httpFailure = { code -> "RED returned HTTP $code. Please try again." },
        webPageInsteadOfArchive = "RED returned a web page instead of the LUT archive. Accept the terms again and retry.",
        notAnArchive = "RED's download was not a zip archive. Please try again.",
    ),
)

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
