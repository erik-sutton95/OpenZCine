import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/camera_props.dart';

void main() {
  test('decodeBaseIso maps 1/2 to Low/High', () {
    expect(decodeBaseIso(1), 'Low');
    expect(decodeBaseIso(2), 'High');
  });
  test('encodeUint8 emits one byte', () {
    expect(encodeUint8(2), [2]);
  });
  test('decodeLens composes focal range + widest aperture', () {
    expect(decodeLens(2400, 7000, 280), '24-70mm f/2.8');
    expect(decodeLens(5000, 5000, 180), '50mm f/1.8');
    expect(decodeLens(null, null, null), isNull);
    expect(decodeLens(0, 0, 0), isNull);
  });
  test('decodeFnumber: 280 -> f/2.8', () {
    expect(decodeFnumber(280), 'f/2.8');
  });
  test('decodeShutterSpeed: 1/60, 1/250, 25s', () {
    expect(decodeShutterSpeed(0x0001003C), '1/60');
    expect(decodeShutterSpeed(0x000100FA), '1/250');
    expect(decodeShutterSpeed(0x00190001), '25s');
  });
  test('decodeShutterAngle: 18000 -> 180°', () {
    expect(decodeShutterAngle(18000), '180°');
    expect(decodeShutterAngle(17280), '172.8°');
  });
  test('decodeFocalLengthMm: 5000 -> 50 mm', () {
    expect(decodeFocalLengthMm(5000), '50 mm');
  });

  test('decodeScreenSize: 0x0F000870001E0000 -> 3840x2160 + 30 fps', () {
    final m = decodeScreenSize(0x0F000870001E0000);
    expect(m.width, 3840);
    expect(m.height, 2160);
    expect(m.fps, 30);
    expect(m.label, '3840×2160');
  });
  test('decodeFileType: 0x00010800 -> H.265 8-bit MOV', () {
    expect(decodeFileType(0x00010800), 'H.265 8-bit MOV');
    expect(decodeFileType(0x00100A00), 'ProRes 422 HQ 10-bit MOV');
  });
  test('decodeWbMode maps known modes, falls back to hex', () {
    expect(decodeWbMode(0x0002), 'Auto');
    expect(decodeWbMode(0x8012), 'Color temp');
    expect(decodeWbMode(0x1234), '0x1234');
  });

  test('CameraState.copyWith replaces one field, keeps the rest', () {
    const a = CameraState(iso: 800, fnumber: 'f/2.8');
    final b = a.copyWith(fnumber: 'f/4');
    expect(b.iso, 800);
    expect(b.fnumber, 'f/4');
  });

  test('encodeUint16/encodeUint32 little-endian', () {
    expect(encodeUint16(280), [0x18, 0x01]);
    expect(encodeUint32(5000), [0x88, 0x13, 0x00, 0x00]);
  });
  test('encodeFnumber: 2.8 -> 280 LE', () {
    expect(encodeFnumber(2.8), [0x18, 0x01]);
  });

  test('parseDevicePropDescEnum reads a trailing UINT16 enum array', () {
    final b = BytesBuilder()
      ..add([0, 0, 0, 0]) // opaque header stand-in
      ..add([0x02]) // form flag = enum
      ..add([0x03, 0x00]) // count = 3
      ..add([0x01, 0x00, 0x02, 0x00, 0x03, 0x00]);
    expect(parseDevicePropDescEnum(b.toBytes(), valueBytes: 2), [1, 2, 3]);
  });
  test('parseDevicePropDescEnum returns empty when count/size mismatch', () {
    expect(
      parseDevicePropDescEnum(
        Uint8List.fromList([0x02, 0x05, 0x00]),
        valueBytes: 2,
      ),
      isEmpty,
    );
  });
}
