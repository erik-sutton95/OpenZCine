import 'ptp_constants.dart';

/// Base type for all PTP-IP client failures.
class PtpIpException implements Exception {
  PtpIpException(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => message;
}

/// Thrown when the camera answers the handshake with an `Init_Fail` packet.
class InitFailException extends PtpIpException {
  InitFailException(this.reason, this.rawCode)
      : super(_message(reason, rawCode));

  /// Decoded reason.
  final InitFailReason reason;

  /// Raw on-wire reason value.
  final int rawCode;

  static String _message(InitFailReason reason, int rawCode) =>
      switch (reason) {
        InitFailReason.rejectedInitiator =>
          'Camera rejected this initiator (Init_Fail reason 1). Put the camera in '
              '"Connect to PC / Camera Control" with an active profile, make sure no '
              'other app is connected, then retry.',
        InitFailReason.busy =>
          'Camera is busy (Init_Fail reason 2) — another connection is active. '
              'Close it and retry.',
        InitFailReason.unspecified =>
          'Camera refused the connection (Init_Fail reason 3, unspecified).',
        InitFailReason.unknown =>
          'Camera refused the connection (Init_Fail reason $rawCode).',
      };
}

/// Thrown when a PTP operation returns a non-OK response code.
class PtpResponseException extends PtpIpException {
  PtpResponseException(this.operationCode, this.responseCode)
      : super('Operation 0x${operationCode.toRadixString(16)} failed: '
            'response 0x${responseCode.toRadixString(16)}');

  /// The PTP operation code that failed.
  final int operationCode;

  /// The non-OK response code returned by the camera.
  final int responseCode;
}
