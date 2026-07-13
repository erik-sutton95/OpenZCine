import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/live_view_stats.dart';

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
    const samples = <FrameSample>[
      FrameSample(tMs: 100, bytes: 1, decodeMs: 0),
      FrameSample(tMs: 120, bytes: 1, decodeMs: 0), // 20ms gap
      FrameSample(tMs: 320, bytes: 1, decodeMs: 0), // 200ms gap
    ];
    expect(computeStats(samples, 320).jitterMs, greaterThan(0));
  });

  test('computeStats: drops samples outside the 1s window', () {
    const samples = <FrameSample>[
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
