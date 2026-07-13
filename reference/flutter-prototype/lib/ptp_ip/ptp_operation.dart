import 'dart:typed_data';

/// PTP-IP `Operation_Request` DataPhaseInfo values (libgphoto2 `ptpip.c`).
class DataPhase {
  DataPhase._();

  /// No data phase, or a data-IN (camera -> host) operation.
  static const int noDataOrDataIn = 1;

  /// A data-OUT (host -> camera) operation.
  static const int dataOut = 2;

  /// A data-IN (camera -> host) operation. The canonical value the camera's own
  /// clients use for data-in ops (3); value 1 is also accepted by the ZR for
  /// data-in.
  static const int dataIn = 3;
}

/// Builds the `Operation_Request` *payload* (the bytes after the 8-byte PTP-IP
/// header): `DataPhaseInfo(4) + Code(2) + TransactionID(4) + Params(4 each)`,
/// all little-endian. Wrap the result in a `PtpIpPacket(PtpIpType.operationRequest, ...)`.
Uint8List buildOperationRequestPayload({
  required int code,
  required int transactionId,
  List<int> params = const [],
  int dataPhase = DataPhase.noDataOrDataIn,
}) {
  final bytes = Uint8List(10 + params.length * 4);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, dataPhase, Endian.little);
  bd.setUint16(4, code, Endian.little);
  bd.setUint32(6, transactionId, Endian.little);
  for (var i = 0; i < params.length; i++) {
    bd.setUint32(10 + i * 4, params[i], Endian.little);
  }
  return bytes;
}

/// A parsed PTP-IP `Operation_Response` payload:
/// `ResponseCode(2) + TransactionID(4) + Params(4 each)`.
class OperationResponse {
  const OperationResponse(this.code, this.transactionId, this.params);

  /// PTP response code (e.g. 0x2001 = OK).
  final int code;

  /// Transaction ID echoed by the camera.
  final int transactionId;

  /// Zero or more response parameters.
  final List<int> params;

  /// Parses an `Operation_Response` payload (header already stripped).
  static OperationResponse parse(Uint8List payload) {
    if (payload.length < 6) {
      throw FormatException(
        'Operation_Response payload too short: ${payload.length} bytes',
      );
    }
    final bd = ByteData.sublistView(payload);
    final code = bd.getUint16(0, Endian.little);
    final tid = bd.getUint32(2, Endian.little);
    final params = <int>[];
    for (var offset = 6; offset + 4 <= payload.length; offset += 4) {
      params.add(bd.getUint32(offset, Endian.little));
    }
    return OperationResponse(code, tid, params);
  }
}

/// Builds a `Start_Data` packet payload: `TransactionID(4) + TotalLength(8)`,
/// little-endian. Wrap in `PtpIpPacket(PtpIpType.startData, ...)`.
Uint8List buildStartDataPayload(int transactionId, int totalLength) {
  final bytes = Uint8List(12);
  ByteData.sublistView(bytes)
    ..setUint32(0, transactionId, Endian.little)
    ..setUint64(4, totalLength, Endian.little);
  return bytes;
}

/// Builds an `End_Data` packet payload: `TransactionID(4) + data`, little-endian
/// TID. Wrap in `PtpIpPacket(PtpIpType.endData, ...)`.
Uint8List buildEndDataPayload(int transactionId, Uint8List data) {
  final out = Uint8List(4 + data.length);
  ByteData.sublistView(out).setUint32(0, transactionId, Endian.little);
  out.setRange(4, 4 + data.length, data);
  return out;
}
