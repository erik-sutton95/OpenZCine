import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/live_view.dart';

Uint8List _object({required int declaredLength, required List<int> jpeg}) {
  final obj = Uint8List(liveViewHeaderLength + jpeg.length);
  ByteData.sublistView(obj).setUint32(12, declaredLength, Endian.little);
  obj.setRange(liveViewHeaderLength, liveViewHeaderLength + jpeg.length, jpeg);
  return obj;
}

void main() {
  group('parseTimecode', () {
    test('reads HH:MM:SS:FF and on-flag from the header', () {
      final obj = Uint8List(liveViewHeaderLength + 3);
      obj[831] = 1; // on
      obj[832] = 1; // hour
      obj[833] = 23; // min
      obj[834] = 45; // sec
      obj[835] = 12; // frame
      final tc = parseTimecode(obj);
      expect(tc.on, true);
      expect(tc.label, '01:23:45:12');
    });

    test('returns off when the status byte is 0', () {
      final tc = parseTimecode(Uint8List(liveViewHeaderLength + 3));
      expect(tc.on, false);
    });

    test('returns off when the object is too short', () {
      expect(parseTimecode(Uint8List(10)).on, false);
    });
  });

  test('extractLiveViewJpeg returns the JPEG after the 1024-byte header', () {
    final obj = _object(
      declaredLength: 5,
      jpeg: const [0xff, 0xd8, 0xff, 0xd9, 0x11],
    );
    expect(extractLiveViewJpeg(obj), [0xff, 0xd8, 0xff, 0xd9, 0x11]);
  });

  test('extractLiveViewJpeg trims to the declared image length', () {
    final obj = _object(
      declaredLength: 4,
      jpeg: const [0xff, 0xd8, 0xff, 0xd9, 0xaa, 0xbb], // trailing padding
    );
    expect(extractLiveViewJpeg(obj), [0xff, 0xd8, 0xff, 0xd9]);
  });

  test('extractLiveViewJpeg throws when the object is too short', () {
    expect(() => extractLiveViewJpeg(Uint8List(100)), throwsFormatException);
  });

  test('extractLiveViewJpeg throws when there is no JPEG SOI', () {
    final obj = _object(declaredLength: 0, jpeg: const [0x00, 0x00, 0x00]);
    expect(() => extractLiveViewJpeg(obj), throwsFormatException);
  });
}
