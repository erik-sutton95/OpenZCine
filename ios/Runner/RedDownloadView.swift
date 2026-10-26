import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenZCineCore
import SwiftUI

/// RED's IPP2 Output Presets download over the shared LUT pack flow
/// (`MonitorLutPackDownloadScreen`): RED's terms page, hosts, scripts and words, importing into
/// the RED category. RED's terms forbid bundling the presets, so the operator downloads them from
/// RED's own page. We present, we do not bypass: the bytes come from RED, the terms are accepted in
/// RED's UI, and only the download the operator triggers is taken over.
struct RedDownloadView: View {
    /// Imports the downloaded file into the RED category.
    let importPack: (URL) async -> MonitorLutPackImportResult
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Shared instance: see `InternetReachability.shared` for why a per-view `@State` is banned.
    private var reachability: InternetReachability { .shared }
    @State private var hop: RedLutPackHop?

    var body: some View {
        MonitorLutPackDownloadScreen(
            source: redLutPack,
            readiness: { availability.packReadiness },
            hop: hop,
            noHopMessage:
                "OpenZCine can't leave the camera Wi‑Fi from this surface. Reconnect from Your "
                + "cameras on home Wi‑Fi to download RED LUTs.",
            hopFailedMessage: "OpenZCine couldn't leave the camera Wi‑Fi for an internet route.",
            closeLabel: "Close",
            importPack: { file in await importPack(file).redOutcome },
            onClose: { dismiss() }
        )
        .onAppear { if hop == nil { hop = RedLutPackHop(model: model) } }
    }

    /// Whether the download may proceed right now from live reachability signals.
    /// `ZC_DEMO_RED_BLOCKED=ap|off` forces a blocked state for screenshots: the simulator can
    /// never actually be on a camera AP.
    private var availability: RedLUTDownloadAvailability {
        if let forced = DemoHarness.forcedRedAvailability {
            return forced == "ap" ? .blockedOnCameraAccessPoint : .blockedNoInternet
        }
        return reachability.redLUTDownloadAvailability
    }
}

/// The app's camera access point hop as the pack flow asks for it. The screen ends only the hop it
/// began and still owns; another owner's hop keeps running (A2-59).
@MainActor
final class RedLutPackHop: MonitorLutPackInternetHop {
    private let model: NativeAppModel
    private var token: MonitorInternetHop<NikonHopRoute>.Token?

    init(model: NativeAppModel) { self.model = model }

    var ready: Bool { true }
    var unavailableMessage: String? { nil }
    var switching: Bool { model.internetHopActive }
    var active: Bool { token.map(model.internetHop.owns) ?? false }
    var errorMessage: String? { nil }

    func begin() async -> Bool {
        // A refused begin (another hop already runs) keeps any token this screen already holds.
        guard let started = model.internetHop.begin(model.hopRoute()) else { return token != nil }
        token = started
        return true
    }

    func endAfterDismiss() {
        if let token, model.internetHop.owns(token) { model.internetHop.end(token) }
        token = nil
    }
}

/// Which surface presents the RED download. UIKit presents one cover at a time from each
/// controller, so a cover requested at the app root while the clip player's own full-screen cover
/// is up waits until the player closes. The LUT picker therefore names the surface it lives on
/// and only that surface's mount presents.
enum RedDownloadHost: Equatable, Sendable {
    /// The app root: the monitor, its panels and the standalone covers. The cover survives the
    /// monitor collapsing when the internet hop tears the camera session down mid-download.
    case root
    /// The clip player's cover: the download presents over the playing clip.
    case playback
}

extension View {
    /// The RED download cover for one surface. It presents only while `model.redDownloadHost`
    /// names `host`, and closing it clears that request and no other.
    func redDownloadCover(
        _ model: NativeAppModel, host: RedDownloadHost
    ) -> some View {
        redDownloadCover(model, host: host) {
            RedDownloadView { url in await model.importRedZip(from: url) }
        }
    }

    /// `content` stands in for the download screen in tests.
    func redDownloadCover(
        _ model: NativeAppModel, host: RedDownloadHost,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        fullScreenCover(
            isPresented: Binding(
                get: { model.redDownloadHost == host },
                set: { presented in
                    if !presented, model.redDownloadHost == host { model.redDownloadHost = nil }
                })
        ) {
            content()
                .environment(model)
                // A host that goes away with the cover up (the player closing) takes the cover
                // with it; clear the request so it does not reappear on the next clip.
                .onDisappear { if model.redDownloadHost == host { model.redDownloadHost = nil } }
        }
    }
}

extension RedLUTDownloadAvailability {
    /// The policy verdict in the pack flow's terms.
    var packReadiness: MonitorLutPackReadiness {
        switch self {
        case .available: MonitorLutPackReadiness(network: .available, message: "")
        case .blockedOnCameraAccessPoint:
            MonitorLutPackReadiness(network: .onCameraAccessPoint, message: blockedReason ?? "")
        case .blockedNoInternet:
            MonitorLutPackReadiness(network: .noInternet, message: blockedReason ?? "")
        }
    }
}

extension MonitorLutPackImportResult {
    /// RED's words for what the import made of the download (the Android adapter's `redOutcome`).
    var redOutcome: MonitorLutPackOutcome {
        if importedCount > 0 { return .imported(count: importedCount) }
        if notAnArchive {
            return .failed(
                message: "RED's download was not a readable zip archive. Please try again.")
        }
        if let archiveError {
            return .failed(
                message: "Couldn't open RED's archive (\(archiveError)). Please try again.")
        }
        if foundCubeEntries == 0 {
            return .failed(
                message: "We downloaded RED's file but it didn't contain any .cube LUTs.")
        }
        if rejectedCubeEntries > 0 {
            return .failed(
                message: "We found \(foundCubeEntries) LUT(s) in RED's archive, but none could be "
                    + "validated. Try again, or reinstall if the shared engine is unavailable.")
        }
        return .failed(message: "We downloaded RED's file but couldn't read any LUTs from it.")
    }
}

/// A failed RED page load in words, WITHOUT inventing a cause: the availability verdict when the
/// app knows the phone is on the camera's Wi-Fi or offline, the OS's own "no route", else RED's
/// plain page failure. Field report: "you appear to be on the camera's Wi-Fi" shown on home Wi-Fi
/// with working internet for a request that merely timed out.
func redDownloadFailureMessage(for error: NSError, availability: RedLUTDownloadAvailability)
    -> String
{
    redLutPack.copy.pageLoadFailure(error, readiness: availability.packReadiness)
}

/// The canonical RED IPP2 Output Presets page (the same URL as Android's RED_IPP2_PRESETS_URL).
let redIPP2PresetsURL = "https://www.reddigitalcinema.com/download/ipp2-output-presets"

let redLutPack = MonitorLutPackSource(
    pageUrl: redIPP2PresetsURL,
    archiveFileName: "red-ipp2-presets.zip",
    isAllowedDownload: isAllowedRedDownloadURL,
    // The session often lives on RED's storefront before the S3 redirect.
    cookieOrigins: [
        "https://www.reddigitalcinema.com", "https://reddigitalcinema.com", "https://www.red.com",
    ],
    loadingScript: redLoadingJS,
    helperScript: redHelperJS,
    copy: MonitorLutPackCopy(
        intro:
            "RED provides its IPP2 Output Presets for free, but you must accept RED's terms on RED's own site.",
        introDetail:
            "We'll open RED's real download page. Accept their terms there, then start the download, "
            + "and we'll import the LUTs automatically.",
        continueLabel: "Continue to RED's page",
        hopReady:
            "We'll hop off the camera's Wi‑Fi to download, then reconnect your camera automatically.",
        hopUnavailable:
            "Automatic hop needs a saved camera access-point profile with its Wi‑Fi key. Connect over "
            + "the camera AP after pairing, or leave Wi‑Fi and open RED from home internet.",
        downloading: "Downloading from RED…",
        success: { $0 == 1 ? "1 RED LUT added" : "\($0) RED LUTs added" },
        successDetail: "Find them under the RED tab in the LUT picker.",
        unexpectedSite: "RED's download came from an unexpected site and was blocked.",
        noFile: "RED's download produced no file. Please try again.",
        pageFailed: "RED's page didn't load. Check your internet connection and try again.",
        httpFailure: { "RED returned HTTP \($0). Please try again." },
        webPageInsteadOfArchive:
            "RED returned a web page instead of the LUT archive. Accept the terms again and retry.",
        notAnArchive: "RED's download was not a zip archive. Please try again.",
        opening: "Opening RED's download page…",
        unreadableLink: "Couldn't read RED's download link. Please try again.",
        pageKeptClosing: "RED's page kept closing. Please try again.",
        downloadNotStarted: "RED's download didn't start. Please accept the terms and try again."
    ))

/// RED storefront domains plus the S3 bucket their `DownloadUrl.Service.ss` API returns
/// (`https://s3.amazonaws.com/red-4/downloads/...`). An unexpected popup must never be fetched
/// and imported as a LUT. Same allowlist as Android's `isAllowedRedDownloadUrl`.
@Sendable func isAllowedRedDownloadURL(_ string: String) -> Bool {
    guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
    else { return false }
    let host = url.host?.lowercased() ?? ""
    if ["reddigitalcinema.com", "red.com"].contains(where: {
        host == $0 || host.hasSuffix("." + $0)
    }) {
        return true
    }
    // Path-style bucket URL from DownloadUrl.Service.ss (IPP2 Output Presets v1.13+).
    if host == "s3.amazonaws.com", url.path.lowercased().hasPrefix("/red-4/") { return true }
    // Virtual-hosted-style bucket URL, if RED ever switches formats.
    return host == "red-4.s3.amazonaws.com"
}

/// Injected at document start: a full-screen loading cover painted over RED's page (same render
/// layer as the eventual modal, so there's no compositing gap or white flash) until the helper
/// removes it once the terms are up.
private let redLoadingJS = """
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
      // Raise (or relabel) the cover. Exposed on `window` so the T&C helper can re-raise it the
      // instant the download starts - before RED's modal tears down and flashes the store page
      // underneath - reusing the same markup as the initial load cover.
      window.__zcCover = function (text) {
        var d = document.getElementById('__zcLoading');
        if (!d) {
          d = document.createElement('div');
          d.id = '__zcLoading';
          (document.body || document.documentElement).appendChild(d);
        }
        d.innerHTML = '<div class="s"></div><div class="t">' + text + '</div>';
      };
      function add() { window.__zcCover('Loading RED\\u2019s terms\\u2026'); }
      add();
      document.addEventListener('DOMContentLoaded', add);
    })();
    """

/// Reshapes RED's own T&C modal to fit a phone, auto-opens it, and removes RED's in-modal close
/// (so the app's own back button is the only exit). The user still scrolls and accepts there -
/// acceptance is what triggers RED's download. Best-effort and self-guarded.
private let redHelperJS = """
    (function () {
      if (window.__zcTc) return;
      window.__zcTc = true;
      // The moment RED triggers the download (its accept button calls window.open on the zip
      // URL), raise the cover again so the store page never shows in the gap between RED's modal
      // tearing down and our native download page appearing. Wrap - don't replace - so WebKit
      // still receives the window.open and hands the URL to createWebViewWith.
      var zcNativeOpen = window.open;
      window.open = function () {
        if (window.__zcCover) { window.__zcCover('Downloading from RED\\u2026'); }
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
      // Lock RED's modal open: block its own dismiss (X / backdrop / Esc) so the only exit is the
      // app's back button. Declining is still possible - via that button - without forcing accept.
      if (window.jQuery) {
        window.jQuery(document).on('hide.bs.modal', '#terms-and-condition-modal', function (e) { e.preventDefault(); });
      }
      var selectors = [
        'a.modal-download-button[data-name="IPP2 Output Presets"]',
        'a.modal-download-button[data-target="#terms-and-condition-modal"]',
        'a.modal-download-button'
      ];
      function reveal() { var d = document.getElementById('__zcLoading'); if (d && d.parentNode) d.parentNode.removeChild(d); }
      // RED shows a Ketch cookie-consent dialog first. Decline it (the most privacy-preserving
      // choice) so it can't sit on top of the terms or give the operator somewhere to wander.
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
          // Modal is up - wait until RED's AJAX has filled in the agreement text AND the cookie
          // dialog is gone before lifting the cover, so the operator only ever sees the terms.
          var wrapper = modal.querySelector('.terms-and-condition-wrapper');
          var loaded = wrapper && wrapper.textContent.trim().length > 40;
          if (loaded && !cookieBtn()) {
            // Give the modal a beat to finish painting under the cover, so it doesn't flash the
            // bare page as the cover lifts.
            clearInterval(timer);
            setTimeout(reveal, 500);
            return;
          }
          if (tries > 50) { clearInterval(timer); reveal(); return; }
          return;
        }
        // Click RED's own download button - NOT jQuery's .modal('show'). The click is what makes
        // RED fetch the agreement text into the modal; showing the modal directly leaves it blank.
        // Programmatic .click() lands on the element even if a banner overlaps it.
        for (var i = 0; i < selectors.length; i++) {
          var el = document.querySelector(selectors[i]);
          if (el) { el.click(); break; }
        }
        if (tries > 60) { clearInterval(timer); reveal(); }
      }, 300);
    })();
    """
