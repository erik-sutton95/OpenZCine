import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/lut/cube_lut.dart';

const _cube2 = '''
# a tiny 2x2x2 test cube
TITLE "test"
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
LUT_3D_SIZE 2
0.0 0.0 0.0
1.0 0.0 0.0
0.0 0.5 0.0
1.0 0.5 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 0.5 1.0
1.0 0.5 1.0
''';

void main() {
  test('parseCubeLut reads size and red-fastest triplets', () {
    final lut = parseCubeLut(_cube2);
    expect(lut.size, 2);
    expect(lut.rgb.length, 2 * 2 * 2 * 3);
    // index 0 = (r=0,g=0,b=0)
    expect(lut.rgb.sublist(0, 3), [0.0, 0.0, 0.0]);
    // index 1 = (r=1,g=0,b=0) -> red changes fastest
    expect(lut.rgb.sublist(3, 6), [1.0, 0.0, 0.0]);
    // index 4 = (r=0,g=0,b=1)
    expect(lut.rgb.sublist(12, 15), [0.0, 0.0, 1.0]);
  });

  test('parseCubeLut throws when LUT_3D_SIZE is missing', () {
    expect(() => parseCubeLut('0 0 0\n1 1 1\n'), throwsFormatException);
  });

  test('parseCubeLut throws when the triplet count is wrong', () {
    const bad = 'LUT_3D_SIZE 2\n0 0 0\n1 0 0\n';
    expect(() => parseCubeLut(bad), throwsFormatException);
  });
}
