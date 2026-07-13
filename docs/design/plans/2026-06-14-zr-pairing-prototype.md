# ZR Direct-Connect Pairing Prototype — Implementation Plan

**Goal:** From an iPhone on the Nikon ZR's Wi-Fi AP ("Connect to PC" / Direct mode), complete the PTP-IP handshake, open a PTP session, read `GetDeviceInfo`, and show the camera's manufacturer/model/serial on screen.

**Architecture:** A pure-Dart PTP-IP client in `lib/ptp_ip/` (no Flutter imports → unit-testable without hardware) behind a thin one-screen Flutter UI in `lib/main.dart`. Wire layouts follow the public PTP-IP standard (CIPA DC-005) + libgphoto2 `ptpip.c`.

**Tech Stack:** Flutter / Dart 3 (`dart:io` sockets, `dart:typed_data`), `flutter_test`.

**Production-stack note:** Treat this as the original Flutter prototype plan. The pairing and PTP-IP
knowledge should be ported into the shared Swift core, then consumed by SwiftUI and Jetpack Compose
production shells.

**Branch & commits:** Per `CLAUDE.md`: work on a branch (not `main`), Conventional Commits. This plan commits per task. Confirm the target branch and that committing is wanted before executing — if the user prefers, squash into fewer commits at the end.

---

## File structure

```
lib/
  main.dart                    # UI: IP field, Pair button, status + camera card
  ptp_ip/
    ptp_constants.dart         # packet types, opcodes, response codes, DataPhase, InitFailReason, version, default GUID
    ptp_exceptions.dart        # PtpIpException, InitFailException, PtpResponseException
    ptp_ip_packet.dart         # PtpIpPacket: Length(4)+Type(4)+payload encode/decode
    ptp_operation.dart         # buildOperationRequestPayload(), OperationResponse.parse(), DataPhase
    socket_reader.dart         # SocketReader: buffered readExact(n) over a Stream<Uint8List>
    device_info.dart           # DeviceInfo.parse(dataset) -> {manufacturer, model, deviceVersion, serialNumber}
    ptp_ip_client.dart         # encodeFriendlyName(), buildInitCommandPayload(), PtpIpClient (orchestrator)
test/
  ptp_ip/
    ptp_constants_test.dart
    ptp_exceptions_test.dart
    ptp_ip_packet_test.dart
    ptp_operation_test.dart
    socket_reader_test.dart
    device_info_test.dart
    init_command_test.dart
  widget_test.dart             # smoke test: app builds, shows Pair button + IP field
```

---

## Task 0: Reset — remove the old prototype

**Files:**
- Delete: `lib/main.dart`, `lib/zr_live_view.dart`, `test/widget_test.dart`, `PROTOTYPE.md`
- Modify: `pubspec.yaml` (remove `bonsoir` dependency)

- [ ] **Step 1: Delete the old prototype files**

```bash
rm lib/main.dart lib/zr_live_view.dart test/widget_test.dart PROTOTYPE.md
```

- [ ] **Step 2: Remove the unused `bonsoir` dependency**

In `pubspec.yaml`, delete this line under `dependencies:`:

```yaml
  bonsoir: ^7.1.1  # For Bonjour/mDNS discovery of PTP cameras (rescan + tap in list to trigger pairing wizard)
```

- [ ] **Step 3: Refresh packages and confirm a clean analyze**

Run: `flutter pub get && flutter analyze`
Expected: `No issues found!` (empty `lib/` analyzes clean; the app entrypoint is rebuilt in Task 9).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove first pairing prototype to rebuild cleanly"
```

---

## Task 1: Protocol constants + InitFailReason

**Files:**
- Create: `lib/ptp_ip/ptp_constants.dart`
- Test: `test/ptp_ip/ptp_constants_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/ptp_constants_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/ptp_constants.dart';

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/ptp_constants_test.dart`
Expected: FAIL — `ptp_constants.dart` / `InitFailReason` not found.

- [ ] **Step 3: Write the implementation**

```dart
// lib/ptp_ip/ptp_constants.dart
import 'dart:typed_data';

/// Default PTP-IP TCP port (both the command and event channels).
const int ptpIpPort = 15740;

/// Canonical PTP-IP protocol version (UINT32 0x00010000 -> wire bytes 00 00 01 00).
const int ptpIpProtocolVersion = 0x00010000;

/// PTP-IP packet type codes (CIPA DC-005).
class PtpIpType {
  PtpIpType._();
  static const int initCommandRequest = 1;
  static const int initCommandAck = 2;
  static const int initEventRequest = 3;
  static const int initEventAck = 4;
  static const int initFail = 5;
  static const int operationRequest = 6;
  static const int operationResponse = 7;
  static const int event = 8;
  static const int startData = 9;
  static const int data = 0x0A;
  static const int cancel = 0x0B;
  static const int endData = 0x0C;
}

/// PTP operation codes used by this prototype.
class PtpOp {
  PtpOp._();
  static const int getDeviceInfo = 0x1001;
  static const int openSession = 0x1002;
  static const int closeSession = 0x1003;
}

/// PTP response codes.
class PtpResponse {
  PtpResponse._();
  static const int ok = 0x2001;
}

/// PTP-IP Init_Fail reason codes (CIPA DC-005 §2.3.5).
enum InitFailReason {
  rejectedInitiator(1),
  busy(2),
  unspecified(3),
  unknown(-1);

  const InitFailReason(this.code);

  /// The on-wire reason value (or -1 for [unknown]).
  final int code;

  /// Maps a raw on-wire reason value to an [InitFailReason].
  static InitFailReason fromCode(int code) => switch (code) {
        1 => InitFailReason.rejectedInitiator,
        2 => InitFailReason.busy,
        3 => InitFailReason.unspecified,
        _ => InitFailReason.unknown,
      };
}

/// A stable, app-specific 16-byte initiator GUID. Hardcoded so the camera sees
/// the *same* identity on every attempt (a per-attempt-random GUID can never be
/// recognized/paired). A persisted GUID is a future enhancement.
Uint8List zcineControllerGuid() => Uint8List.fromList(<int>[
      0x5a, 0x43, 0x69, 0x6e, 0x65, 0x43, 0x74, 0x72,
      0x6c, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
    ]);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/ptp_constants_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/ptp_constants.dart test/ptp_ip/ptp_constants_test.dart
git commit -m "feat: add PTP-IP protocol constants and Init_Fail reasons"
```

---

## Task 2: Exceptions

**Files:**
- Create: `lib/ptp_ip/ptp_exceptions.dart`
- Test: `test/ptp_ip/ptp_exceptions_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/ptp_exceptions_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/ptp_constants.dart';
import 'package:openzcine/ptp_ip/ptp_exceptions.dart';

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/ptp_exceptions_test.dart`
Expected: FAIL — `ptp_exceptions.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// lib/ptp_ip/ptp_exceptions.dart
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
  InitFailException(this.reason, this.rawCode) : super(_message(reason, rawCode));

  /// Decoded reason.
  final InitFailReason reason;

  /// Raw on-wire reason value.
  final int rawCode;

  static String _message(InitFailReason reason, int rawCode) => switch (reason) {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/ptp_exceptions_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/ptp_exceptions.dart test/ptp_ip/ptp_exceptions_test.dart
git commit -m "feat: add PTP-IP exception types with actionable Init_Fail messages"
```

---

## Task 3: PtpIpPacket framing

**Files:**
- Create: `lib/ptp_ip/ptp_ip_packet.dart`
- Test: `test/ptp_ip/ptp_ip_packet_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/ptp_ip_packet_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/ptp_ip_packet.dart';

void main() {
  test('toBytes writes little-endian Length then Type, then payload', () {
    final pkt = PtpIpPacket(1, Uint8List.fromList([0xAA, 0xBB]));
    expect(pkt.toBytes(), [10, 0, 0, 0, 1, 0, 0, 0, 0xAA, 0xBB]);
  });

  test('fromBytes round-trips type and payload', () {
    final original = PtpIpPacket(5, Uint8List.fromList([1, 0, 0, 0]));
    final parsed = PtpIpPacket.fromBytes(original.toBytes());
    expect(parsed.type, 5);
    expect(parsed.payload, [1, 0, 0, 0]);
  });

  test('fromBytes throws on a header shorter than 8 bytes', () {
    expect(() => PtpIpPacket.fromBytes(Uint8List(4)), throwsFormatException);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/ptp_ip_packet_test.dart`
Expected: FAIL — `ptp_ip_packet.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// lib/ptp_ip/ptp_ip_packet.dart
import 'dart:typed_data';

/// A PTP-IP packet: an 8-byte header (Length, Type — both UINT32 LE) followed by
/// a type-specific payload. `Length` counts the whole packet including the header.
class PtpIpPacket {
  PtpIpPacket(this.type, this.payload);

  /// PTP-IP packet type code (see [PtpIpType]).
  final int type;

  /// Bytes after the 8-byte header.
  final Uint8List payload;

  /// Serializes to `Length(4 LE) + Type(4 LE) + payload`.
  Uint8List toBytes() {
    final length = 8 + payload.length;
    final bytes = Uint8List(length);
    final bd = ByteData.sublistView(bytes);
    bd.setUint32(0, length, Endian.little);
    bd.setUint32(4, type, Endian.little);
    bytes.setRange(8, length, payload);
    return bytes;
  }

  /// Parses a complete, length-prefixed packet from [bytes].
  static PtpIpPacket fromBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('PTP-IP packet shorter than its 8-byte header');
    }
    final bd = ByteData.sublistView(bytes);
    final length = bd.getUint32(0, Endian.little);
    final type = bd.getUint32(4, Endian.little);
    if (bytes.length < length) {
      throw const FormatException('PTP-IP packet truncated');
    }
    return PtpIpPacket(type, Uint8List.sublistView(bytes, 8, length));
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/ptp_ip_packet_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/ptp_ip_packet.dart test/ptp_ip/ptp_ip_packet_test.dart
git commit -m "feat: add PTP-IP packet framing"
```

---

## Task 4: Operation request/response envelope

**Files:**
- Create: `lib/ptp_ip/ptp_operation.dart`
- Test: `test/ptp_ip/ptp_operation_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/ptp_operation_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/ptp_constants.dart';
import 'package:openzcine/ptp_ip/ptp_operation.dart';

void main() {
  test('OpenSession request payload: DataPhase(1)+Code(0x1002)+TID(0)+param(1)', () {
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/ptp_operation_test.dart`
Expected: FAIL — `ptp_operation.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// lib/ptp_ip/ptp_operation.dart
import 'dart:typed_data';

/// PTP-IP `Operation_Request` DataPhaseInfo values (libgphoto2 `ptpip.c`).
class DataPhase {
  DataPhase._();

  /// No data phase, or a data-IN (camera -> host) operation.
  static const int noDataOrDataIn = 1;

  /// A data-OUT (host -> camera) operation.
  static const int dataOut = 2;
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/ptp_operation_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/ptp_operation.dart test/ptp_ip/ptp_operation_test.dart
git commit -m "feat: add PTP-IP operation request/response envelope"
```

---

## Task 5: Init_Command_Request builder (version-byte regression guard)

**Files:**
- Create: `lib/ptp_ip/ptp_ip_client.dart` (functions only this task; the class is added in Task 8)
- Test: `test/ptp_ip/init_command_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/init_command_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/ptp_ip_client.dart';

void main() {
  test('friendly name is raw UTF-16LE with a double-NUL terminator', () {
    expect(encodeFriendlyName('ZR'), [0x5A, 0x00, 0x52, 0x00, 0x00, 0x00]);
  });

  test('Init_Command payload = GUID + name + version, with version 00 00 01 00', () {
    final guid = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final payload = buildInitCommandPayload(guid, 'ZR');
    expect(payload.sublist(0, 16), guid);
    expect(payload.sublist(16, 22), [0x5A, 0x00, 0x52, 0x00, 0x00, 0x00]);
    // Regression guard for the prior bug: version must be 00 00 01 00, NOT 00 01 00 00.
    expect(payload.sublist(22, 26), [0x00, 0x00, 0x01, 0x00]);
  });

  test('buildInitCommandPayload rejects a non-16-byte GUID', () {
    expect(() => buildInitCommandPayload(Uint8List(8), 'x'), throwsArgumentError);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/init_command_test.dart`
Expected: FAIL — `ptp_ip_client.dart` / `encodeFriendlyName` not found.

- [ ] **Step 3: Write the implementation (functions only for now)**

```dart
// lib/ptp_ip/ptp_ip_client.dart
import 'dart:typed_data';

import 'ptp_constants.dart';

/// Encodes [name] as raw UTF-16LE with a trailing double-NUL — the PTP-IP
/// friendly-name encoding (NOT a PTP length-prefixed string).
Uint8List encodeFriendlyName(String name) {
  final units = name.codeUnits;
  final out = Uint8List((units.length + 1) * 2); // +1 char for the NUL terminator
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
    throw ArgumentError.value(guid.length, 'guid.length', 'GUID must be 16 bytes');
  }
  final version = Uint8List(4);
  ByteData.sublistView(version).setUint32(0, ptpIpProtocolVersion, Endian.little);
  return (BytesBuilder()
        ..add(guid)
        ..add(encodeFriendlyName(friendlyName))
        ..add(version))
      .toBytes();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/init_command_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/ptp_ip_client.dart test/ptp_ip/init_command_test.dart
git commit -m "feat: build Init_Command_Request with correct version bytes"
```

---

## Task 6: SocketReader (buffered exact-length reads)

**Files:**
- Create: `lib/ptp_ip/socket_reader.dart`
- Test: `test/ptp_ip/socket_reader_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/socket_reader_test.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/socket_reader.dart';

void main() {
  test('readExact reassembles across chunk boundaries', () async {
    final controller = StreamController<Uint8List>();
    final reader = SocketReader(controller.stream);

    final first = reader.readExact(5);
    controller.add(Uint8List.fromList([1, 2]));
    controller.add(Uint8List.fromList([3, 4, 5, 6]));
    expect(await first, [1, 2, 3, 4, 5]);
    expect(await reader.readExact(1), [6]);

    await controller.close();
    await reader.close();
  });

  test('readExact errors if the stream closes before enough bytes', () async {
    final controller = StreamController<Uint8List>();
    final reader = SocketReader(controller.stream);
    final pending = reader.readExact(10);
    controller.add(Uint8List.fromList([1, 2, 3]));
    await controller.close();
    await expectLater(pending, throwsA(isA<Exception>()));
    await reader.close();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/socket_reader_test.dart`
Expected: FAIL — `socket_reader.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// lib/ptp_ip/socket_reader.dart
import 'dart:async';
import 'dart:typed_data';

/// Buffers bytes from a byte stream (e.g. a `Socket`) and hands them out in
/// exact-length chunks. Subscribes once; callers `await readExact(n)` in order.
class SocketReader {
  SocketReader(Stream<Uint8List> stream) {
    _sub = stream.listen(_onData, onError: _onError, onDone: _onDone);
  }

  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _buffer = BytesBuilder();
  final List<_PendingRead> _pending = [];
  Object? _error;
  bool _done = false;

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    _drain();
  }

  void _onError(Object error) {
    _error = error;
    for (final p in _pending) {
      p.completer.completeError(error);
    }
    _pending.clear();
  }

  void _onDone() {
    _done = true;
    _failPending();
  }

  void _drain() {
    while (_pending.isNotEmpty && _buffer.length >= _pending.first.count) {
      final pending = _pending.removeAt(0);
      final all = _buffer.takeBytes();
      pending.completer.complete(Uint8List.sublistView(all, 0, pending.count));
      _buffer.add(Uint8List.sublistView(all, pending.count));
    }
  }

  void _failPending() {
    for (final p in _pending) {
      p.completer.completeError(
        StateError('Stream closed before $_neededDescription'),
      );
    }
    _pending.clear();
  }

  String get _neededDescription =>
      _pending.isEmpty ? 'read' : '${_pending.first.count} bytes arrived';

  /// Completes with exactly [count] bytes, or errors if the stream closes first.
  Future<Uint8List> readExact(int count) {
    if (_error != null) return Future.error(_error!);
    final completer = Completer<Uint8List>();
    _pending.add(_PendingRead(count, completer));
    if (_done) {
      _failPending();
    } else {
      _drain();
    }
    return completer.future;
  }

  /// Cancels the underlying subscription.
  Future<void> close() => _sub.cancel();
}

class _PendingRead {
  _PendingRead(this.count, this.completer);
  final int count;
  final Completer<Uint8List> completer;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/socket_reader_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/socket_reader.dart test/ptp_ip/socket_reader_test.dart
git commit -m "feat: add buffered SocketReader for exact-length reads"
```

---

## Task 7: DeviceInfo dataset parser

**Files:**
- Create: `lib/ptp_ip/device_info.dart`
- Test: `test/ptp_ip/device_info_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/ptp_ip/device_info_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/device_info.dart';

/// PTP string: UINT8 length-in-chars (incl. trailing NUL) + UTF-16LE code units.
List<int> _ptpString(String s) {
  if (s.isEmpty) return [0];
  final bytes = <int>[s.length + 1];
  for (final u in s.codeUnits) {
    bytes.addAll([u & 0xFF, (u >> 8) & 0xFF]);
  }
  bytes.addAll([0, 0]); // NUL
  return bytes;
}

List<int> _emptyArray() => [0, 0, 0, 0]; // UINT32 count = 0

void main() {
  test('parse extracts manufacturer, model, version, serial', () {
    final data = <int>[
      100, 0, //              StandardVersion
      10, 0, 0, 0, //         VendorExtensionID
      100, 0, //              VendorExtensionVersion
      ..._ptpString(''), //   VendorExtensionDesc
      0, 0, //                FunctionalMode
      ..._emptyArray(), //    OperationsSupported
      ..._emptyArray(), //    EventsSupported
      ..._emptyArray(), //    DevicePropertiesSupported
      ..._emptyArray(), //    CaptureFormats
      ..._emptyArray(), //    ImageFormats
      ..._ptpString('Nikon'),
      ..._ptpString('ZR'),
      ..._ptpString('1.0'),
      ..._ptpString('ABC123'),
    ];
    final info = DeviceInfo.parse(Uint8List.fromList(data));
    expect(info.manufacturer, 'Nikon');
    expect(info.model, 'ZR');
    expect(info.deviceVersion, '1.0');
    expect(info.serialNumber, 'ABC123');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ptp_ip/device_info_test.dart`
Expected: FAIL — `device_info.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// lib/ptp_ip/device_info.dart
import 'dart:typed_data';

/// The identity fields of a PTP `DeviceInfo` dataset that this prototype shows.
class DeviceInfo {
  const DeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
    required this.serialNumber,
  });

  final String manufacturer;
  final String model;
  final String deviceVersion;
  final String serialNumber;

  /// Parses a standard PTP `DeviceInfo` dataset and extracts the trailing
  /// identity strings, skipping the fixed fields and the five code arrays.
  static DeviceInfo parse(Uint8List data) {
    final r = _DatasetReader(data);
    r.skip(2); // StandardVersion (UINT16)
    r.skip(4); // VendorExtensionID (UINT32)
    r.skip(2); // VendorExtensionVersion (UINT16)
    r.skipString(); // VendorExtensionDesc
    r.skip(2); // FunctionalMode (UINT16)
    r.skipUint16Array(); // OperationsSupported
    r.skipUint16Array(); // EventsSupported
    r.skipUint16Array(); // DevicePropertiesSupported
    r.skipUint16Array(); // CaptureFormats
    r.skipUint16Array(); // ImageFormats
    return DeviceInfo(
      manufacturer: r.readString(),
      model: r.readString(),
      deviceVersion: r.readString(),
      serialNumber: r.readString(),
    );
  }
}

class _DatasetReader {
  _DatasetReader(this._data) : _bd = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _bd;
  int _offset = 0;

  void skip(int bytes) => _offset += bytes;

  void skipUint16Array() {
    final count = _bd.getUint32(_offset, Endian.little);
    _offset += 4 + count * 2;
  }

  /// Reads a PTP string: UINT8 char count (incl. trailing NUL), then that many
  /// UTF-16LE code units. Returns the value without the NUL.
  String readString() {
    final numChars = _bd.getUint8(_offset);
    _offset += 1;
    if (numChars == 0) return '';
    final units = <int>[];
    for (var i = 0; i < numChars; i++) {
      units.add(_bd.getUint16(_offset, Endian.little));
      _offset += 2;
    }
    if (units.isNotEmpty && units.last == 0) units.removeLast();
    return String.fromCharCodes(units);
  }

  void skipString() {
    final numChars = _bd.getUint8(_offset);
    _offset += 1 + numChars * 2;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ptp_ip/device_info_test.dart`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/device_info.dart test/ptp_ip/device_info_test.dart
git commit -m "feat: parse PTP DeviceInfo identity fields"
```

---

## Task 8: PtpIpClient orchestrator

**Files:**
- Modify: `lib/ptp_ip/ptp_ip_client.dart` (append the `PtpIpClient` class to the functions from Task 5)

No unit test: this orchestrator only sequences already-tested units over live TCP sockets; it is verified by the manual on-device test (Task 10). Keep the methods thin so the logic stays obvious.

- [ ] **Step 1: Replace the imports at the top of `lib/ptp_ip/ptp_ip_client.dart`**

Replace the existing import block with:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'device_info.dart';
import 'ptp_constants.dart';
import 'ptp_exceptions.dart';
import 'ptp_ip_packet.dart';
import 'ptp_operation.dart';
import 'socket_reader.dart';
```

- [ ] **Step 2: Append the `PtpIpClient` class to the end of the file**

```dart
/// Connects to a camera over PTP-IP, performs the handshake, opens a session,
/// and reads the camera identity. One attempt per call; throws on any failure
/// and always closes its sockets.
class PtpIpClient {
  PtpIpClient({
    required this.host,
    required this.guid,
    this.port = ptpIpPort,
    this.friendlyName = 'OpenZCine',
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

  /// Pairs and returns the camera identity. Closes everything on failure.
  Future<DeviceInfo> pairAndIdentify() async {
    try {
      _command = await Socket.connect(host, port, timeout: timeout);
      _commandReader = SocketReader(_command!);
      await _initCommand();

      _event = await Socket.connect(host, port, timeout: timeout);
      _eventReader = SocketReader(_event!);
      await _initEvent();

      await _openSession();
      return await _getDeviceInfo();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> _initCommand() async {
    _send(_command!,
        PtpIpPacket(PtpIpType.initCommandRequest, buildInitCommandPayload(guid, friendlyName)));
    final reply = await _readPacket(_commandReader!);
    if (reply.type == PtpIpType.initFail) {
      final code = ByteData.sublistView(reply.payload).getUint32(0, Endian.little);
      throw InitFailException(InitFailReason.fromCode(code), code);
    }
    if (reply.type != PtpIpType.initCommandAck) {
      throw PtpIpException('Expected Init_Command_Ack, got packet type ${reply.type}');
    }
    _connectionNumber = ByteData.sublistView(reply.payload).getUint32(0, Endian.little);
  }

  Future<void> _initEvent() async {
    final payload = Uint8List(4);
    ByteData.sublistView(payload).setUint32(0, _connectionNumber, Endian.little);
    _send(_event!, PtpIpPacket(PtpIpType.initEventRequest, payload));
    final reply = await _readPacket(_eventReader!);
    if (reply.type != PtpIpType.initEventAck) {
      throw PtpIpException('Expected Init_Event_Ack, got packet type ${reply.type}');
    }
  }

  Future<void> _openSession() async {
    final (response, _) =
        await _transact(code: PtpOp.openSession, transactionId: 0, params: const [1]);
    if (response.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.openSession, response.code);
    }
    _nextTransactionId = 1;
  }

  Future<DeviceInfo> _getDeviceInfo() async {
    final (response, data) =
        await _transact(code: PtpOp.getDeviceInfo, transactionId: _nextTransactionId++);
    if (response.code != PtpResponse.ok) {
      throw PtpResponseException(PtpOp.getDeviceInfo, response.code);
    }
    return DeviceInfo.parse(data);
  }

  /// Sends an Operation_Request and drains the command socket until the matching
  /// Operation_Response, assembling any data-phase bytes (TID prefix stripped).
  Future<(OperationResponse, Uint8List)> _transact({
    required int code,
    required int transactionId,
    List<int> params = const [],
  }) async {
    _send(
      _command!,
      PtpIpPacket(PtpIpType.operationRequest,
          buildOperationRequestPayload(code: code, transactionId: transactionId, params: params)),
    );
    final data = BytesBuilder();
    while (true) {
      final pkt = await _readPacket(_commandReader!);
      if (pkt.type == PtpIpType.startData) {
        continue; // payload = TID(4)+TotalLen(4)+unknown(4); not needed
      } else if (pkt.type == PtpIpType.data || pkt.type == PtpIpType.endData) {
        data.add(Uint8List.sublistView(pkt.payload, 4)); // strip 4-byte TID prefix
      } else if (pkt.type == PtpIpType.operationResponse) {
        return (OperationResponse.parse(pkt.payload), data.takeBytes());
      }
    }
  }

  void _send(Socket socket, PtpIpPacket packet) => socket.add(packet.toBytes());

  Future<PtpIpPacket> _readPacket(SocketReader reader) async {
    final header = await reader.readExact(8);
    final bd = ByteData.sublistView(header);
    final length = bd.getUint32(0, Endian.little);
    final type = bd.getUint32(4, Endian.little);
    final payload = length > 8 ? await reader.readExact(length - 8) : Uint8List(0);
    return PtpIpPacket(type, payload);
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
```

- [ ] **Step 3: Confirm it analyzes and the suite still passes**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/ptp_ip/ptp_ip_client.dart
git commit -m "feat: add PtpIpClient pairing orchestrator"
```

---

## Task 9: UI + widget smoke test

**Files:**
- Create: `lib/main.dart`
- Create: `test/widget_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// test/widget_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/main.dart';

void main() {
  testWidgets('renders the IP field and Pair button', (tester) async {
    await tester.pumpWidget(const ZCineApp());
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget_test.dart`
Expected: FAIL — `main.dart` / `ZCineApp` not found.

- [ ] **Step 3: Write the UI**

```dart
// lib/main.dart
import 'package:flutter/material.dart';

import 'ptp_ip/device_info.dart';
import 'ptp_ip/ptp_constants.dart';
import 'ptp_ip/ptp_ip_client.dart';

void main() => runApp(const ZCineApp());

class ZCineApp extends StatelessWidget {
  const ZCineApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'OpenZCine',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const PairPage(),
      );
}

class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final TextEditingController _ip = TextEditingController(text: '192.168.0.1');
  bool _busy = false;
  String _status = "Join the camera's Wi-Fi (Connect to PC), then tap Pair.";
  DeviceInfo? _camera;

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _camera = null;
      _status = 'Pairing with ${_ip.text.trim()}…';
    });
    final client = PtpIpClient(host: _ip.text.trim(), guid: zcineControllerGuid());
    try {
      final info = await client.pairAndIdentify();
      setState(() {
        _camera = info;
        _status = 'Paired ✓';
      });
    } on Exception catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      await client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(title: const Text('OpenZCine — Pair')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ip,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Camera IP (Wi-Fi AP gateway)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _pair,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: const Text('Pair'),
            ),
            const SizedBox(height: 24),
            Text(_status, style: Theme.of(context).textTheme.bodyLarge),
            if (camera != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Manufacturer: ${camera.manufacturer}'),
                      Text('Model: ${camera.model}'),
                      Text('Version: ${camera.deviceVersion}'),
                      Text('Serial: ${camera.serialNumber}'),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget_test.dart`
Expected: PASS (1 test). Note: the test never taps Pair, so no socket I/O runs.

- [ ] **Step 5: Full check + commit**

Run: `flutter analyze && flutter test && just check`
Expected: analyze clean, all unit/widget tests PASS, `just check` green.

```bash
git add lib/main.dart test/widget_test.dart
git commit -m "feat: add pairing UI showing camera identity on success"
```

---

## Task 10: Manual on-device pairing test

**Files:** none (verification only).

- [ ] **Step 1: Build and run on a physical iPhone**

```bash
flutter run -d <your-iphone>
```

- [ ] **Step 2: Put the camera in Direct mode**

On the ZR: enable the Wi-Fi AP and select "Connect to PC" / Camera Control with an active connection profile. Join the iPhone to the ZR's Wi-Fi SSID. Make sure no other controller app holds the camera.

- [ ] **Step 3: Pair**

In the app, confirm the IP (default `192.168.0.1`; check the camera's Wi-Fi info screen if different) and tap **Pair**.

- [ ] **Step 4: Verify success criterion**

Expected: status shows "Paired ✓" and the card shows the camera's manufacturer, model, and serial number.

If it fails: the on-screen message carries the decoded cause. `Init_Fail` reason 1 = the camera rejected us → recheck it is in Connect to PC / Camera Control with an active profile and that no other app is connected.

---

## Self-review (completed)

- **Spec coverage:** nuke (T0), pure-Dart client + thin UI (T1–T9), 5-step handshake→OpenSession→GetDeviceInfo flow (T8), model/serial on screen (T9 + T10 criterion), decoded Init_Fail (T2/T8/T10), exact-bytes version guard (T5), GetDeviceInfo parse (T7) — all covered.
- **Placeholders:** none — every code step is complete.
- **Type consistency:** `PtpIpType`, `PtpOp`, `PtpResponse`, `DataPhase`, `InitFailReason`, `PtpIpPacket`, `buildOperationRequestPayload`/`OperationResponse`, `encodeFriendlyName`/`buildInitCommandPayload`, `SocketReader`, `DeviceInfo`, `PtpIpClient` are defined once and referenced consistently. `_transact` returns `(OperationResponse, Uint8List)` and both consumers destructure it the same way.
- **Known deviation from strict TDD:** `PtpIpClient` (T8) has no unit test (live-socket orchestrator) — covered by the T10 manual test; the byte-level logic it composes is unit-tested in T3–T7.
