import 'dart:typed_data';

import 'live_view.dart' show Timecode;

/// Aperture: UINT16 f-number ×100 → `f/2.8`. 0xFFFF = error.
String decodeFnumber(int raw) {
  if (raw == 0xFFFF) return '—';
  final f = raw / 100.0;
  final s = f.toStringAsFixed(1);
  return 'f/${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}';
}

/// Shutter: UINT32, upper 16b numerator / lower 16b denominator.
String decodeShutterSpeed(int raw) {
  final numerator = (raw >> 16) & 0xFFFF;
  final denominator = raw & 0xFFFF;
  if (denominator == 0) return '—';
  if (denominator == 1) return '${numerator}s';
  if (numerator == 1) return '1/$denominator';
  return '$numerator/$denominator';
}

/// Cine shutter angle: INT32 angle ×100 → `180°`.
String decodeShutterAngle(int raw) {
  final deg = raw / 100.0;
  final s = deg.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}°';
}

/// Focal length: UINT32 mm ×100 → `50 mm`.
String decodeFocalLengthMm(int raw) {
  final mm = raw / 100.0;
  final s = mm.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} mm';
}

/// Decoded `MovieRecordScreenSize` (0xD0A0): resolution + frame rate.
class ScreenSize {
  const ScreenSize({
    required this.width,
    required this.height,
    required this.fps,
  });

  final int width;
  final int height;
  final int fps;

  String get label => '$width×$height';
}

/// Unpacks `MovieRecordScreenSize` UINT64: bits 48–63 H-res, 32–47 V-res,
/// 16–23 fps (integer).
ScreenSize decodeScreenSize(int raw) => ScreenSize(
      width: (raw >> 48) & 0xFFFF,
      height: (raw >> 32) & 0xFFFF,
      fps: (raw >> 16) & 0xFF,
    );

const Map<int, String> _codecNames = {
  0x00: 'H.264',
  0x01: 'H.265',
  0x02: 'N-RAW',
  0x10: 'ProRes 422 HQ',
  0x11: 'ProRes RAW HQ',
  0x31: 'R3D NE',
};
const Map<int, String> _containerNames = {
  0: 'MOV',
  1: 'MP4',
  2: 'NEV',
  3: 'R3D',
};

/// Unpacks `MovieFileType` UINT32: bits 16–23 codec, 8–15 bit-depth, 0–7 container.
String decodeFileType(int raw) {
  final codec = _codecNames[(raw >> 16) & 0xFF] ??
      '0x${((raw >> 16) & 0xFF).toRadixString(16)}';
  final depth = (raw >> 8) & 0xFF;
  final container =
      _containerNames[raw & 0xFF] ?? '0x${(raw & 0xFF).toRadixString(16)}';
  return '$codec $depth-bit $container';
}

const Map<int, String> _wbModeNames = {
  0x0002: 'Auto',
  0x0004: 'Sunny',
  0x0005: 'Fluorescent',
  0x0006: 'Incandescent',
  0x0007: 'Flash',
  0x8010: 'Cloudy',
  0x8011: 'Shade',
  0x8012: 'Color temp',
  0x8013: 'Preset',
  0x8016: 'Natural auto',
};

/// `MovieWhiteBalance`/`WhiteBalance` UINT16 mode → label, else hex.
String decodeWbMode(int raw) =>
    _wbModeNames[raw] ?? '0x${raw.toRadixString(16)}';

/// Immutable snapshot of the camera's decoded settings for the overlay. Each
/// round-robin read replaces one field via [copyWith].
class CameraState {
  const CameraState({
    this.iso,
    this.baseIso,
    this.shutterSpeed,
    this.shutterAngle,
    this.fnumber,
    this.wbMode,
    this.wbKelvin,
    this.resolution,
    this.fps,
    this.fileType,
    this.focalLength,
    this.focalMin,
    this.focalMax,
    this.apertureWide,
    this.timecode,
  });

  final int? iso;
  final String? baseIso; // 'Low' / 'High'
  final String? shutterSpeed;
  final String? shutterAngle;
  final String? fnumber;
  final String? wbMode;
  final int? wbKelvin;
  final String? resolution;
  final int? fps;
  final String? fileType;
  final String? focalLength;
  final int? focalMin; // lens min focal length, mm ×100
  final int? focalMax; // lens max focal length, mm ×100
  final int? apertureWide; // lens widest aperture, f-number ×100
  final Timecode? timecode;

  /// The attached-lens descriptor derived from its focal range + widest aperture
  /// (the ZR exposes no lens-name string), or null when no lens is reported.
  String? get lens => decodeLens(focalMin, focalMax, apertureWide);

  /// Returns a new [CameraState] with the given fields replaced; all others
  /// carry over from this instance.
  CameraState copyWith({
    int? iso,
    String? baseIso,
    String? shutterSpeed,
    String? shutterAngle,
    String? fnumber,
    String? wbMode,
    int? wbKelvin,
    String? resolution,
    int? fps,
    String? fileType,
    String? focalLength,
    int? focalMin,
    int? focalMax,
    int? apertureWide,
    Timecode? timecode,
  }) =>
      CameraState(
        iso: iso ?? this.iso,
        baseIso: baseIso ?? this.baseIso,
        shutterSpeed: shutterSpeed ?? this.shutterSpeed,
        shutterAngle: shutterAngle ?? this.shutterAngle,
        fnumber: fnumber ?? this.fnumber,
        wbMode: wbMode ?? this.wbMode,
        wbKelvin: wbKelvin ?? this.wbKelvin,
        resolution: resolution ?? this.resolution,
        fps: fps ?? this.fps,
        fileType: fileType ?? this.fileType,
        focalLength: focalLength ?? this.focalLength,
        focalMin: focalMin ?? this.focalMin,
        focalMax: focalMax ?? this.focalMax,
        apertureWide: apertureWide ?? this.apertureWide,
        timecode: timecode ?? this.timecode,
      );
}

Uint8List encodeUint16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();

Uint8List encodeUint32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

Uint8List encodeUint64(int v) =>
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

/// f-number (e.g. 2.8) → UINT16 ×100 little-endian.
Uint8List encodeFnumber(double f) => encodeUint16((f * 100).round());

Uint8List encodeUint8(int v) => Uint8List.fromList([v & 0xFF]);

/// `MovieBaseISOSensitivity` UINT8: 1 = Low (base 800), 2 = High (base 6400).
String decodeBaseIso(int raw) => switch (raw) {
      1 => 'Low',
      2 => 'High',
      _ => '0x${raw.toRadixString(16)}',
    };

/// Composes a lens descriptor from focal min/max (mm ×100) and the widest
/// aperture (f-number ×100): e.g. "24-70mm f/2.8" or "50mm f/1.8". Returns null
/// when the focal range is unknown (no lens mounted / not reported) — the ZR
/// exposes no lens-name string, so this derived label is the best available.
String? decodeLens(int? focalMinX100, int? focalMaxX100, int? apertureMinX100) {
  if (focalMinX100 == null || focalMaxX100 == null) return null;
  if (focalMinX100 == 0 && focalMaxX100 == 0) return null;
  final lo = _mm(focalMinX100);
  final hi = _mm(focalMaxX100);
  final range = lo == hi ? '${lo}mm' : '$lo-${hi}mm';
  if (apertureMinX100 == null || apertureMinX100 == 0) return range;
  return '$range ${decodeFnumber(apertureMinX100)}';
}

String _mm(int x100) {
  final mm = x100 / 100.0;
  final s = mm.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Extracts the enum value array from a DevicePropDesc data blob, located by its
/// trailing `formFlag(0x02) + count(UINT16) + count×valueBytes` tail. Returns an
/// empty list if the tail doesn't match (range form, or unexpected layout).
List<int> parseDevicePropDescEnum(Uint8List data, {required int valueBytes}) {
  for (var i = 0; i + 3 <= data.length; i++) {
    if (data[i] != 0x02) continue;
    final count = data[i + 1] | (data[i + 2] << 8);
    final start = i + 3;
    if (count > 0 && start + count * valueBytes == data.length) {
      final bd = ByteData.sublistView(data, start);
      return [
        for (var k = 0; k < count; k++)
          valueBytes == 2
              ? bd.getUint16(k * 2, Endian.little)
              : bd.getUint32(k * valueBytes, Endian.little),
      ];
    }
  }
  return const [];
}
