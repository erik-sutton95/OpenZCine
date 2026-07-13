import 'dart:io';
import 'dart:typed_data';

/// Fetches the bytes at [url] over HTTP(S), following redirects.
///
/// [cookieHeader] and [userAgent] are forwarded so a session-gated CDN link
/// (the kind RED hands out after the user accepts its terms in the WebView)
/// resolves the same way it would in the browser. Throws an [HttpException] on
/// any non-2xx status.
Future<Uint8List> downloadBytes(
  Uri url, {
  String? cookieHeader,
  String? userAgent,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    if (userAgent != null && userAgent.isNotEmpty) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Download failed (HTTP ${response.statusCode})',
        uri: url,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}
