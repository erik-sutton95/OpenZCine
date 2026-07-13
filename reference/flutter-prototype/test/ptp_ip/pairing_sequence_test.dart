import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/ptp_constants.dart';
import 'package:zcinecontroller/ptp_ip/ptp_ip_client.dart';
import 'package:zcinecontroller/ptp_ip/ptp_operation.dart';

/// These lock the ZR's Wi-Fi pairing wire format. Any drift breaks a test.
void main() {
  test('DataPhase.dataIn is 3', () {
    expect(DataPhase.dataIn, 3);
  });

  test('pair-query (0x952B) request matches the expected bytes', () {
    final payload = buildOperationRequestPayload(
      code: PtpOp.getPairingInfo,
      transactionId: 2,
      dataPhase: DataPhase.dataIn,
    );
    expect(payload, [
      0x03, 0x00, 0x00, 0x00, // DataPhaseInfo = 3 (data-in)
      0x2b, 0x95, //             code 0x952B
      0x02, 0x00, 0x00, 0x00, // TransactionID 2
    ]);
  });

  test('pair-confirm (0x935A, param 0x2001) request matches the expected bytes',
      () {
    final payload = buildOperationRequestPayload(
      code: PtpOp.confirmPairing,
      transactionId: 3,
      params: const [pairingConfirmValue],
    );
    expect(payload, [
      0x01, 0x00, 0x00, 0x00, // DataPhaseInfo = 1 (no data)
      0x5a, 0x93, //             code 0x935A
      0x03, 0x00, 0x00, 0x00, // TransactionID 3
      0x01, 0x20, 0x00, 0x00, // Param1 = 0x2001
    ]);
  });

  test('the pairing friendly name encodes to the expected UTF-16LE bytes', () {
    expect(encodeFriendlyName('WTU-iPhone'), [
      0x57, 0x00, 0x54, 0x00, 0x55, 0x00, 0x2d, 0x00, // W T U -
      0x69, 0x00, 0x50, 0x00, 0x68, 0x00, 0x6f, 0x00, // i P h o
      0x6e, 0x00, 0x65, 0x00, 0x00, 0x00, //             n e + NUL
    ]);
  });
}
