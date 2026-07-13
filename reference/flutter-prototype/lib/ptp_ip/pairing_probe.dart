import 'dart:typed_data';

import 'ptp_constants.dart';

/// One step of the read-only pairing probe: a single PTP transaction and its
/// captured result. Immutable; [PtpIpClient.probePairingSurface] builds a list
/// of these and [formatProbeReport] renders them for the operator to copy.
class ProbeStep {
  /// Creates a probe step. [data] defaults to empty when omitted.
  ProbeStep({
    required this.label,
    this.responseCode,
    Uint8List? data,
    this.error,
    this.note,
  }) : data = data ?? Uint8List(0);

  /// Human-readable step label (e.g. `GetCommandFeature(0x9455) (0x944C)`).
  final String label;

  /// PTP response code returned by the camera, or null if the step threw.
  final int? responseCode;

  /// Raw data-phase bytes (PTP-IP TransactionID prefix already stripped).
  final Uint8List data;

  /// Dart exception text if the transaction threw, else null.
  final String? error;

  /// Decoded one-line interpretation of [data], else null.
  final String? note;

  /// Returns a copy of this step with [note] attached.
  ProbeStep withNote(String note) => ProbeStep(
        label: label,
        responseCode: responseCode,
        data: data,
        error: error,
        note: note,
      );
}

/// Parses a PTP count-prefixed UINT32 array (e.g. a `GetVendorCodes` reply):
/// `Count(UINT32) + Count×UINT32`, all little-endian. Returns the elements
/// actually present (a short buffer yields a partial list). Throws
/// [FormatException] when there is not even a count word.
List<int> parseVendorCodeArray(Uint8List data) {
  if (data.length < 4) {
    throw FormatException(
      'vendor-code array has no count word: ${data.length} bytes',
    );
  }
  final bd = ByteData.sublistView(data);
  final count = bd.getUint32(0, Endian.little);
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    final offset = 4 + i * 4;
    if (offset + 4 > data.length) break; // truncated; return what we have
    out.add(bd.getUint32(offset, Endian.little));
  }
  return out;
}

/// Best-effort one-line summary of a `GetVendorCodes` reply: the count, the
/// codes (capped), and a flag when any undocumented `0x9455`–`0x945A` op is
/// present. Never throws.
String describeVendorCodes(Uint8List data) {
  List<int> codes;
  try {
    codes = parseVendorCodeArray(data);
  } on FormatException {
    return 'unparsed array (${data.length} bytes)';
  }
  const cap = 40;
  final shown = codes.length <= cap ? codes : codes.sublist(0, cap);
  final hex = shown.map((c) => '0x${c.toRadixString(16)}').join(', ');
  final more = codes.length > cap ? ', … (+${codes.length - cap})' : '';
  final undoc = codes.any((c) => c >= 0x9455 && c <= 0x945a)
      ? ' [incl undoc 0x9455-0x945A]'
      : '';
  return 'count=${codes.length}: $hex$more$undoc';
}

/// Interprets a `GetLiveViewImageEx` reply: a real frame is a 1024-byte header
/// followed by a JPEG (`FF D8 FF`) at offset 1024. The headline word
/// `LIVE VIEW WORKS` / `NO JPEG SOI` / `no data` is the pairing-gate oracle.
/// Never throws.
String describeLiveViewFrame(Uint8List data) {
  if (data.isEmpty) return 'no data returned (live view yielded nothing)';
  const jpegOffset = 1024;
  final hasSoi = data.length >= jpegOffset + 3 &&
      data[jpegOffset] == 0xff &&
      data[jpegOffset + 1] == 0xd8 &&
      data[jpegOffset + 2] == 0xff;
  if (!hasSoi) {
    return 'NO JPEG SOI at offset 1024 (${data.length} bytes) — frame not as expected';
  }
  final bd = ByteData.sublistView(data);
  final major = bd.getUint16(0, Endian.little);
  final minor = bd.getUint16(2, Endian.little);
  return 'LIVE VIEW WORKS: ${data.length} bytes, header v$major.$minor, '
      'JPEG SOI present at 1024';
}

/// One-line interpretation of a `LiveViewProhibitionCondition (0xD1A4)` read.
/// Never throws.
String describeProhibition(Uint8List data) {
  if (data.length < 4) return 'unreadable (${data.length} bytes)';
  final value = ByteData.sublistView(data).getUint32(0, Endian.little);
  final verdict = value == 0 ? 'OK to start live view' : 'live view PROHIBITED';
  return 'value=0x${value.toRadixString(16)} — $verdict';
}

/// Hex dump of [bytes], capped at [max] bytes, always suffixed with the total
/// byte count. Never throws.
String hexPreview(Uint8List bytes, {int max = 48}) {
  final shown =
      bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);
  final hex = shown.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  final suffix = bytes.length > max
      ? ' ... (${bytes.length} bytes)'
      : ' (${bytes.length} bytes)';
  return '$hex$suffix';
}

/// Renders a PTP response code: named for the few we care about, hex otherwise,
/// `(none)` for a step that threw before any response.
String formatResponseCode(int? code) {
  if (code == null) return '(none)';
  if (code == PtpResponse.ok) return 'OK(0x2001)';
  if (code == PtpResponse.deviceBusy) return 'Device_Busy(0x2019)';
  return '0x${code.toRadixString(16)}';
}

/// Renders the full probe report as copy-pasteable text.
String formatProbeReport(List<ProbeStep> steps) {
  final buffer = StringBuffer()
    ..writeln('=== OpenZCine pairing probe ===');
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    buffer.writeln('${i + 1}. ${step.label}');
    if (step.error != null) {
      buffer.writeln('    ERROR: ${step.error}');
      continue;
    }
    buffer.writeln(
      '    resp=${formatResponseCode(step.responseCode)}  data=${step.data.length}B',
    );
    final note = step.note;
    if (note != null && note.isNotEmpty) buffer.writeln('    note: $note');
    if (step.data.isNotEmpty)
      buffer.writeln('    hex: ${hexPreview(step.data)}');
  }
  return buffer.toString();
}
