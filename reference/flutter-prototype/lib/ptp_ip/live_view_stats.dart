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
