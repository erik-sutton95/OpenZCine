import 'dart:typed_data';

/// A parsed Adobe/IRIDAS `.cube` 3D LUT. [rgb] holds `size³` RGB triplets in
/// the cube's canonical **red-fastest** order (index = r + g·size + b·size²).
class CubeLut {
  CubeLut({required this.size, required this.rgb})
      : assert(
          rgb.length == size * size * size * 3,
          'rgb length must be 3·size³',
        );

  /// Edge length of the cube (e.g. 33 for a 33×33×33 LUT).
  final int size;

  /// `size³ × 3` float samples in [0, 1], red-fastest.
  final Float32List rgb;
}

/// Parses a 3D `.cube` LUT. Skips comments/metadata; reads `LUT_3D_SIZE` and the
/// data triplets. Domain is assumed 0–1 (the common case). Throws
/// [FormatException] on a missing size or a triplet count that doesn't match.
CubeLut parseCubeLut(String text) {
  int? size;
  final values = <double>[];
  final ws = RegExp(r'\s+');
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('LUT_3D_SIZE')) {
      size = int.parse(line.split(ws)[1]);
      continue;
    }
    final first = line.codeUnitAt(0);
    final isData = (first >= 0x30 && first <= 0x39) ||
        first == 0x2b ||
        first == 0x2d ||
        first == 0x2e; // 0-9 + - .
    if (!isData) continue; // TITLE / DOMAIN_* / LUT_1D_* / etc.
    final parts = line.split(ws);
    if (parts.length < 3) continue;
    final r = double.tryParse(parts[0]);
    final g = double.tryParse(parts[1]);
    final b = double.tryParse(parts[2]);
    if (r == null || g == null || b == null) continue;
    values
      ..add(r)
      ..add(g)
      ..add(b);
  }
  if (size == null) {
    throw const FormatException('cube LUT missing LUT_3D_SIZE');
  }
  final expected = size * size * size * 3;
  if (values.length != expected) {
    throw FormatException(
      'cube LUT expected $expected values, got ${values.length}',
    );
  }
  return CubeLut(size: size, rgb: Float32List.fromList(values));
}
