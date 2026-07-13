import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'device_info.dart';
import 'live_view.dart';
import 'pairing_challenge.dart';
import 'pairing_probe.dart';
import 'ptp_constants.dart';
import 'ptp_exceptions.dart';
import 'ptp_ip_packet.dart';
import 'ptp_operation.dart';
import 'socket_reader.dart';

/// Encodes [name] as raw UTF-16LE with a trailing double-NUL — the PTP-IP
/// friendly-name encoding (NOT a PTP length-prefixed string).
Uint8List encodeFriendlyName(String name) {
  final units = name.codeUnits;
  final out =
      Uint8List((units.length + 1) * 2); // +1 char for the NUL terminator
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < units.length; i++) {
    bd.setUint16(i * 2, units[i], Endian.little);
  }
  return out; // trailing 2 bytes are already 0 = UTF-16 NUL
}

/// Builds the `Init_Command_Request` payload: GUID(16) + friendly name +
/// ProtocolVersion(4). Version is UINT32 `0x00010000` -> wire bytes `00 00 01 00`.
Uint8List buildInitCommandPayload(Uint8List guid, String friendlyName) {
  if (guid.length != 16) {
    throw ArgumentError.value(
      guid.length,
      'guid.length',
      'GUID must be 16 bytes',
    );
  }
  final version = Uint8List(4);
  ByteData.sublistView(version)
      .setUint32(0, ptpIpProtocolVersion, Endian.little);
  return (BytesBuilder()
        ..add(guid)
        ..add(encodeFriendlyName(friendlyName))
        ..add(version))
      .toBytes();
}

/// Called when the camera returns a pairing challenge. Return true to send the
/// confirm operation, false to reject and close the session.
typedef PairingChallengeHandler = Future<bool> Function(
  PairingChallenge challenge,
);

/// Connects to a camera over PTP-IP, performs the handshake, opens a session,
/// and reads the camera identity. One attempt per call; throws on any failure
/// and always closes its sockets.
class PtpIpClient {
  PtpIpClient({
    required this.host,
    required this.guid,
    this.port = ptpIpPort,
    this.friendlyName = 'WTU-iPhone',
    this.timeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;
  final Uint8List guid;
  final String friendlyName;
  final Duration timeout;

  Socket? _command;
  Socket? _event;
  SocketReader? _commandReader;
  SocketReader? _eventReader;
  int _connectionNumber = 0;
  int _nextTransactionId = 1;
  String? _cameraName;

  /// Diagnostic summary of the best-effort control-establishment ops run after
  /// GetDeviceInfo (e.g. "vendorOps=0x2001 appMode=0x2001"). Populated by [pairAndIdentify].
  String establishmentSummary = '';

  /// Pairs and returns the camera identity. Closes everything on failure.
  Future<DeviceInfo> pairAndIdentify({
    PairingChallengeHandler? onPairingChallenge,
    bool requestPairing = true,
  }) async {
    try {
      _command = await Socket.connect(host, port, timeout: timeout);
      _command!.setOption(SocketOption.tcpNoDelay, true);
      _guardSocketWrites(_command!);
      _commandReader = SocketReader(_command!);
      await _initCommand();

      _event = await Socket.connect(host, port, timeout: timeout);
      _event!.setOption(SocketOption.tcpNoDelay, true);
      _guardSocketWrites(_event!);
      _eventReader = SocketReader(_event!);
      await _initEvent();

      await _openSession();
      if (requestPairing) {
        await _completePairing(onPairingChallenge: onPairingChallenge);
      } else {
        establishmentSummary += 'pairing=skipped ';
      }
      await _enableCameraControl();
      final info = await _getDeviceInfo();
      return info;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// Starts remote live view and waits until the camera is ready: StartLiveView,
  /// then poll DeviceReady out of Device_Busy. Throws if StartLiveView is
  /// rejected. Requires a paired/unlocked session.
  Future<void> startLiveView() async {
    final (start, _) = await _transact(
      code: PtpOp.startLiveView,
      transactionId: _nextTransactionId++,
    );
    if (start.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.startLiveView, start.code);
    }
    for (var i = 0; i < 40; i++) {
      final (ready, _) = await _transact(
        code: PtpOp.deviceReady,
        transactionId: _nextTransactionId++,
      );
      if (ready.code != PtpResponse.deviceBusy) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Pulls the newest live-view frame: its JPEG plus header-derived timecode.
  Future<LiveViewFrame> liveViewFrame() async {
    final (resp, data) = await _transact(
      code: PtpOp.getLiveViewImageEx,
      transactionId: _nextTransactionId++,
      dataPhase: DataPhase.dataIn,
    );
    if (resp.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.getLiveViewImageEx, resp.code);
    }
    return LiveViewFrame(
      jpeg: extractLiveViewJpeg(data),
      timecode: parseTimecode(data),
    );
  }

  /// Pulls the newest live-view frame and returns just its JPEG.
  Future<Uint8List> liveViewFrameJpeg() async => (await liveViewFrame()).jpeg;

  /// Ends remote live view (best-effort; ignores errors).
  Future<void> stopLiveView() async {
    try {
      await _transact(
        code: PtpOp.endLiveView,
        transactionId: _nextTransactionId++,
      );
    } on Object catch (_) {
      // best-effort teardown
    }
  }

  /// Best-effort camera-side live-view tuning: writes LiveViewImageSize (1=QVGA,
  /// 2=VGA, 3=XGA) and LiveViewImageCompression (0..5). May be read-only in
  /// "Connect to PC" mode — records each result in [establishmentSummary] and
  /// never throws, so the stream proceeds at the camera default if rejected.
  Future<void> configureLiveView({int size = 2, int compression = 2}) async {
    Future<void> setU8(String label, int prop, int value) async {
      try {
        final (resp, _) = await _transact(
          code: PtpOp.setDevicePropValueEx,
          transactionId: _nextTransactionId++,
          params: [prop],
          dataPhase: DataPhase.dataOut,
          dataOut: Uint8List.fromList([value]),
        );
        establishmentSummary += '$label=0x${resp.code.toRadixString(16)} ';
      } on Object catch (_) {
        establishmentSummary += '$label=err ';
      }
    }

    await setU8('lvSize', PtpProp.liveViewImageSize, size);
    await setU8('lvComp', PtpProp.liveViewImageCompression, compression);
  }

  /// Reads the camera's movie frame rate from `MovieRecordScreenSize` (0xD0A0),
  /// bits 16-23 (e.g. 24/25/30/50/60). Returns 0 if unreadable.
  Future<int> readMovieFrameRate() async {
    final (resp, data) = await _transact(
      code: PtpOp.getDevicePropValueEx,
      transactionId: _nextTransactionId++,
      params: const [PtpProp.movieRecordScreenSize],
      dataPhase: DataPhase.dataIn,
    );
    if (resp.code != PtpResponse.ok || data.length < 8) return 0;
    final raw = ByteData.sublistView(data).getUint64(0, Endian.little);
    return (raw >> 16) & 0xff;
  }

  /// Reads a vendor device property's raw value bytes (New-API 0x943B).
  Future<Uint8List> getProperty(int code) async {
    final (resp, data) = await _transact(
      code: PtpOp.getDevicePropValueEx,
      transactionId: _nextTransactionId++,
      params: [code],
      dataPhase: DataPhase.dataIn,
    );
    if (resp.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.getDevicePropValueEx, resp.code);
    }
    return data;
  }

  /// Writes a vendor device property's raw value bytes (New-API 0x943C).
  /// Throws [PtpResponseException] if the camera rejects it (e.g. wrong mode).
  Future<void> setProperty(int code, Uint8List value) async {
    final (resp, _) = await _transact(
      code: PtpOp.setDevicePropValueEx,
      transactionId: _nextTransactionId++,
      params: [code],
      dataPhase: DataPhase.dataOut,
      dataOut: value,
    );
    if (resp.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.setDevicePropValueEx, resp.code);
    }
  }

  /// Reads a property's raw DevicePropDesc blob (New-API 0x943A) — current value,
  /// supported-value form, etc. Callers parse it (see parseDevicePropDescEnum).
  Future<Uint8List> describeProperty(int code) async {
    final (resp, data) = await _transact(
      code: PtpOp.getDevicePropDescEx,
      transactionId: _nextTransactionId++,
      params: [code],
      dataPhase: DataPhase.dataIn,
    );
    if (resp.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.getDevicePropDescEx, resp.code);
    }
    return data;
  }

  Future<void> _initCommand() async {
    _send(
      _command!,
      PtpIpPacket(
        PtpIpType.initCommandRequest,
        buildInitCommandPayload(guid, friendlyName),
      ),
    );
    final reply = await _readPacket(_commandReader!);
    if (reply.type == PtpIpType.initFail) {
      if (reply.payload.length < 4) {
        throw PtpIpException('Init_Fail packet too short');
      }
      final code =
          ByteData.sublistView(reply.payload).getUint32(0, Endian.little);
      throw InitFailException(
        InitFailReason.fromCode(code),
        code,
      );
    }
    if (reply.type != PtpIpType.initCommandAck) {
      throw PtpIpException(
        'Expected Init_Command_Ack, got packet type ${reply.type}',
      );
    }
    if (reply.payload.length < 4) {
      throw PtpIpException('Init_Command_Ack payload too short');
    }
    _connectionNumber =
        ByteData.sublistView(reply.payload).getUint32(0, Endian.little);
    _cameraName = _parseInitAckName(reply.payload);
  }

  Future<void> _initEvent() async {
    final payload = Uint8List(4);
    ByteData.sublistView(payload)
        .setUint32(0, _connectionNumber, Endian.little);
    _send(_event!, PtpIpPacket(PtpIpType.initEventRequest, payload));
    final reply = await _readPacket(_eventReader!);
    if (reply.type != PtpIpType.initEventAck) {
      throw PtpIpException(
        'Expected Init_Event_Ack, got packet type ${reply.type}',
      );
    }
  }

  Future<void> _openSession() async {
    final (response, _) = await _transact(
      code: PtpOp.openSession,
      transactionId: 0,
      params: const [1],
    );
    if (response.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.openSession, response.code);
    }
    _nextTransactionId = 1;
  }

  Future<DeviceInfo> _getDeviceInfo() async {
    final (response, data) = await _transact(
      code: PtpOp.getDeviceInfo,
      transactionId: _nextTransactionId++,
      dataPhase: DataPhase.dataIn,
    );
    if (response.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.getDeviceInfo, response.code);
    }
    return DeviceInfo.parse(data);
  }

  /// Completes the ZR's Wi-Fi pairing handshake: a data-in query (0x952B), then
  /// the pairing-confirm op (0x935A with [pairingConfirmValue]). On success the
  /// camera fires DeviceInfoChanged and shows "Pairing Complete". Records each
  /// response in [establishmentSummary]; never throws so identity can still read.
  Future<void> _completePairing({
    PairingChallengeHandler? onPairingChallenge,
  }) async {
    PairingChallenge? challenge;
    try {
      final (response, data) = await _transact(
        code: PtpOp.getPairingInfo,
        transactionId: _nextTransactionId++,
        dataPhase: DataPhase.dataIn,
      );
      establishmentSummary += 'pairInfo=0x${response.code.toRadixString(16)} ';
      if (response.code == PtpResponse.ok && data.isNotEmpty) {
        challenge = PairingChallenge.parse(data, cameraName: _cameraName);
        establishmentSummary += 'pairData=${challenge.rawHex} ';
      }
    } on Object catch (_) {
      establishmentSummary += 'pairInfo=err ';
    }

    if (challenge != null && onPairingChallenge != null) {
      final accepted = await onPairingChallenge(challenge);
      if (!accepted) throw PtpIpException('Pairing rejected by user.');
    }

    try {
      final (response, _) = await _transact(
        code: PtpOp.confirmPairing,
        transactionId: _nextTransactionId++,
        params: const [pairingConfirmValue],
      );
      establishmentSummary +=
          'pairConfirm=0x${response.code.toRadixString(16)} ';
    } on Object catch (_) {
      establishmentSummary += 'pairConfirm=err ';
    }
  }

  /// Enables application mode (0x9435 P1=1) — the camera requires it to permit
  /// video recording (MovieRecProhibitionCondition bit14 = "Not in application
  /// mode"). Reads 0xD0A4 afterward to confirm (0 = recording allowed). Records
  /// both in [establishmentSummary]; best-effort, never throws.
  Future<void> _enableCameraControl() async {
    try {
      final (resp, _) = await _transact(
        code: PtpOp.changeApplicationMode,
        transactionId: _nextTransactionId++,
        params: const [1],
      );
      establishmentSummary += 'appMode=0x${resp.code.toRadixString(16)} ';
    } on Object catch (_) {
      establishmentSummary += 'appMode=err ';
    }
    try {
      final (_, data) = await _transact(
        code: PtpOp.getDevicePropValueEx,
        transactionId: _nextTransactionId++,
        params: const [PtpProp.movieRecProhibitionCondition],
        dataPhase: DataPhase.dataIn,
      );
      final value = data.length >= 4
          ? ByteData.sublistView(data).getUint32(0, Endian.little)
          : -1;
      establishmentSummary += 'recProhib=0x${value.toRadixString(16)} ';
    } on Object catch (_) {
      establishmentSummary += 'recProhib=err ';
    }
  }

  /// Read-only diagnostic probe of the camera's pairing/control surface, run
  /// against the already-open session. It asks the camera to *describe* itself —
  /// the vendor op/property lists it exposes right now, and the feature info for
  /// each available op (via GetCommandFeature). Every step is captured even on
  /// error. Non-destructive by default; pass [probeLiveView] to also run the
  /// live-view gate test (the ZR answers it by dropping the connection, so it
  /// runs last and ends the session). Render with [formatProbeReport].
  Future<List<ProbeStep>> probePairingSurface({
    bool probeLiveView = false,
  }) async {
    final steps = <ProbeStep>[
      await _probeCodes('GetVendorCodes ops (0x9439 P1=0x09)', const [0x09]),
      await _probeCodes('GetVendorCodes props (0x9439 P1=0x0D)', const [0x0d]),
    ];

    // Describe the ops the camera ACTUALLY exposes in this state via
    // GetCommandFeature. These are *describe* calls — they reveal each op's data
    // direction + payload shape without invoking it. The two undocumented ops
    // (0x935A, 0x952B) are the leading pairing-handshake suspects.
    steps.add(
      await _probeOne(
        'GetCommandFeature no-param (0x944C)',
        PtpOp.getCommandFeature,
        const [],
      ),
    );
    for (final op in const [0x935a, 0x9439, 0x9440, 0x9441, 0x9442, 0x952b]) {
      steps.add(
        await _probeOne(
          'GetCommandFeature(0x${op.toRadixString(16)}) (0x944C)',
          PtpOp.getCommandFeature,
          [op],
        ),
      );
    }

    steps.add(
      await _probeOne(
        'GetEventEx keep (0x941C P1=1)',
        PtpOp.getEventEx,
        const [1],
      ),
    );
    if (probeLiveView) steps.addAll(await _probeLiveViewGate());
    return steps;
  }

  /// CAREFULLY invokes the two undocumented pairing-suspect ops (0x935A, 0x952B)
  /// directly — no params, DataPhaseInfo = no-data/data-in (we never claim to
  /// send data) — capturing the response code and any data-in. After each it
  /// drains events (an invoke may push a pairing/auth event). Stops early if an
  /// invoke drops or hangs the connection. The operator should WATCH THE CAMERA
  /// SCREEN: success looks like the wizard advancing to an authentication code.
  Future<List<ProbeStep>> probeInvoke() async {
    final steps = <ProbeStep>[];
    for (final op in const [0x935a, 0x952b]) {
      final hex = op.toRadixString(16);
      final step = await _probeOne('INVOKE 0x$hex (no params)', op, const []);
      if (step.error != null) {
        steps
          ..add(step)
          ..add(
            ProbeStep(
              label: 'STOP',
              note: 'invoke of 0x$hex failed/closed the socket — '
                  'skipping the rest; reconnect to retry',
            ),
          );
        return steps;
      }
      final note = step.data.isNotEmpty
          ? 'returned ${step.data.length} bytes of data-in'
          : 'no data-in; response only';
      steps
        ..add(step.withNote(note))
        ..add(
          await _probeOne(
            'GetEventEx after 0x$hex (0x941C P1=1)',
            PtpOp.getEventEx,
            const [1],
          ),
        );
    }
    return steps;
  }

  /// Runs one probe transaction, capturing the response code and data — or the
  /// exception text if it throws. Never rethrows.
  Future<ProbeStep> _probeOne(String label, int code, List<int> params) async {
    try {
      final (response, data) = await _transact(
        code: code,
        transactionId: _nextTransactionId++,
        params: params,
      ).timeout(timeout);
      return ProbeStep(label: label, responseCode: response.code, data: data);
    } on Object catch (e) {
      return ProbeStep(label: label, error: e.toString());
    }
  }

  /// A [GetVendorCodes] probe step with its code-array decoded into a note.
  Future<ProbeStep> _probeCodes(String label, List<int> params) async {
    final step = await _probeOne(label, PtpOp.getVendorCodes, params);
    return step.error == null
        ? step.withNote(describeVendorCodes(step.data))
        : step;
  }

  /// Tests whether live view functions on the current (unpaired) session — the
  /// pairing-gate oracle. Pre-checks LiveViewProhibitionCondition, then (only if
  /// clear) StartLiveView -> DeviceReady poll -> one frame -> EndLiveView.
  Future<List<ProbeStep>> _probeLiveViewGate() async {
    final steps = <ProbeStep>[];

    final prohibition = await _probeOne(
      'GetDevicePropValueEx LiveViewProhibition (0x943B 0xD1A4)',
      PtpOp.getDevicePropValueEx,
      const [PtpProp.liveViewProhibitionCondition],
    );
    final canStart = prohibition.error == null &&
        prohibition.data.length >= 4 &&
        ByteData.sublistView(prohibition.data).getUint32(0, Endian.little) == 0;
    steps.add(
      prohibition.error == null
          ? prohibition.withNote(describeProhibition(prohibition.data))
          : prohibition,
    );

    if (!canStart) {
      steps.add(
        ProbeStep(
          label: 'StartLiveView SKIPPED',
          note: 'prohibition != 0 or unreadable — not starting live view',
        ),
      );
      return steps;
    }

    steps.add(
      await _probeOne('StartLiveView (0x9201)', PtpOp.startLiveView, const []),
    );

    // Readiness poll: re-issue DeviceReady until it stops returning Device_Busy.
    var ready =
        await _probeOne('DeviceReady (0x90C8)', PtpOp.deviceReady, const []);
    var polls = 1;
    while (ready.error == null &&
        ready.responseCode == PtpResponse.deviceBusy &&
        polls < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ready =
          await _probeOne('DeviceReady (0x90C8)', PtpOp.deviceReady, const []);
      polls++;
    }
    steps.add(
      ready.error == null ? ready.withNote('after $polls poll(s)') : ready,
    );

    final frame = await _probeOne(
      'GetLiveViewImageEx (0x9428)',
      PtpOp.getLiveViewImageEx,
      const [],
    );
    steps.add(
      frame.error == null
          ? frame.withNote(describeLiveViewFrame(frame.data))
          : frame,
    );

    steps.add(
      await _probeOne('EndLiveView (0x9202)', PtpOp.endLiveView, const []),
    );
    return steps;
  }

  /// Sends an Operation_Request and drains the command socket until the matching
  /// Operation_Response, assembling any data-phase bytes (TID prefix stripped).
  Future<(OperationResponse, Uint8List)> _transact({
    required int code,
    required int transactionId,
    List<int> params = const [],
    int dataPhase = DataPhase.noDataOrDataIn,
    Uint8List? dataOut,
  }) async {
    _send(
      _command!,
      PtpIpPacket(
        PtpIpType.operationRequest,
        buildOperationRequestPayload(
          code: code,
          transactionId: transactionId,
          params: params,
          dataPhase: dataPhase,
        ),
      ),
    );
    if (dataOut != null) {
      _send(
        _command!,
        PtpIpPacket(
          PtpIpType.startData,
          buildStartDataPayload(transactionId, dataOut.length),
        ),
      );
      _send(
        _command!,
        PtpIpPacket(
          PtpIpType.endData,
          buildEndDataPayload(transactionId, dataOut),
        ),
      );
    }
    final data = BytesBuilder();
    while (true) {
      final pkt = await _readPacket(_commandReader!);
      if (pkt.type == PtpIpType.startData) {
        continue; // payload = TID(4)+TotalLen(4)+unknown(4); not needed
      } else if (pkt.type == PtpIpType.data || pkt.type == PtpIpType.endData) {
        data.add(
          Uint8List.sublistView(pkt.payload, 4), // strip 4-byte TID prefix
        );
      } else if (pkt.type == PtpIpType.operationResponse) {
        return (OperationResponse.parse(pkt.payload), data.takeBytes());
      } else {
        throw PtpIpException(
          'Unexpected packet type ${pkt.type} during operation 0x${code.toRadixString(16)}',
        );
      }
    }
  }

  void _send(Socket socket, PtpIpPacket packet) => socket.add(packet.toBytes());

  /// Routes a socket's asynchronous write-side errors (e.g. the camera dropping
  /// mid-send: "host is down") to a no-op so they cannot escalate to a fatal
  /// unhandled exception. The drop is still detected and surfaced on the read
  /// side (read timeout / closed-stream error), which drives teardown.
  void _guardSocketWrites(Socket socket) {
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
  }

  Future<PtpIpPacket> _readPacket(SocketReader reader) async {
    final header = await reader.readExact(8);
    final bd = ByteData.sublistView(header);
    final length = bd.getUint32(0, Endian.little);
    final type = bd.getUint32(4, Endian.little);
    final payload =
        length > 8 ? await reader.readExact(length - 8) : Uint8List(0);
    return PtpIpPacket(type, payload);
  }

  String? _parseInitAckName(Uint8List payload) {
    const nameOffset = 20; // ConnectionNumber(4) + GUID(16)
    if (payload.length < nameOffset + 2) return null;
    final out = StringBuffer();
    for (var i = nameOffset; i + 1 < payload.length; i += 2) {
      final unit = payload[i] | (payload[i + 1] << 8);
      if (unit == 0) break;
      out.writeCharCode(unit);
    }
    final name = out.toString();
    return name.isEmpty ? null : name;
  }

  /// Closes both channels. Safe to call more than once.
  Future<void> close() async {
    await _commandReader?.close();
    await _eventReader?.close();
    await _command?.close();
    await _event?.close();
    _command = null;
    _event = null;
    _commandReader = null;
    _eventReader = null;
  }
}
