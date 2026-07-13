import SwiftUI
import WebKit

/// Presents RED's real IPP2 Output Presets page so the operator accepts RED's terms and triggers
/// RED's own download. We **present, we do not bypass**: the bytes come from RED, terms are
/// accepted in RED's UI, and we intercept only the download the user triggers — no scraping,
/// no auto-accept, no constructed deep link.
struct RedDownloadView: View {
    /// Imports the downloaded zip and returns how many LUTs it recognized (0 = failed/empty).
    let onDownloaded: (URL) async -> Int
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var phase: DownloadPhase = .browsing
    /// Whether RED's page has committed a navigation yet. Until it does, the injected loading cover
    /// hasn't painted, so we show a native cover instead of a bare (black) web view.
    @State private var pageCommitted = false
    /// Bumping this recreates the web view (fresh WKWebView + reload) — used by Retry after a failure.
    @State private var reloadToken = 0
    @State private var reachability = InternetReachability()
    @State private var pageLoadWatchdog: Task<Void, Never>?

    /// Once the operator taps DOWNLOAD the flow takes over its own full-screen page, so they never
    /// drop back onto RED's store: downloading (with progress) → importing → success or failure.
    enum DownloadPhase: Equatable {
        case browsing
        case downloading(Double)
        case importing
        case success(Int)
        case failed(String)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LiveDesign.background.ignoresSafeArea()

            if started {
                // RED's page loads behind an injected loading cover (see RedWebView.loadingJS) until
                // the terms modal is up, so the operator can't wander RED's store during the wait.
                RedWebView(
                    onCommitted: {
                        pageCommitted = true
                        pageLoadWatchdog?.cancel()
                        pageLoadWatchdog = nil
                    },
                    onDownloadStarted: { phase = .downloading(0) },
                    onProgress: { fraction in
                        if case .downloading = phase { phase = .downloading(fraction) }
                    },
                    onDownloaded: { url in
                        phase = .importing
                        Task { @MainActor in
                            let count = await onDownloaded(url)
                            // Cubes are in the LUT store now — drop the tens-of-MB zip from
                            // tmp/caches instead of waiting for iOS to purge it.
                            try? FileManager.default.removeItem(at: url)
                            phase =
                                count > 0
                                ? .success(count)
                                : .failed(
                                    "We downloaded RED's file but couldn't read any LUTs from it.")
                        }
                    },
                    onFailed: { message in
                        pageLoadWatchdog?.cancel()
                        pageLoadWatchdog = nil
                        phase = .failed(message)
                    }
                )
                .id(reloadToken)
                .ignoresSafeArea()
            } else {
                gateway
            }

            // Native cover for the gap between "started" and RED's page committing — never show a
            // bare (black) web view. Once RED commits, the injected in-page cover takes over.
            if started, !pageCommitted, phase == .browsing {
                loadingCover
                    .transition(.opacity)
            }

            // Our own opaque status page over RED's page for the whole download → import → result.
            if phase != .browsing {
                DownloadStatusView(
                    phase: phase, onDismiss: { dismiss() },
                    onRetry: {
                        guard availability.isAvailable else {
                            phase = .failed(
                                availability.blockedReason
                                    ?? "Connect to the internet to download RED LUTs.")
                            return
                        }
                        phase = .browsing
                        started = true
                        pageCommitted = false
                        reloadToken += 1
                        armPageLoadWatchdog()
                    }
                )
                .transition(.opacity)
            }

            // The app's own exit. RED's in-page modal close is hidden so this single control backs
            // the operator out. Hidden on the result page, which carries its own Done/Close button.
            if showsCloseButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.4))
                }
                .buttonStyle(.zcTapTarget)
                .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        .onChange(of: reachability.redLUTDownloadAvailability) { _, availability in
            guard started, let reason = availability.blockedReason else { return }
            switch phase {
            case .browsing, .downloading, .importing:
                phase = .failed(reason)
            case .success, .failed:
                break
            }
        }
        .onChange(of: started) { _, isStarted in
            if isStarted {
                armPageLoadWatchdog()
            } else {
                pageLoadWatchdog?.cancel()
                pageLoadWatchdog = nil
            }
        }
        .onDisappear {
            pageLoadWatchdog?.cancel()
            pageLoadWatchdog = nil
            // If an internet hop is active, leaving this screen is the cue to rejoin the
            // camera's Wi‑Fi and reconnect. No-op otherwise.
            model.endInternetHop()
        }
    }

    /// Whether the download may proceed right now from live reachability signals.
    /// `ZC_DEMO_RED_BLOCKED=ap|off` forces a blocked state for screenshots — the simulator can
    /// never actually be on a camera AP.
    private var availability: RedLUTDownloadAvailability {
        if let forced = DemoHarness.forcedRedAvailability {
            return forced == "ap" ? .blockedOnCameraAccessPoint : .blockedNoInternet
        }
        return reachability.redLUTDownloadAvailability
    }

    /// Surfaces a connectivity failure when RED's page never commits (typical on camera AP / offline).
    private func armPageLoadWatchdog() {
        pageLoadWatchdog?.cancel()
        pageLoadWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            guard started, !pageCommitted, phase == .browsing else { return }
            let message =
                availability.blockedReason
                ?? "RED's page didn't load. Check your internet connection and try again."
            phase = .failed(message)
        }
    }

    private var showsCloseButton: Bool {
        switch phase {
        case .success, .failed: false
        default: true
        }
    }

    /// Branded, opaque loading state shown while RED's page connects — the backstop that keeps the
    /// screen from ever rendering black if the page is slow (or never) committing.
    private var loadingCover: some View {
        ZStack {
            LiveDesign.background.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(LiveDesign.accent)
                Text("Opening RED's download page…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    @ViewBuilder private var gateway: some View {
        if let reason = availability.blockedReason {
            blockedGateway(reason: reason)
        } else {
            activeGateway
        }
    }

    private var activeGateway: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 52))
                .foregroundStyle(LiveDesign.accent)
            Text(
                "RED provides its IPP2 Output Presets for free, but you must accept RED's terms on "
                    + "RED's own site."
            )
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(LiveDesign.text)
            Text(
                "We'll open RED's real download page and bring up their Terms & Conditions. Read and "
                    + "accept them there, and the LUTs download straight into the app."
            )
            .font(.system(size: 14))
            .foregroundStyle(LiveDesign.muted)
            Button {
                guard availability.isAvailable else { return }
                started = true
            } label: {
                Label("Continue to RED's page", systemImage: "safari")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(LiveDesign.accentDim, in: Capsule())
            }
            .buttonStyle(.zcTapTarget)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func blockedGateway(reason: String) -> some View {
        // Tighter metrics than the active gateway: with the hop CTA + caption this stack brushes
        // the ~400pt landscape height, and compressed Texts truncate instead of wrapping.
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Internet required")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LiveDesign.text)

            if model.internetHopActive {
                // Mid-hop: iOS is dropping the camera AP and settling on home Wi‑Fi or
                // cellular. Reachability flips this whole gateway to the download UI the
                // moment a usable path lands; Close below is the escape if none ever does.
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(LiveDesign.accent)
                    Text("Switching networks…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                }
            } else {
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(LiveDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if availability == .blockedOnCameraAccessPoint {
                    Button {
                        model.beginInternetHop()
                    } label: {
                        Label(
                            "Download over internet",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(LiveDesign.accentDim, in: Capsule())
                    }
                    .buttonStyle(.zcTapTarget)
                    .padding(.top, 6)

                    Text(
                        "We'll hop off the camera's Wi‑Fi to download, then reconnect your "
                            + "camera automatically."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(LiveDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    .background(
                        model.internetHopActive
                            || availability != .blockedOnCameraAccessPoint
                            ? LiveDesign.accentDim : LiveDesign.glass,
                        in: Capsule())
            }
            .buttonStyle(.zcTapTarget)
            .padding(.top, model.internetHopActive ? 6 : 0)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// The download flow's own full-screen page — opaque, so RED's store never shows through — walking
/// the operator from downloading (with a real progress bar) through importing to a clear
/// success/failure result.
private struct DownloadStatusView: View {
    let phase: RedDownloadView.DownloadPhase
    let onDismiss: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            LiveDesign.background.ignoresSafeArea()
            VStack(spacing: 18) {
                content
            }
            .padding(40)
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Swallow taps so RED's page behind the cover can't be poked.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .browsing:
            EmptyView()
        case .downloading(let fraction):
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 50))
                .foregroundStyle(LiveDesign.accent)
            Text("Downloading from RED…")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(LiveDesign.accent)
                .frame(width: 260)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(LiveDesign.muted)
        case .importing:
            ProgressView()
                .controlSize(.large)
                .tint(LiveDesign.accent)
            Text("Adding LUTs…")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
        case .success(let count):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("\(count) RED LUT\(count == 1 ? "" : "s") added")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Text("Find them under the RED tab in the LUT picker.")
                .font(.system(size: 14))
                .foregroundStyle(LiveDesign.muted)
                .multilineTextAlignment(.center)
            statusButton("Done", action: onDismiss)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Download failed")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(LiveDesign.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                statusButton("Retry", action: onRetry)
                statusButton("Close", action: onDismiss)
            }
        }
    }

    private func statusButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .background(LiveDesign.accentDim, in: Capsule())
        }
        .buttonStyle(.zcTapTarget)
        .padding(.top, 6)
    }
}

/// The embedded RED page: loads RED's IPP2 presets URL, injects the phone-friendly T&C helper, and
/// hands any download the user triggers back through `onDownloaded`.
private struct RedWebView: UIViewRepresentable {
    let onCommitted: () -> Void
    let onDownloadStarted: () -> Void
    let onProgress: (Double) -> Void
    let onDownloaded: (URL) -> Void
    let onFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCommitted: onCommitted,
            onDownloadStarted: onDownloadStarted, onProgress: onProgress,
            onDownloaded: onDownloaded, onFailed: onFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Paint a loading cover over RED's page from the first frame (in the page itself, so it
        // reliably sits above the WKWebView's own content) until the terms modal is ready.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.loadingJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.helperJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // RED's download button opens the file in a new window; allow it so the coordinator can
        // hand back a real popup web view and intercept the download there.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Dark (not white) before the page paints, so the hand-off into the cover is seamless.
        webView.isOpaque = false
        webView.backgroundColor = UIColor(LiveDesign.background)
        webView.scrollView.backgroundColor = UIColor(LiveDesign.background)
        if let url = URL(string: Self.redURLString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static let redURLString =
        "https://www.reddigitalcinema.com/download/ipp2-output-presets"

    /// Injected at document start: a full-screen loading cover painted over RED's page (same render
    /// layer as the eventual modal, so there's no compositing gap or white flash) until the helper
    /// removes it once the terms are up.
    private static let loadingJS = """
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
          // instant the download starts — before RED's modal tears down and flashes the store page
          // underneath — reusing the same markup as the initial load cover.
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
    /// (so the app's own back button is the only exit). The user still scrolls and accepts there —
    /// acceptance is what triggers RED's download. Best-effort and self-guarded.
    private static let helperJS = """
        (function () {
          if (window.__zcTc) return;
          window.__zcTc = true;
          // The moment RED triggers the download (its accept button calls window.open on the zip
          // URL), raise the cover again so the store page never shows in the gap between RED's modal
          // tearing down and our native download page appearing. Wrap — don't replace — so WebKit
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
          // app's back button. Declining is still possible — via that button — without forcing accept.
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
              // Modal is up — wait until RED's AJAX has filled in the agreement text AND the cookie
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
            // Click RED's own download button — NOT jQuery's .modal('show'). The click is what makes
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCommitted: () -> Void
        private let onDownloadStarted: () -> Void
        private let onProgress: (Double) -> Void
        private let onDownloaded: (URL) -> Void
        private let onFailed: (String) -> Void
        private var fetching = false
        private var completed = false
        private var watchdog: Task<Void, Never>?
        private var progressObservation: NSKeyValueObservation?
        /// Bounded so a page that keeps crashing can't reload into a black screen forever.
        private var reloadCount = 0
        /// Captured while the page is stable. We can't reliably read these at download time — RED's
        /// window.open churns the WebContent/networking processes, so reading the user agent or
        /// cookies there can stall past the watchdog.
        private var cachedUserAgent: String?
        private var cachedCookies: [HTTPCookie] = []

        /// First paint of RED's page — lifts the native loading cover so the injected in-page cover
        /// can take over without exposing a bare WKWebView frame.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onCommitted()
        }

        // Keep the user agent and cookies fresh on every page load, so the download can use them
        // without touching the web view at trigger time (when RED's window.open churns the process).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                if let agent = result as? String { self?.cachedUserAgent = agent }
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                [weak self] cookies in
                self?.cachedCookies = cookies
            }
        }

        // A dead WebContent process takes the injected loading cover with it, leaving a permanent
        // black screen. Reload once or twice to recover; if it keeps dying, surface an error rather
        // than hang on black.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !completed else { return }
            guard reloadCount < 2, let url = URL(string: RedWebView.redURLString) else {
                fail("RED's page kept closing. Please try again.")
                return
            }
            reloadCount += 1
            webView.load(URLRequest(url: url))
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            surfaceNavigationFailure(error)
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            surfaceNavigationFailure(error)
        }

        /// Turns a failed RED page load into a clear message instead of a stuck black cover — most
        /// commonly no internet route (phone on the camera's WAN-less Wi‑Fi AP). Ignores the cancels
        /// we trigger ourselves when intercepting the archive navigation (`.cancel` / WebKit 102).
        private func surfaceNavigationFailure(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            if fetching || completed { return }
            fail(Self.failureMessage(for: nsError))
        }

        private static func failureMessage(for error: NSError) -> String {
            let offlineCodes: Set<Int> = [
                NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                NSURLErrorNetworkConnectionLost,
            ]
            if error.domain == NSURLErrorDomain, offlineCodes.contains(error.code) {
                return "No internet connection. You appear to be connected to the camera's Wi‑Fi, "
                    + "which has no internet access. RED's download page needs internet — switch to "
                    + "a Wi‑Fi network or cellular with internet, then try again."
            }
            return "RED's page couldn't load (\(error.localizedDescription)). "
                + "Check your connection and try again."
        }

        init(
            onCommitted: @escaping () -> Void,
            onDownloadStarted: @escaping () -> Void, onProgress: @escaping (Double) -> Void,
            onDownloaded: @escaping (URL) -> Void, onFailed: @escaping (String) -> Void
        ) {
            self.onCommitted = onCommitted
            self.onDownloadStarted = onDownloadStarted
            self.onProgress = onProgress
            self.onDownloaded = onDownloaded
            self.onFailed = onFailed
        }

        /// Signals the download is under way (shows the overlay) and arms a watchdog so a stalled or
        /// non-file response surfaces an error instead of hanging silently. Idempotent.
        private func markStarted() {
            guard watchdog == nil, !completed else { return }
            onDownloadStarted()
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                // Cancelling the watchdog throws out of the sleep above; `try?` swallows it, so we
                // must bail here or a normal cancel would fire the "didn't start" failure itself.
                if Task.isCancelled { return }
                self?.fail("RED's download didn't start. Please accept the terms and try again.")
            }
        }

        private func finish(_ url: URL) {
            guard !completed else { return }
            completed = true
            watchdog?.cancel()
            progressObservation?.invalidate()
            onDownloaded(url)
        }

        private func fail(_ message: String) {
            guard !completed else { return }
            completed = true
            watchdog?.cancel()
            progressObservation?.invalidate()
            onFailed(message)
        }

        // RED triggers the download with a `window.open(...)` to the file URL. Letting WebKit open
        // the window fails (cross-origin process swap fails the provisional load — code 102) and
        // nothing downloads; grab the URL and fetch the bytes ourselves with the session cookies.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https"
            {
                fetchDownload(url)
            } else {
                fail("Couldn't read RED's download link. Please try again.")
            }
            return nil
        }

        // If RED ever navigates the page itself to the file (instead of window.open), it surfaces
        // here as a response WebKit can't render or one flagged as an attachment — fetch it the same
        // way and cancel the page navigation so we don't leave the terms.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            let attachment =
                (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
                .contains("attachment") ?? false
            if !navigationResponse.canShowMIMEType || attachment,
                let url = navigationResponse.response.url
            {
                fetchDownload(url)
                return .cancel
            }
            return .allow
        }

        /// RED storefront domains plus the S3 bucket their `DownloadUrl.Service.ss` API returns
        /// (`https://s3.amazonaws.com/red-4/downloads/...`). An unexpected popup must never be
        /// fetched and imported as a LUT.
        private static let allowedDownloadHosts = ["reddigitalcinema.com", "red.com"]

        /// Returns whether `url` is a RED-hosted IPP2 preset zip the operator just authorized.
        private static func isAllowedDownloadURL(_ url: URL) -> Bool {
            let host = url.host?.lowercased() ?? ""
            if allowedDownloadHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return true
            }
            // Path-style bucket URL from DownloadUrl.Service.ss (IPP2 Output Presets v1.13+).
            if host == "s3.amazonaws.com", url.path.lowercased().hasPrefix("/red-4/") {
                return true
            }
            // Virtual-hosted-style bucket URL, if RED ever switches formats.
            if host == "red-4.s3.amazonaws.com" { return true }
            return false
        }

        /// Fetches RED's preset zip directly, carrying the cookies + user agent cached from page load
        /// so RED's server authorizes it as it would the in-page download. Runs **synchronously** —
        /// it touches nothing on the web view, which can stall during RED's window.open process churn
        /// — so the download always starts and the "didn't start" watchdog can't fire.
        private func fetchDownload(_ url: URL) {
            guard !fetching, !completed else { return }
            guard Self.isAllowedDownloadURL(url) else {
                fail("RED's download came from an unexpected site and was blocked.")
                return
            }
            fetching = true
            markStarted()
            let host = url.host?.lowercased() ?? ""
            let relevant = cachedCookies.filter { cookie in
                let domain =
                    cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            var request = URLRequest(url: url)
            for (field, value) in HTTPCookie.requestHeaderFields(with: relevant) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if let agent = cachedUserAgent {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            startDownload(request)
        }

        /// Downloads the zip with byte progress, moving the finished file off the system's temporary
        /// location before the completion handler returns (it's deleted otherwise).
        private func startDownload(_ request: URLRequest) {
            guard !completed else { return }
            // The transfer is now in URLSession's hands (with its own timeouts), so retire the
            // "didn't start" watchdog.
            watchdog?.cancel()
            let task = URLSession.shared.downloadTask(with: request) {
                [weak self] location, response, error in
                var moved: URL?
                if let location {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("red-ipp2-presets.zip")
                    try? FileManager.default.removeItem(at: destination)
                    if (try? FileManager.default.moveItem(at: location, to: destination)) != nil {
                        moved = destination
                    }
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if let errorMessage {
                        self.fail(errorMessage)
                    } else if let statusCode, !(200..<300).contains(statusCode) {
                        self.fail("RED returned HTTP \(statusCode). Please try again.")
                    } else if let moved {
                        self.finish(moved)
                    } else {
                        self.fail("RED's download produced no file. Please try again.")
                    }
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) {
                [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.onProgress(fraction) }
            }
            task.resume()
        }
    }
}
