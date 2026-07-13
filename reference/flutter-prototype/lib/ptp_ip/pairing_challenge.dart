import 'dart:typed_data';

/// Human-confirmed ZR pairing challenge returned by the pairing-info operation.
///
/// Nikon's Wi-Fi pairing payload is hardware-verified rather than publicly
/// documented, so the parser is intentionally tolerant: it keeps the raw bytes
/// for diagnostics and extracts a probable 4-digit PIN from common encodings.
class PairingChallenge {
  const PairingChallenge({
    required this.rawBytes,
    this.pin,
    this.cameraName,
  });

  /// Raw pairing-info bytes returned by the camera.
  final Uint8List rawBytes;

  /// Best-effort 4-digit PIN decoded from [rawBytes], or null if unknown.
  final String? pin;

  /// Camera name from the PTP-IP init ack, when available.
  final String? cameraName;

  /// Lowercase hex dump of [rawBytes].
  String get rawHex =>
      rawBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  /// Parses [data] into a pairing challenge, preserving [cameraName] if known.
  static PairingChallenge parse(Uint8List data, {String? cameraName}) {
    final raw = Uint8List.fromList(data);
    return PairingChallenge(
      rawBytes: raw,
      pin: _extractPin(raw),
      cameraName: cameraName,
    );
  }
}

String? _extractPin(Uint8List data) =>
    _pinFromAscii(data) ??
    _pinFromUtf16(data, Endian.little) ??
    _pinFromUtf16(data, Endian.big) ??
    _pinFromLengthPrefixedByteDigits(data) ??
    _pinFromLengthPrefixedBcd(data) ??
    _pinFromLengthPrefixedNumber(data) ??
    _pinFromStandaloneNumber(data) ??
    _pinFromBcd(data);

String? _pinFromAscii(Uint8List data) {
  final text = String.fromCharCodes(data);
  return RegExp(r'(?<!\d)(\d{4})(?!\d)').firstMatch(text)?.group(1);
}

String? _pinFromUtf16(Uint8List data, Endian endian) {
  if (data.length < 8) return null;
  for (var start = 0; start < 2; start++) {
    final chars = StringBuffer();
    for (var i = start; i + 1 < data.length; i += 2) {
      final unit = endian == Endian.little
          ? data[i] | (data[i + 1] << 8)
          : (data[i] << 8) | data[i + 1];
      if (unit >= 0x30 && unit <= 0x39) {
        chars.writeCharCode(unit);
      } else {
        chars.write(' ');
      }
    }
    final pin = RegExp(
      r'(?<!\d)(\d{4})(?!\d)',
    ).firstMatch(chars.toString())?.group(1);
    if (pin != null) return pin;
  }
  return null;
}

String? _pinFromLengthPrefixedByteDigits(Uint8List data) {
  for (final start in _lengthPrefixedStarts(data)) {
    if (start + 3 >= data.length) continue;
    final digits = data.sublist(start, start + 4);
    if (digits.every((d) => d <= 9)) return digits.join();
  }
  return null;
}

String? _pinFromLengthPrefixedBcd(Uint8List data) {
  for (final start in _lengthPrefixedStarts(data)) {
    final pin = _bcdAt(data, start);
    if (pin != null) return pin;
  }
  return null;
}

String? _pinFromLengthPrefixedNumber(Uint8List data) {
  for (final start in _lengthPrefixedStarts(data)) {
    final pin = _numberAt(data, start);
    if (pin != null) return pin;
  }
  return null;
}

String? _pinFromStandaloneNumber(Uint8List data) {
  if (data.length != 2 && data.length != 4) return null;
  return _numberAt(data, 0);
}

String? _pinFromBcd(Uint8List data) {
  for (var i = 0; i + 1 < data.length; i++) {
    final pin = _bcdAt(data, i);
    if (pin != null) return pin;
  }
  return null;
}

List<int> _lengthPrefixedStarts(Uint8List data) {
  final starts = <int>[];
  final bytes = ByteData.sublistView(data);
  if (data.length > 4 && bytes.getUint32(0, Endian.little) == 4) {
    starts.add(4);
  } else if (data.length > 2 && bytes.getUint16(0, Endian.little) == 4) {
    starts.add(2);
  }
  return starts;
}

String? _bcdAt(Uint8List data, int start) {
  if (start + 1 >= data.length) return null;
  final a = data[start];
  final b = data[start + 1];
  final digits = <int>[a >> 4, a & 0x0f, b >> 4, b & 0x0f];
  if (!digits.every((d) => d <= 9)) return null;
  return digits.join();
}

String? _numberAt(Uint8List data, int start) {
  final bytes = ByteData.sublistView(data);
  if (start + 1 < data.length) {
    final value = bytes.getUint16(start, Endian.little);
    final pin = _pinFromDecimalValue(value);
    if (pin != null) return pin;
  }
  if (start + 3 < data.length) {
    final value = bytes.getUint32(start, Endian.little);
    final pin = _pinFromDecimalValue(value);
    if (pin != null) return pin;
  }
  return null;
}

String? _pinFromDecimalValue(int value) {
  if (value < 1000 || value > 9999) return null;
  return value.toString().padLeft(4, '0');
}
