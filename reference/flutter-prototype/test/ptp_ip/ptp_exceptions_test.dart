import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/ptp_constants.dart';
import 'package:zcinecontroller/ptp_ip/ptp_exceptions.dart';

void main() {
  test('InitFailException keeps reason + raw code and explains reason 1', () {
    final e = InitFailException(InitFailReason.rejectedInitiator, 1);
    expect(e.reason, InitFailReason.rejectedInitiator);
    expect(e.rawCode, 1);
    expect(e.toString(), contains('Connect to PC'));
  });

  test('PtpResponseException formats op + response codes as hex', () {
    final e = PtpResponseException(PtpOp.openSession, 0x2019);
    expect(e.toString(), contains('1002'));
    expect(e.toString(), contains('2019'));
  });
}
