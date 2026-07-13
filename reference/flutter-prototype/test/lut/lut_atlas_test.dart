import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/lut/cube_lut.dart';
import 'package:zcinecontroller/lut/lut_atlas.dart';

void main() {
  test('packLutAtlasRgba has (size·size × size) RGBA dimensions', () {
    final lut = CubeLut(size: 2, rgb: Float32List(2 * 2 * 2 * 3));
    final atlas = packLutAtlasRgba(lut);
    expect(atlas.length, (2 * 2) * 2 * 4); // width*height*4
  });

  test('packLutAtlasRgba maps LUT[r,g,b] to pixel (b·size+r, g)', () {
    // Mark entry (r=1, g=0, b=1) red so we can locate it in the atlas.
    final rgb = Float32List(2 * 2 * 2 * 3);
    const index = 1 + 0 * 2 + 1 * 4; // r + g*size + b*size^2
    rgb[index * 3] = 1.0; // R = 1.0
    final atlas = packLutAtlasRgba(CubeLut(size: 2, rgb: rgb));

    const width = 2 * 2;
    const col = 1 * 2 + 1; // b*size + r = 3
    const row = 0; // g
    const dst = (row * width + col) * 4;
    expect(atlas[dst], 255); // R
    expect(atlas[dst + 1], 0); // G
    expect(atlas[dst + 2], 0); // B
    expect(atlas[dst + 3], 255); // A
  });
}
