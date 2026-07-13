import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'camera_props.dart';
import 'live_view.dart';
import 'live_view_stats.dart';
import 'ptp_constants.dart';
import 'ptp_ip_client.dart';
import 'socket_reader.dart';

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
  int _frameBudgetMs = 0; // ms per frame, paced to the camera's frame rate
  int _pendingSize = 2; // requested live-view image size; applied by the loop
  int _pendingCompression = 2; // requested compression; applied by the loop
  bool _qualityDirty = false;
  int _lastFpsCheckMs = 0; // last time the camera frame rate was re-read
  static const int _fpsRecheckMs = 2000; // cadence for re-reading camera fps
  static const int _maxConsecutiveErrors =
      30; // give up after this many in a row

  /// Decoded camera settings for the overlay (updated one field per poll tick).
  final ValueNotifier<CameraState> cameraState =
      ValueNotifier<CameraState>(const CameraState());

  // Property writes/describes to run at the safe point (one per tick).
  final List<Future<void> Function()> _commandQueue = [];

  int _pollCursor = 0; // round-robin index into _pollProps
  int _lastPollMs = 0; // last camera-property read time
  static const int _pollIntervalMs =
      200; // read one property at most this often
  static const List<int> _pollProps = [
    PtpProp.movieIsoSensitivity,
    PtpProp.movieBaseIso,
    PtpProp.movieShutterAngle,
    PtpProp.movieShutterSpeed,
    PtpProp.movieFnumber,
    PtpProp.movieWhiteBalance,
    PtpProp.movieWbColorTemp,
    PtpProp.movieRecordScreenSize,
    PtpProp.movieFileType,
    PtpProp.focalLength,
    PtpProp.lensFocalMin,
    PtpProp.lensFocalMax,
    PtpProp.lensApertureMin,
  ];

  /// Goes true once the loop gives up because the camera/connection dropped;
  /// the UI listens to this to leave the live-view screen automatically.
  final ValueNotifier<bool> disconnected = ValueNotifier<bool>(false);

  /// Frame-fetch deadline. A healthy stream returns frames every ~20–40 ms, so
  /// exceeding this means the camera is gone (e.g. powered off mid-stream),
  /// where the TCP socket may never see a FIN/RST and a read would hang.
  static const Duration _frameTimeout = Duration(seconds: 3);

  /// Configures the camera (best-effort), starts live view, and begins
  /// streaming. Safe to call once.
  Future<void> start({int size = 2, int compression = 2}) async {
    _pendingSize = size;
    _pendingCompression = compression;
    try {
      await client
          .configureLiveView(size: size, compression: compression)
          .timeout(_frameTimeout);
    } on Object {
      // Best-effort tuning; proceed at the camera defaults.
    }
    try {
      await client.startLiveView().timeout(_frameTimeout);
    } on Object catch (e) {
      _markDisconnected('Could not start live view: $e');
      return;
    }
    var fps = 0;
    try {
      fps = await client.readMovieFrameRate().timeout(_frameTimeout);
    } on Object {
      fps = 0;
    }
    _frameBudgetMs = fps > 0 ? (1000 / fps).round() : 33;
    _running = true;
    _clock.start();
    unawaited(_loop());
  }

  /// Requests a new live-view image [size] (1=QVGA, 2=VGA, 3=XGA) and
  /// [compression] (0..5). The change is applied by the loop at a safe point
  /// (no frame request in flight) so it never races the command socket.
  /// Best-effort — the camera may ignore these in "Connect to PC" mode.
  void setQuality({required int size, required int compression}) {
    _pendingSize = size;
    _pendingCompression = compression;
    _qualityDirty = true;
  }

  /// Queues a property write to run at the next safe point. [onError] receives
  /// the response/exception text if the camera rejects it (e.g. wrong mode).
  void setCameraProperty(
    int code,
    Uint8List value, {
    void Function(String)? onError,
  }) {
    _commandQueue.add(() async {
      try {
        await client.setProperty(code, value).timeout(_frameTimeout);
      } on Object catch (e) {
        onError?.call(e.toString());
      }
    });
  }

  /// Queues a DevicePropDesc read at the next safe point; resolves to its parsed
  /// enum value list (empty if the camera exposes no enum form or it fails).
  Future<List<int>> describeEnum(int code, {required int valueBytes}) {
    final completer = Completer<List<int>>();
    _commandQueue.add(() async {
      try {
        final raw = await client.describeProperty(code).timeout(_frameTimeout);
        completer
            .complete(parseDevicePropDescEnum(raw, valueBytes: valueBytes));
      } on Object {
        completer.complete(const []);
      }
    });
    return completer.future;
  }

  /// Runs while the command socket is idle (between frames): applies a pending
  /// quality change and periodically re-reads the camera's movie frame rate so
  /// vsync pacing follows a mid-session capture-fps change.
  Future<void> _maybeReconfigure() async {
    if (_commandQueue.isNotEmpty) {
      final op = _commandQueue.removeAt(0);
      await op();
      return; // one command per safe point; reconfigure/poll resume next tick
    }
    if (_qualityDirty) {
      _qualityDirty = false;
      try {
        await client
            .configureLiveView(
              size: _pendingSize,
              compression: _pendingCompression,
            )
            .timeout(_frameTimeout);
      } on Object {
        // best-effort; keep streaming at whatever the camera accepted
      }
    }
    final now = _clock.elapsedMilliseconds;
    if (now - _lastFpsCheckMs >= _fpsRecheckMs) {
      _lastFpsCheckMs = now;
      try {
        final fps = await client.readMovieFrameRate().timeout(_frameTimeout);
        if (fps > 0) _frameBudgetMs = (1000 / fps).round();
      } on Object {
        // keep the previous budget
      }
    }
    if (now - _lastPollMs >= _pollIntervalMs) {
      _lastPollMs = now;
      await _pollOneProperty();
    }
  }

  Future<void> _pollOneProperty() async {
    final code = _pollProps[_pollCursor];
    _pollCursor = (_pollCursor + 1) % _pollProps.length;
    try {
      final bytes = await client.getProperty(code).timeout(_frameTimeout);
      final bd = ByteData.sublistView(bytes);
      final s = cameraState.value;
      switch (code) {
        case PtpProp.movieIsoSensitivity:
          cameraState.value = s.copyWith(iso: bd.getUint32(0, Endian.little));
        case PtpProp.movieBaseIso:
          cameraState.value =
              s.copyWith(baseIso: decodeBaseIso(bd.getUint8(0)));
        case PtpProp.movieShutterAngle:
          cameraState.value = s.copyWith(
            shutterAngle: decodeShutterAngle(bd.getInt32(0, Endian.little)),
          );
        case PtpProp.movieShutterSpeed:
          cameraState.value = s.copyWith(
            shutterSpeed: decodeShutterSpeed(bd.getUint32(0, Endian.little)),
          );
        case PtpProp.movieFnumber:
          cameraState.value = s.copyWith(
            fnumber: decodeFnumber(bd.getUint16(0, Endian.little)),
          );
        case PtpProp.movieWhiteBalance:
          cameraState.value =
              s.copyWith(wbMode: decodeWbMode(bd.getUint16(0, Endian.little)));
        case PtpProp.movieWbColorTemp:
          cameraState.value =
              s.copyWith(wbKelvin: bd.getUint16(0, Endian.little));
        case PtpProp.movieRecordScreenSize:
          final ss = decodeScreenSize(bd.getUint64(0, Endian.little));
          cameraState.value = s.copyWith(resolution: ss.label, fps: ss.fps);
        case PtpProp.movieFileType:
          cameraState.value = s.copyWith(
            fileType: decodeFileType(bd.getUint32(0, Endian.little)),
          );
        case PtpProp.focalLength:
          cameraState.value = s.copyWith(
            focalLength: decodeFocalLengthMm(bd.getUint32(0, Endian.little)),
          );
        case PtpProp.lensFocalMin:
          cameraState.value =
              s.copyWith(focalMin: bd.getUint32(0, Endian.little));
        case PtpProp.lensFocalMax:
          cameraState.value =
              s.copyWith(focalMax: bd.getUint32(0, Endian.little));
        case PtpProp.lensApertureMin:
          cameraState.value =
              s.copyWith(apertureWide: bd.getUint16(0, Endian.little));
      }
    } on Object {
      // Unsupported/unreadable property in this mode — leave the prior value.
    }
  }

  Future<void> _loop() async {
    var next = client.liveViewFrame();
    var consecutiveErrors = 0;
    while (_running) {
      final iterStart = _clock.elapsedMilliseconds;

      final LiveViewFrame frame;
      try {
        frame = await next.timeout(_frameTimeout);
      } on Object catch (e) {
        // Fetch failed: no new request is in flight yet. A timeout or socket
        // error means the camera is gone; anything else (e.g. a malformed
        // LiveViewObject) is a transient frame error — drop it and retry.
        if (!_running) break;
        if (_isTerminalError(e) ||
            ++consecutiveErrors >= _maxConsecutiveErrors) {
          _markDisconnected('Connection lost: $e');
          break;
        }
        next = client.liveViewFrame();
        continue;
      }
      cameraState.value = cameraState.value.copyWith(timecode: frame.timecode);
      final jpeg = frame.jpeg;

      if (!_running) break;
      await _maybeReconfigure();
      if (!_running) break;
      next = client.liveViewFrame(); // pipeline: request N+1 before decoding N

      final decodeStart = _clock.elapsedMilliseconds;
      final ui.Image image;
      try {
        image = await _decode(jpeg);
      } on Object {
        // Corrupt/partial JPEG (transient, or a transitional frame during a
        // resolution switch). Drop it and keep streaming — `next` is already in
        // flight, so do NOT issue another request here.
        if (!_running) break;
        if (++consecutiveErrors >= _maxConsecutiveErrors) {
          _markDisconnected('Live view stalled (unreadable frames)');
          break;
        }
        continue;
      }
      consecutiveErrors = 0;

      final tMs = _clock.elapsedMilliseconds;
      _publish(
        image,
        FrameSample(tMs: tMs, bytes: jpeg.length, decodeMs: tMs - decodeStart),
      );
      final wait = _frameBudgetMs - (_clock.elapsedMilliseconds - iterStart);
      if (wait > 0) {
        await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
    next.ignore(); // a still-pending read may resolve/err later; don't leak it
    // Bounded teardown: a dead socket must not hang the request.
    unawaited(
      client.stopLiveView().timeout(_frameTimeout).catchError((_) {}),
    );
  }

  /// Whether a frame-fetch error means the connection is dead (vs. a one-off
  /// bad frame that should just be skipped).
  bool _isTerminalError(Object e) =>
      e is TimeoutException ||
      e is SocketException ||
      e is SocketReaderClosedException;

  void _markDisconnected(String message) {
    error.value = message;
    _running = false;
    disconnected.value = true;
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
      WidgetsBinding.instance.addPostFrameCallback((_) => replaced.dispose());
    }
  }

  /// Stops streaming and live view (best-effort). The loop drains its in-flight
  /// request before tearing down.
  Future<void> stop() async {
    _running = false;
  }
}
