import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/ptp_ip_client.dart';

void main() {
  test('friendly name is raw UTF-16LE with a double-NUL terminator', () {
    expect(encodeFriendlyName('ZR'), [0x5A, 0x00, 0x52, 0x00, 0x00, 0x00]);
  });

  test('Init_Command payload = GUID + name + version, with version 00 00 01 00',
      () {
    final guid = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final payload = buildInitCommandPayload(guid, 'ZR');
    expect(payload.sublist(0, 16), guid);
    expect(payload.sublist(16, 22), [0x5A, 0x00, 0x52, 0x00, 0x00, 0x00]);
    // Regression guard for the prior bug: version must be 00 00 01 00, NOT 00 01 00 00.
    expect(payload.sublist(22, 26), [0x00, 0x00, 0x01, 0x00]);
  });

  test('buildInitCommandPayload rejects a non-16-byte GUID', () {
    expect(
      () => buildInitCommandPayload(Uint8List(8), 'x'),
      throwsArgumentError,
    );
  });
}
