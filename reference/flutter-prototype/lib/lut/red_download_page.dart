import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'lut_downloader.dart';
import 'lut_library.dart';

/// JavaScript injected into RED's page to make their consent flow phone-friendly.
///
/// It does two things, both best-effort and self-guarded so they run once and
/// no-op if RED changes its markup:
///   1. Adds presentational CSS so RED's own Terms & Conditions modal fits the
///      screen with the accept toggle + download button reachable (a body that
///      scrolls internally instead of the modal overflowing the viewport). This
///      only reshapes RED's existing controls — it does not alter the terms text
///      or accept anything.
///   2. Polls for RED's own download button (it renders after load) and clicks
///      it to surface RED's real T&C modal. The user still scrolls and accepts
///      there; that acceptance is what triggers the download.
const String _redHelpersJs = '''
(function () {
  if (window.__zcTc) return;
  window.__zcTc = true;

  var style = document.createElement('style');
  style.textContent =
    '#terms-and-condition-modal{overflow:hidden!important;}' +
    '#terms-and-condition-modal .modal-dialog{margin:0!important;width:100%!important;max-width:100%!important;height:100%!important;}' +
    '#terms-and-condition-modal .modal-content{height:100%!important;display:flex!important;flex-direction:column!important;border:0!important;border-radius:0!important;}' +
    '#terms-and-condition-modal .modal-header,#terms-and-condition-modal .modal-footer{flex:0 0 auto!important;}' +
    '#terms-and-condition-modal .modal-body{flex:1 1 auto!important;min-height:0!important;overflow-y:auto!important;-webkit-overflow-scrolling:touch!important;}' +
    '#terms-and-condition-modal .modal-footer{display:flex!important;flex-wrap:wrap!important;gap:8px!important;align-items:center!important;justify-content:flex-end!important;}' +
    '#terms-and-condition-modal .modal-header .close{display:none!important;}';
  if (document.head) document.head.appendChild(style);

  // Keep the user on RED's T&C while it is open: block the modal's own dismiss
  // (X / backdrop / Esc) so the only exits are accepting (which downloads) or
  // the app's own back button. Declining is still possible — via that back
  // button — so this focuses the flow without forcing acceptance.
  if (window.jQuery) {
    window.jQuery(document).on(
      'hide.bs.modal',
      '#terms-and-condition-modal',
      function (e) { e.preventDefault(); }
    );
  }

  var selectors = [
    'a.modal-download-button[data-name="IPP2 Output Presets"]',
    'a.modal-download-button[data-target="#terms-and-condition-modal"]',
    'a.modal-download-button'
  ];
  var tries = 0;
  var timer = setInterval(function () {
    tries++;
    var modal = document.querySelector('#terms-and-condition-modal');
    if (modal && getComputedStyle(modal).display !== 'none') {
      clearInterval(timer);
      return;
    }
    var el = null;
    for (var i = 0; i < selectors.length; i++) {
      el = document.querySelector(selectors[i]);
      if (el) break;
    }
    if (el) {
      clearInterval(timer);
      el.scrollIntoView({block: 'center'});
      el.click();
    } else if (tries > 40) {
      clearInterval(timer);
    }
  }, 500);
})();
''';

/// Presents RED's real IPP2 Output Presets page so the user can read and accept
/// RED's terms and trigger RED's own download.
///
/// Flow: a native gateway screen explains what's about to happen, then the
/// embedded WebView loads RED's actual page. As a convenience we auto-open
/// RED's own T&C modal (see [_openTermsModalJs]); the user still accepts there.
///
/// Compliance: this screen **presents, it does not bypass**. The bytes come
/// from RED, the user accepts RED's real terms in RED's UI, and we intercept
/// only the download the user triggers — no scraping, no auto-accept, no
/// constructed deep link. Pops with the imported `List<StoredLut>` on success,
/// or `null` if the user backs out.
class RedDownloadPage extends StatefulWidget {
  const RedDownloadPage({required this.library, super.key});

  /// Store that receives the downloaded cubes.
  final LutLibrary library;

  @override
  State<RedDownloadPage> createState() => _RedDownloadPageState();
}

class _RedDownloadPageState extends State<RedDownloadPage> {
  static final WebUri _redUrl = WebUri(
    'https://www.reddigitalcinema.com/download/ipp2-output-presets',
  );

  bool _started = false; // false = native gateway, true = WebView
  bool _busy = false; // downloading/extracting overlay
  String _status = '';
  double _progress = 0; // page-load progress, 0..1
  bool _helpersInjected = false; // inject the RED page helpers once

  Future<void> _handleDownload(
    InAppWebViewController controller,
    WebUri url,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Downloading…';
    });
    try {
      final cookies = await CookieManager.instance().getCookies(url: url);
      final cookieHeader = cookies
          .where((c) => c.value != null)
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      final uaResult =
          await controller.evaluateJavascript(source: 'navigator.userAgent');
      final userAgent =
          uaResult is String && uaResult.isNotEmpty ? uaResult : null;

      final bytes = await downloadBytes(
        url,
        cookieHeader: cookieHeader.isEmpty ? null : cookieHeader,
        userAgent: userAgent,
      );

      if (!mounted) return;
      setState(() => _status = 'Extracting…');
      final imported = await _importDownload(url, bytes);

      if (!mounted) return;
      Navigator.of(context).pop(imported);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  Future<List<StoredLut>> _importDownload(WebUri url, Uint8List bytes) async {
    final lastSegment =
        url.pathSegments.isNotEmpty ? url.pathSegments.last : '';
    if (lastSegment.toLowerCase().endsWith('.cube')) {
      final tmp = File('${Directory.systemTemp.path}/$lastSegment');
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        return <StoredLut>[await widget.library.importCubeFile(tmp.path)];
      } finally {
        if (tmp.existsSync()) await tmp.delete();
      }
    }
    return widget.library.importZipBytes(bytes);
  }

  Future<void> _injectRedHelpers(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (_helpersInjected) return;
    if (url == null || !url.host.contains('reddigitalcinema')) return;
    _helpersInjected = true; // the injected script self-polls; inject once
    try {
      await controller.evaluateJavascript(source: _redHelpersJs);
    } on Object {
      // Best-effort; the user can still tap Download themselves.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _started ? _buildWebView(context) : _buildGateway(context),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: Colors.black38,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGateway(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              "RED provides its IPP2 Output Presets for free, but you must "
              "accept RED's terms on RED's own site.",
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Text(
              "We'll open RED's real download page and bring up their Terms & "
              'Conditions. Read and accept them there, and the LUTs download '
              'straight into the app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => setState(() => _started = true),
              icon: const Icon(Icons.open_in_browser),
              label: const Text("Continue to RED's page"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView(BuildContext context) {
    return Stack(
      children: [
        SafeArea(
          child: Column(
            children: [
              if (_progress < 1.0)
                LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                ),
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: _redUrl),
                  initialSettings:
                      InAppWebViewSettings(useOnDownloadStart: true),
                  onProgressChanged: (controller, progress) {
                    if (mounted) setState(() => _progress = progress / 100.0);
                  },
                  onLoadStop: _injectRedHelpers,
                  onDownloadStartRequest: (controller, request) =>
                      _handleDownload(controller, request.url),
                ),
              ),
            ],
          ),
        ),
        if (_busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      _status,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
