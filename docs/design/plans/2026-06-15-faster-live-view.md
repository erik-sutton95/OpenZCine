# Faster, Buttery-Smooth Live View — Implementation Plan

**Goal:** Raise live-view frame rate toward the camera's rate (25/50fps) and make the displayed stream judder-free.

**Architecture:** Keep the camera's MJPEG feed (the only live path). Kill self-imposed overhead (`TCP_NODELAY`, no throttle), shrink frames on the camera (`SetDevicePropValueEx` on `0xD1AC`/`0xD1BC`), and replace the serial render-on-arrival loop with a decoupled producer/consumer: a pipelined fetch+decode loop publishes the newest `ui.Image` into a slot, and the UI renders it via `RawImage`/`RepaintBoundary` paced to vsync.

**Tech Stack:** Dart 3, Flutter, `dart:ui` image codec, `flutter_test`. Spec: `docs/design/specs/2026-06-15-faster-live-view-design.md`.

**Production-stack note:** Treat this as the Flutter prototype plan. Production must preserve the
same transport and smoothness requirements, but implement them with the shared Swift core plus
platform-native iOS/Android decode and render paths.

**Commit note:** Commits are currently held for one pass (user preference). Keep the per-task commit steps for traceability, but the executor should confirm commit cadence with the user before committing.

---

## File Structure

- `lib/ptp_ip/ptp_constants.dart` — add `PtpProp.liveViewImageSize 0xD1AC`, `PtpProp.liveViewImageCompression 0xD1BC`.
- `lib/ptp_ip/ptp_operation.dart` — add `buildStartDataPayload` / `buildEndDataPayload` for the data-out phase.
- `lib/ptp_ip/ptp_ip_client.dart` — `TCP_NODELAY`; data-out path in `_transact`; `configureLiveView`.
- `lib/ptp_ip/live_view_stats.dart` (new) — `FrameSample`, `LiveViewStats`, pure `computeStats`.
- `lib/ptp_ip/live_view_stream.dart` (new) — `LiveViewStream` producer controller.
- `lib/live_view_page.dart` — consume `LiveViewStream`; `RawImage`/`RepaintBoundary` + fps/jitter overlay.
- Tests under `test/ptp_ip/`.

---

## Task 1: Disable Nagle on the PTP-IP sockets

**Files:**
- Modify: `lib/ptp_ip/ptp_ip_client.dart` (in `pairAndIdentify`, right after each `Socket.connect`)

No unit test — `TCP_NODELAY` is a socket side-effect; validated on-device by lower latency. Keep it tiny and obvious.

- [ ] **Step 1: Set the option on the command socket**

In `pairAndIdentify`, change:

```dart
      _command = await Socket.connect(host, port, timeout: timeout);
      _commandReader = SocketReader(_command!);
```

to:

```dart
      _command = await Socket.connect(host, port, timeout: timeout);
      _command!.setOption(SocketOption.tcpNoDelay, true);
      _commandReader = SocketReader(_command!);
```

- [ ] **Step 2: Set the option on the event socket**

Change:

```dart
      _event = await Socket.connect(host, port, timeout: timeout);
      _eventReader = SocketReader(_event!);
```

to:

```dart
      _event = await Socket.connect(host, port, timeout: timeout);
      _event!.setOption(SocketOption.tcpNoDelay, true);
      _eventReader = SocketReader(_event!);
```

- [ ] **Step 3: Verify it compiles and tests pass**

Run: `just analyze && just test`
Expected: no issues; all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/ptp_ip/ptp_ip_client.dart
git commit -m "perf: disable Nagle on PTP-IP sockets for lower request latency"
```

---

## Task 2: Data-out packet helpers

**Files:**
- Modify: `lib/ptp_ip/ptp_operation.dart`
- Test: `test/ptp_ip/ptp_operation_test.dart`

- [ ] **Step 1: Write the failing tests**

Append to `test/ptp_ip/ptp_operation_test.dart` (inside `main()`):

```dart
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
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL — `buildStartDataPayload`/`buildEndDataPayload` not defined.

- [ ] **Step 3: Implement the helpers**

Append to `lib/ptp_ip/ptp_operation.dart`:

```dart
/// Builds a `Start_Data` packet payload: `TransactionID(4) + TotalLength(8)`,
/// little-endian. Wrap in `PtpIpPacket(PtpIpType.startData, ...)`.
Uint8List buildStartDataPayload(int transactionId, int totalLength) {
  final bytes = Uint8List(12);
  final bd = ByteData.sublistView(bytes)
    ..setUint32(0, transactionId, Endian.little)
    ..setUint64(4, totalLength, Endian.little);
  return bd.buffer.asUint8List();
}

/// Builds an `End_Data` packet payload: `TransactionID(4) + data`, little-endian
/// TID. Wrap in `PtpIpPacket(PtpIpType.endData, ...)`.
Uint8List buildEndDataPayload(int transactionId, Uint8List data) {
  final out = Uint8List(4 + data.length);
  ByteData.sublistView(out).setUint32(0, transactionId, Endian.little);
  out.setRange(4, 4 + data.length, data);
  return out;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/ptp_operation.dart test/ptp_ip/ptp_operation_test.dart
git commit -m "feat: add PTP-IP data-out (Start_Data/End_Data) packet builders"
```

---

## Task 3: SetDevicePropValueEx data-out + configureLiveView

**Files:**
- Modify: `lib/ptp_ip/ptp_constants.dart` (add prop codes)
- Modify: `lib/ptp_ip/ptp_ip_client.dart` (`_transact` data-out param; `configureLiveView`)
- Test: `test/ptp_ip/ptp_operation_test.dart` (request bytes)

- [ ] **Step 1: Write the failing test for the request envelope**

Append to `test/ptp_ip/ptp_operation_test.dart`:

```dart
  test('SetDevicePropValueEx request: dataOut(2)+code(0x943C)+tid+prop param', () {
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
      0xac, 0xd1, 0x00, 0x00, // Param1 = 0xD1AC LiveViewImageSize
    ]);
  });
```

- [ ] **Step 2: Run to verify it passes already**

Run: `just test`
Expected: PASS (this exercises existing `buildOperationRequestPayload` with `DataPhase.dataOut`; it locks the envelope we rely on). If it fails, stop and fix `buildOperationRequestPayload` before continuing.

- [ ] **Step 3: Add the live-view property codes**

In `lib/ptp_ip/ptp_constants.dart`, inside `class PtpProp`, after `liveViewProhibitionCondition`:

```dart
  /// `LiveViewImageSize` — 1=QVGA, 2=VGA, 3=XGA (settable; [VERIFY-ON-HW] in PC mode).
  static const int liveViewImageSize = 0xd1ac;

  /// `LiveViewImageCompression` — 0..5 (Basic/Normal/Fine × Size/Quality).
  static const int liveViewImageCompression = 0xd1bc;
```

- [ ] **Step 4: Add the data-out path to `_transact`**

In `lib/ptp_ip/ptp_ip_client.dart`, replace the `_transact` signature + send block:

```dart
  Future<(OperationResponse, Uint8List)> _transact({
    required int code,
    required int transactionId,
    List<int> params = const [],
    int dataPhase = DataPhase.noDataOrDataIn,
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
```

with:

```dart
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
        PtpIpPacket(PtpIpType.endData, buildEndDataPayload(transactionId, dataOut)),
      );
    }
```

(The existing read loop after this already returns at `Operation_Response`, which is all a data-out op sends back.)

- [ ] **Step 5: Add `configureLiveView`**

In `lib/ptp_ip/ptp_ip_client.dart`, add a public method (place it right after `stopLiveView`):

```dart
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
```

- [ ] **Step 6: Verify**

Run: `just analyze && just test`
Expected: no issues; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/ptp_ip/ptp_constants.dart lib/ptp_ip/ptp_ip_client.dart test/ptp_ip/ptp_operation_test.dart
git commit -m "feat: SetDevicePropValueEx data-out + best-effort configureLiveView"
```

---

## Task 4: LiveViewStats + pure computeStats

**Files:**
- Create: `lib/ptp_ip/live_view_stats.dart`
- Test: `test/ptp_ip/live_view_stats_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/ptp_ip/live_view_stats_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/live_view_stats.dart';

void main() {
  test('computeStats: steady 100ms cadence -> 10 fps, 0 jitter', () {
    final samples = <FrameSample>[
      for (var i = 1; i <= 10; i++)
        FrameSample(tMs: i * 100, bytes: 10240, decodeMs: 5),
    ];
    final s = computeStats(samples, 1000);
    expect(s.fps, 10);
    expect(s.jitterMs, 0);
    expect(s.avgFrameKb, closeTo(10.0, 0.001));
    expect(s.avgDecodeMs, closeTo(5.0, 0.001));
  });

  test('computeStats: irregular intervals -> nonzero jitter', () {
    final samples = <FrameSample>[
      FrameSample(tMs: 100, bytes: 1, decodeMs: 0),
      FrameSample(tMs: 120, bytes: 1, decodeMs: 0), // 20ms gap
      FrameSample(tMs: 320, bytes: 1, decodeMs: 0), // 200ms gap
    ];
    expect(computeStats(samples, 320).jitterMs, greaterThan(0));
  });

  test('computeStats: drops samples outside the 1s window', () {
    final samples = <FrameSample>[
      FrameSample(tMs: 50, bytes: 1, decodeMs: 0), // older than now-1000
      FrameSample(tMs: 1100, bytes: 1, decodeMs: 0),
      FrameSample(tMs: 1200, bytes: 1, decodeMs: 0),
    ];
    expect(computeStats(samples, 1200).fps, 2);
  });

  test('computeStats: empty -> zeroed stats', () {
    expect(computeStats(const [], 0).fps, 0);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL — `live_view_stats.dart` does not exist.

- [ ] **Step 3: Implement**

Create `lib/ptp_ip/live_view_stats.dart`:

```dart
import 'dart:math' as math;

/// One captured live-view frame: arrival time, JPEG size, decode duration.
class FrameSample {
  const FrameSample({
    required this.tMs,
    required this.bytes,
    required this.decodeMs,
  });

  /// Arrival time in ms on the stream's monotonic clock.
  final int tMs;

  /// JPEG byte length.
  final int bytes;

  /// Decode duration in ms.
  final int decodeMs;
}

/// Rolling live-view statistics over a recent window.
class LiveViewStats {
  const LiveViewStats({
    required this.fps,
    required this.jitterMs,
    required this.avgFrameKb,
    required this.avgDecodeMs,
  });

  const LiveViewStats.empty()
      : fps = 0,
        jitterMs = 0,
        avgFrameKb = 0,
        avgDecodeMs = 0;

  /// Frames in the last window (≈ frames per second).
  final int fps;

  /// Std-dev of inter-frame intervals in ms (lower = smoother).
  final double jitterMs;

  /// Mean JPEG size over the window, in KiB.
  final double avgFrameKb;

  /// Mean decode time over the window, in ms.
  final double avgDecodeMs;
}

/// Computes [LiveViewStats] over the [windowMs] ending at [nowMs]. Pure.
LiveViewStats computeStats(
  List<FrameSample> samples,
  int nowMs, {
  int windowMs = 1000,
}) {
  final window = samples.where((s) => s.tMs > nowMs - windowMs).toList();
  if (window.isEmpty) return const LiveViewStats.empty();
  final intervals = <int>[
    for (var i = 1; i < window.length; i++) window[i].tMs - window[i - 1].tMs,
  ];
  final totalBytes = window.fold<int>(0, (a, s) => a + s.bytes);
  final totalDecode = window.fold<int>(0, (a, s) => a + s.decodeMs);
  return LiveViewStats(
    fps: window.length,
    jitterMs: _stdDev(intervals),
    avgFrameKb: totalBytes / window.length / 1024,
    avgDecodeMs: totalDecode / window.length,
  );
}

double _stdDev(List<int> xs) {
  if (xs.length < 2) return 0;
  final mean = xs.fold<int>(0, (a, x) => a + x) / xs.length;
  final variance =
      xs.fold<double>(0, (a, x) => a + (x - mean) * (x - mean)) / xs.length;
  return math.sqrt(variance);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ptp_ip/live_view_stats.dart test/ptp_ip/live_view_stats_test.dart
git commit -m "feat: live-view fps/jitter stats (pure computeStats)"
```

---

## Task 5: LiveViewStream producer controller

**Files:**
- Create: `lib/ptp_ip/live_view_stream.dart`

No unit test (sockets + GPU decode); validated on-device in Task 7. Keep logic thin and delegate stats to the tested `computeStats`.

- [ ] **Step 1: Implement the controller**

Create `lib/ptp_ip/live_view_stream.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'live_view_stats.dart';
import 'ptp_ip_client.dart';

/// Drives a pipelined live-view stream on [client]: keeps one frame request in
/// flight, decodes off the UI isolate, and publishes the newest [ui.Image] plus
/// rolling [LiveViewStats]. The PTP-IP session is owned by the caller.
class LiveViewStream {
  LiveViewStream(this.client);

  /// An already-paired, open session.
  final PtpIpClient client;

  /// Newest decoded frame (null until the first frame / on error).
  final ValueNotifier<ui.Image?> frame = ValueNotifier<ui.Image?>(null);

  /// Rolling stats for the overlay.
  final ValueNotifier<LiveViewStats> stats =
      ValueNotifier<LiveViewStats>(const LiveViewStats.empty());

  /// Last error message (null while healthy).
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  final Stopwatch _clock = Stopwatch();
  final List<FrameSample> _samples = <FrameSample>[];
  bool _running = false;

  /// Configures the camera (best-effort), starts live view, and begins
  /// streaming. Safe to call once.
  Future<void> start({int size = 2, int compression = 2}) async {
    await client.configureLiveView(size: size, compression: compression);
    try {
      await client.startLiveView();
    } on Exception catch (e) {
      error.value = 'Could not start live view: $e';
      return;
    }
    _running = true;
    _clock.start();
    unawaited(_loop());
  }

  Future<void> _loop() async {
    var next = client.liveViewFrameJpeg();
    while (_running) {
      Uint8List jpeg;
      try {
        jpeg = await next;
      } on Exception catch (e) {
        error.value = e.toString();
        if (!_running) break;
        next = client.liveViewFrameJpeg();
        continue;
      }
      if (!_running) break;
      next = client.liveViewFrameJpeg(); // pipeline: request N+1 before decoding N
      final decodeStart = _clock.elapsedMilliseconds;
      final image = await _decode(jpeg);
      final tMs = _clock.elapsedMilliseconds;
      _publish(
        image,
        FrameSample(tMs: tMs, bytes: jpeg.length, decodeMs: tMs - decodeStart),
      );
    }
    await next.then<void>((_) {}).catchError((_) {}); // drain the in-flight request
    await client.stopLiveView();
  }

  Future<ui.Image> _decode(Uint8List jpeg) async {
    final codec = await ui.instantiateImageCodec(jpeg);
    final frameInfo = await codec.getNextFrame();
    codec.dispose();
    return frameInfo.image;
  }

  void _publish(ui.Image image, FrameSample sample) {
    final replaced = frame.value;
    frame.value = image;
    error.value = null;
    _samples
      ..add(sample)
      ..removeWhere((s) => s.tMs < sample.tMs - 1000);
    stats.value = computeStats(_samples, sample.tMs);
    if (replaced != null) {
      // Dispose the prior image after the frame that no longer uses it renders.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => replaced.dispose());
    }
  }

  /// Stops streaming and live view (best-effort). The loop drains its in-flight
  /// request before tearing down.
  Future<void> stop() async {
    _running = false;
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `just analyze && just test`
Expected: no issues; existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/ptp_ip/live_view_stream.dart
git commit -m "feat: pipelined live-view producer controller (decoupled fetch/decode)"
```

---

## Task 6: Rewire LiveViewPage to the controller (vsync render + overlay)

**Files:**
- Modify: `lib/live_view_page.dart` (full rewrite)

No unit test (UI + device); validated in Task 7. The current widget test only covers `PairPage`, so it is unaffected.

- [ ] **Step 1: Rewrite the page**

Replace the entire contents of `lib/live_view_page.dart` with:

```dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ptp_ip/live_view_stats.dart';
import 'ptp_ip/live_view_stream.dart';
import 'ptp_ip/ptp_ip_client.dart';

/// Full-screen live-view stream rendered from a [LiveViewStream]: the newest
/// decoded frame is painted via [RawImage] in a [RepaintBoundary], paced to
/// vsync, with an fps + jitter readout bottom-right and an overlay back button.
class LiveViewPage extends StatefulWidget {
  const LiveViewPage({required this.client, super.key});

  /// An already-paired, open session to stream from.
  final PtpIpClient client;

  @override
  State<LiveViewPage> createState() => _LiveViewPageState();
}

class _LiveViewPageState extends State<LiveViewPage> {
  late final LiveViewStream _stream;

  @override
  void initState() {
    super.initState();
    _stream = LiveViewStream(widget.client);
    unawaited(_stream.start());
  }

  @override
  void dispose() {
    unawaited(_stream.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: ValueListenableBuilder<ui.Image?>(
                valueListenable: _stream.frame,
                builder: (context, image, _) {
                  if (image != null) {
                    return RepaintBoundary(
                      child: RawImage(image: image, fit: BoxFit.contain),
                    );
                  }
                  return ValueListenableBuilder<String?>(
                    valueListenable: _stream.error,
                    builder: (context, err, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        err ?? 'Starting live view…',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Material(
                      color: Colors.black38,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ValueListenableBuilder<LiveViewStats>(
                      valueListenable: _stream.stats,
                      builder: (context, s, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            '${s.fps} fps · ${s.jitterMs.toStringAsFixed(1)} ms',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

Run: `just analyze && just test`
Expected: no issues; all tests pass (44 + the new stats/data-out tests).

- [ ] **Step 3: Commit**

```bash
git add lib/live_view_page.dart
git commit -m "feat: render live view via vsync-paced RawImage + fps/jitter overlay"
```

---

## Task 7: On-device measurement & tuning

**Files:** none (manual, on-device).

- [ ] **Step 1: Baseline at VGA**

Build to the iPhone, pair, open Live view (defaults: `size=2` VGA, `compression=2`). Note the overlay's `fps` and jitter `ms`. Confirm the `establishmentSummary` from the pair status shows `lvSize=0x2001 lvComp=0x2001` (writes accepted) or `=err`/other (read-only in PC mode → set live-view image size on the camera menu instead).

- [ ] **Step 2: Push toward 50fps**

If short of target, drop to QVGA: temporarily change the `start()` call in `_LiveViewPageState.initState` to `_stream.start(size: 1, compression: 0)`. Rebuild, re-read fps/jitter.

- [ ] **Step 3: Diagnose the wall**

Read avg frame KB and decode ms (add them to the overlay text if needed, e.g. append `· ${s.avgFrameKb.toStringAsFixed(0)}KB`). If transfer dominates (large KB) → shrink further / lower compression. If decode dominates → consider `targetWidth` downscale in `_decode`. If both are small but fps is still capped → the camera's LV rate or Wi-Fi RTT is the wall (record the finding).

- [ ] **Step 4: Record results**

Note achieved fps + jitter at VGA and QVGA, whether the camera accepted the property writes, and the dominant bottleneck, in the PR description / a follow-up note.

---

## Self-Review

**Spec coverage:**
- TCP_NODELAY → Task 1 ✓
- Data-out + configureLiveView (shrink) → Tasks 2–3 ✓
- Decoupled producer/consumer pipeline → Task 5 (producer) + Task 6 (vsync consumer) ✓
- fps + jitter instrumentation → Task 4 (compute) + Task 6 (overlay) ✓
- Image lifecycle / post-frame dispose → Task 5 `_publish` ✓
- Error handling (best-effort config, transient skip, surface persistent) → Task 3 `configureLiveView`, Task 5 `_loop`/`error` ✓
- On-device measurement + tuning → Task 7 ✓
- Codec/XGA-ceiling constraints → no code (documented in spec; honored by not attempting non-JPEG) ✓

**Placeholder scan:** none — every code step is complete.

**Type consistency:** `FrameSample{tMs,bytes,decodeMs}`, `LiveViewStats{fps,jitterMs,avgFrameKb,avgDecodeMs}`, `computeStats(List<FrameSample>, int, {windowMs})`, `LiveViewStream.{frame,stats,error,start,stop}`, `configureLiveView({size,compression})`, `PtpProp.liveViewImageSize/liveViewImageCompression`, `_transact({..., dataOut})` — used consistently across Tasks 3–6.
