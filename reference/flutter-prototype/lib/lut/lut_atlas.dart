import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'cube_lut.dart';

/// Packs a 3D LUT into RGBA8888 bytes for a 2D atlas the shader samples: a
/// `(size·size) × size` image of `size` horizontally-tiled blue slices, where
/// within each tile x = red and y = green. Pixel (b·size + r, g) = LUT[r,g,b].
Uint8List packLutAtlasRgba(CubeLut lut) {
  final n = lut.size;
  final width = n * n;
  final out = Uint8List(width * n * 4);
  for (var b = 0; b < n; b++) {
    for (var g = 0; g < n; g++) {
      for (var r = 0; r < n; r++) {
        final dst = (g * width + (b * n + r)) * 4;
        final src = (r + g * n + b * n * n) * 3;
        out[dst] = _toByte(lut.rgb[src]);
        out[dst + 1] = _toByte(lut.rgb[src + 1]);
        out[dst + 2] = _toByte(lut.rgb[src + 2]);
        out[dst + 3] = 255;
      }
    }
  }
  return out;
}

int _toByte(double v) => (v * 255.0).round().clamp(0, 255);

/// Decodes the packed atlas into a [ui.Image] ready to bind as a shader sampler.
Future<ui.Image> decodeLutAtlas(CubeLut lut) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    packLutAtlasRgba(lut),
    lut.size * lut.size,
    lut.size,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
