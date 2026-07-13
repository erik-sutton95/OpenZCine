import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/ptp_constants.dart';
import 'package:zcinecontroller/ptp_ip/ptp_operation.dart';

void main() {
  test('OpenSession request payload: DataPhase(1)+Code(0x1002)+TID(0)+param(1)',
      () {
    final payload = buildOperationRequestPayload(
      code: PtpOp.openSession,
      transactionId: 0,
      params: const [1],
    );
    expect(payload, [
      0x01, 0x00, 0x00, 0x00, // DataPhaseInfo = 1 (no data / data-in)
      0x02, 0x10, //             Code = 0x1002
      0x00, 0x00, 0x00, 0x00, // TransactionID = 0
      0x01, 0x00, 0x00, 0x00, // Param1 = SessionID 1
    ]);
  });

  test('GetDeviceInfo request payload has no params (10 bytes)', () {
    final payload = buildOperationRequestPayload(
      code: PtpOp.getDeviceInfo,
      transactionId: 7,
    );
    expect(payload.length, 10);
    expect(payload.sublist(4, 6), [0x01, 0x10]); // Code 0x1001
  });

  test('OperationResponse.parse reads code, tid, params', () {
    final bytes = Uint8List.fromList([
      0x01, 0x20, //             code 0x2001
      0x05, 0x00, 0x00, 0x00, // tid 5
      0x09, 0x00, 0x00, 0x00, // param 9
    ]);
    final resp = OperationResponse.parse(bytes);
    expect(resp.code, 0x2001);
    expect(resp.transactionId, 5);
    expect(resp.params, [9]);
  });

  test('OperationResponse.parse rejects a too-short payload', () {
    expect(() => OperationResponse.parse(Uint8List(4)), throwsFormatException);
  });

  test('buildStartDataPayload = TID(4 LE) + TotalLength(8 LE)', () {
    expect(buildStartDataPayload(5, 1), [
      0x05, 0x00, 0x00, 0x00, // TransactionID 5
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // TotalLength 1 (UINT64)
    ]);
  });

  test('buildEndDataPayload = TID(4 LE) + data bytes', () {
    expect(buildEndDataPayload(5, Uint8List.fromList(<int>[0x02])), [
      0x05, 0x00, 0x00, 0x00, // TransactionID 5
      0x02, //                   data
    ]);
  });

  test('SetDevicePropValueEx request: dataOut(2)+code(0x943C)+tid+prop param',
      () {
    final payload = buildOperationRequestPayload(
      code: 0x943c,
      transactionId: 7,
      params: const [0xd1ac],
      dataPhase: DataPhase.dataOut,
    );
    expect(payload, [
      0x02, 0x00, 0x00, 0x00, // DataPhaseInfo = 2 (data-out)
      0x3c, 0x94, //             code 0x943C
      0x07, 0x00, 0x00, 0x00, // tid 7
      0xac, 0xd1, 0x00, 0x00, // Param1 = 0xD1AC
    ]);
  });
}
