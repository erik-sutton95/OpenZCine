import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/ptp_constants.dart';

void main() {
  test('InitFailReason.fromCode maps known + unknown codes', () {
    expect(InitFailReason.fromCode(1), InitFailReason.rejectedInitiator);
    expect(InitFailReason.fromCode(2), InitFailReason.busy);
    expect(InitFailReason.fromCode(3), InitFailReason.unspecified);
    expect(InitFailReason.fromCode(99), InitFailReason.unknown);
  });

  test('default GUID is exactly 16 bytes', () {
    expect(zcineControllerGuid().length, 16);
  });

  test('protocol version is 0x00010000', () {
    expect(ptpIpProtocolVersion, 0x00010000);
  });
}
