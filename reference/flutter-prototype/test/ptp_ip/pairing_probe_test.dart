import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/pairing_probe.dart';

void main() {
  test('parseVendorCodeArray reads count-prefixed UINT32 codes', () {
    final data = Uint8List.fromList(<int>[
      0x03, 0x00, 0x00, 0x00, // count = 3
      0x01, 0x92, 0x00, 0x00, // 0x9201
      0x55, 0x94, 0x00, 0x00, // 0x9455
      0x5a, 0x94, 0x00, 0x00, // 0x945A
    ]);
    expect(parseVendorCodeArray(data), [0x9201, 0x9455, 0x945a]);
  });

  test('parseVendorCodeArray returns the partial list when truncated', () {
    final data = Uint8List.fromList(<int>[
      0x03, 0x00, 0x00, 0x00, // count claims 3
      0x01, 0x92, 0x00, 0x00, // but only 0x9201 is present
    ]);
    expect(parseVendorCodeArray(data), [0x9201]);
  });

  test('parseVendorCodeArray throws when there is no count word', () {
    expect(
      () => parseVendorCodeArray(Uint8List.fromList(<int>[0x00, 0x01])),
      throwsFormatException,
    );
  });

  test('describeVendorCodes summarizes count and flags undocumented ops', () {
    final data = Uint8List.fromList(<int>[
      0x03,
      0x00,
      0x00,
      0x00,
      0x01,
      0x92,
      0x00,
      0x00,
      0x55,
      0x94,
      0x00,
      0x00,
      0x5a,
      0x94,
      0x00,
      0x00,
    ]);
    final summary = describeVendorCodes(data);
    expect(summary, contains('count=3'));
    expect(summary, contains('0x9455'));
    expect(summary, contains('undoc'));
  });

  test('describeLiveViewFrame confirms a real JPEG frame', () {
    final frame = Uint8List(1030);
    frame[0] = 0x02; // version major (LE 0x0002)
    frame[2] = 0x01; // version minor (LE 0x0001)
    frame[1024] = 0xff; // JPEG SOI
    frame[1025] = 0xd8;
    frame[1026] = 0xff;
    final summary = describeLiveViewFrame(frame);
    expect(summary, contains('LIVE VIEW WORKS'));
  });

  test('describeLiveViewFrame reports a missing JPEG SOI', () {
    final frame = Uint8List(1030); // all zero -> no SOI at offset 1024
    expect(describeLiveViewFrame(frame), contains('NO JPEG SOI'));
  });

  test('describeLiveViewFrame reports no data', () {
    expect(describeLiveViewFrame(Uint8List(0)), contains('no data'));
  });

  test('hexPreview caps output and always reports the byte count', () {
    final bytes = Uint8List.fromList(<int>[0xab, 0xcd, 0xef]);
    expect(hexPreview(bytes, max: 2), 'ab cd ... (3 bytes)');
    expect(
      hexPreview(Uint8List.fromList(<int>[0x01, 0x02])),
      '01 02 (2 bytes)',
    );
  });

  test('formatResponseCode names known codes and hexes the rest', () {
    expect(formatResponseCode(0x2001), 'OK(0x2001)');
    expect(formatResponseCode(0x2019), 'Device_Busy(0x2019)');
    expect(formatResponseCode(0xa00b), '0xa00b');
    expect(formatResponseCode(null), '(none)');
  });

  test('ProbeStep.withNote copies the step with a note attached', () {
    final step = ProbeStep(label: 'A', responseCode: 0x2001);
    final noted = step.withNote('hello');
    expect(noted.note, 'hello');
    expect(noted.label, 'A');
    expect(noted.responseCode, 0x2001);
  });

  test('formatProbeReport renders steps, notes, hex, and errors', () {
    final report = formatProbeReport(<ProbeStep>[
      ProbeStep(
        label: 'GetVendorCodes ops',
        responseCode: 0x2001,
        data: Uint8List.fromList(<int>[0x01, 0x02]),
        note: 'count=0',
      ),
      ProbeStep(label: 'GetCommandFeature(0x9455)', error: 'boom'),
    ]);
    expect(report, contains('1. GetVendorCodes ops'));
    expect(report, contains('resp=OK(0x2001)'));
    expect(report, contains('data=2B'));
    expect(report, contains('note: count=0'));
    expect(report, contains('hex: 01 02 (2 bytes)'));
    expect(report, contains('2. GetCommandFeature(0x9455)'));
    expect(report, contains('ERROR: boom'));
  });
}
