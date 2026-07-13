# Camera Control Panel (Live-View Overlay) Implementation Plan

**Goal:** A live-view overlay that displays and (Stage 2) adjusts the Nikon ZR's video shooting settings — ISO, shutter (angle/speed), F-stop, WB + Kelvin, focal length, lens, resolution, format, framerate, timecode — over PTP-IP.

**Architecture:** All camera I/O is serialized through the live-view loop's existing safe point (one transaction per frame: a queued write, else the next round-robin read). Pure decoders/encoders convert PTP bytes ↔ display values. Timecode is parsed free from each frame's LiveViewObject header. A `ValueNotifier<CameraState>` feeds the overlay.

**Tech Stack:** Dart/Flutter, existing `PtpIpClient` (New-API `GetDevicePropValueEx 0x943B` / `SetDevicePropValueEx 0x943C` / `GetDevicePropDescEx 0x943A`), `LiveViewStream`.

**Spec:** `docs/design/specs/2026-06-15-camera-control-panel-design.md`
**Wireframe follow-up:** `docs/design/plans/2026-06-20-wireframe-kit-app.md` moves this debug-style
overlay work into the Penpot monitor shell, bottom value strip, Command mode cards, and transient
picker panels.
**Production-stack note:** Treat this as the Flutter prototype plan. Production should port pure
property/state logic into the shared Swift core and rebuild the UI in SwiftUI and Jetpack Compose.

**Commits:** This project **batches commits** — do NOT commit per task. End each task with the checkpoint (`flutter analyze` + `flutter test` clean, `just check` for doc/meta tasks). The whole arc is committed in one pass when the user asks.

**Property codes** (`lib/ptp_ip/ptp_constants.dart` — add to `PtpProp` in Task 1):
`isoControlSensitivity=0xd0b5`, `movieShutterSpeed=0xd1a8`, `movieShutterAngle=0x0001d075`,
`movieFnumber=0xd1a9`, `movieWhiteBalance=0xd23a`, `movieWbColorTemp=0xd21a`,
`movieFileType=0xd0af`, `focalLength=0x5008`, `lensId=0xd0e0` (plus existing
`movieRecordScreenSize=0xd0a0`).

---

## Stage 1 — Read-only

### Task 1: Property-code constants

**Files:**
- Modify: `lib/ptp_ip/ptp_constants.dart` (the `PtpProp` class)

- [ ] **Step 1: Add the constants** to `PtpProp` (after `movieRecordScreenSize`):

```dart
  /// `ISOControlSensitivity` — UINT32, the effective ISO the camera is applying.
  static const int isoControlSensitivity = 0xd0b5;

  /// `MovieShutterSpeed` — UINT32; upper 16b numerator, lower 16b denominator.
  static const int movieShutterSpeed = 0xd1a8;

  /// `MovieShutterAngle` — INT32 cine shutter angle ×100 (18000 = 180°).
  static const int movieShutterAngle = 0x0001d075;

  /// `MovieFnumber` — UINT16 aperture ×100 (280 = f/2.8).
  static const int movieFnumber = 0xd1a9;

  /// `MovieWhiteBalance` — UINT16 WB-mode enum.
  static const int movieWhiteBalance = 0xd23a;

  /// `MovieWbColorTemp` — UINT16 white-balance colour temperature in Kelvin.
  static const int movieWbColorTemp = 0xd21a;

  /// `MovieFileType` — UINT32; packs codec, bit-depth, container.
  static const int movieFileType = 0xd0af;

  /// `FocalLength` — UINT32 current focal length in mm ×100 (read-only).
  static const int focalLength = 0x5008;

  /// `LensID` — UINT32 attached-lens identification code (read-only).
  static const int lensId = 0xd0e0;
```

- [ ] **Step 2: Checkpoint** — `flutter analyze` → "No issues found!"

### Task 2: Timecode parser

**Files:**
- Modify: `lib/ptp_ip/live_view.dart`
- Test: `test/ptp_ip/live_view_test.dart` (append)

The LiveViewObject header carries timecode at byte offsets: 831 = status (0=off, 1=on), 832=hour, 833=minute, 834=second, 835=frame.

- [ ] **Step 1: Write the failing test** (append to `test/ptp_ip/live_view_test.dart`):

```dart
  group('parseTimecode', () {
    test('reads HH:MM:SS:FF and on-flag from the header', () {
      final obj = Uint8List(liveViewHeaderLength + 3);
      obj[831] = 1; // on
      obj[832] = 1; // hour
      obj[833] = 23; // min
      obj[834] = 45; // sec
      obj[835] = 12; // frame
      final tc = parseTimecode(obj);
      expect(tc.on, true);
      expect(tc.label, '01:23:45:12');
    });

    test('returns off when the status byte is 0', () {
      final tc = parseTimecode(Uint8List(liveViewHeaderLength + 3));
      expect(tc.on, false);
    });

    test('returns off when the object is too short', () {
      expect(parseTimecode(Uint8List(10)).on, false);
    });
  });
```

- [ ] **Step 2: Run it, expect FAIL** — `flutter test test/ptp_ip/live_view_test.dart` → "parseTimecode" undefined.

- [ ] **Step 3: Implement** (append to `lib/ptp_ip/live_view.dart`):

```dart
/// Movie timecode decoded from a LiveViewObject header.
class Timecode {
  const Timecode({
    required this.on,
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
    this.frame = 0,
  });

  /// Whether the camera reports timecode active.
  final bool on;
  final int hour;
  final int minute;
  final int second;
  final int frame;

  /// `HH:MM:SS:FF`.
  String get label => '${_p(hour)}:${_p(minute)}:${_p(second)}:${_p(frame)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}

/// Parses the movie [Timecode] from a LiveViewObject header (offsets 831–835).
/// Tolerant: returns an off timecode if the object is too short.
Timecode parseTimecode(Uint8List liveViewObject) {
  if (liveViewObject.length < 836) return const Timecode(on: false);
  return Timecode(
    on: liveViewObject[831] == 1,
    hour: liveViewObject[832],
    minute: liveViewObject[833],
    second: liveViewObject[834],
    frame: liveViewObject[835],
  );
}
```

- [ ] **Step 4: Run it, expect PASS** — `flutter test test/ptp_ip/live_view_test.dart`.

### Task 3: Numeric setting decoders + CameraState

**Files:**
- Create: `lib/ptp_ip/camera_props.dart`
- Test: `test/ptp_ip/camera_props_test.dart`

- [ ] **Step 1: Write the failing test**:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:openzcine/ptp_ip/camera_props.dart';

void main() {
  test('decodeFnumber: 280 -> f/2.8', () {
    expect(decodeFnumber(280), 'f/2.8');
  });
  test('decodeShutterSpeed: 1/60, 1/250, 25s', () {
    expect(decodeShutterSpeed(0x0001003C), '1/60');
    expect(decodeShutterSpeed(0x000100FA), '1/250');
    expect(decodeShutterSpeed(0x00190001), '25s');
  });
  test('decodeShutterAngle: 18000 -> 180°', () {
    expect(decodeShutterAngle(18000), '180°');
    expect(decodeShutterAngle(17280), '172.8°');
  });
  test('decodeFocalLengthMm: 5000 -> 50 mm', () {
    expect(decodeFocalLengthMm(5000), '50 mm');
  });
}
```

- [ ] **Step 2: Run it, expect FAIL** — `flutter test test/ptp_ip/camera_props_test.dart`.

- [ ] **Step 3: Implement** `lib/ptp_ip/camera_props.dart`:

```dart
import 'live_view.dart' show Timecode;

/// Aperture: UINT16 f-number ×100 → `f/2.8`. 0xFFFF = error.
String decodeFnumber(int raw) {
  if (raw == 0xFFFF) return '—';
  final f = raw / 100.0;
  final s = f.toStringAsFixed(1);
  return 'f/${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}';
}

/// Shutter: UINT32, upper 16b numerator / lower 16b denominator.
String decodeShutterSpeed(int raw) {
  final num = (raw >> 16) & 0xFFFF;
  final den = raw & 0xFFFF;
  if (den == 0) return '—';
  if (den == 1) return '${num}s';
  if (num == 1) return '1/$den';
  return '$num/$den';
}

/// Cine shutter angle: INT32 angle ×100 → `180°`.
String decodeShutterAngle(int raw) {
  final deg = raw / 100.0;
  final s = deg.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}°';
}

/// Focal length: UINT32 mm ×100 → `50 mm`.
String decodeFocalLengthMm(int raw) {
  final mm = raw / 100.0;
  final s = mm.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} mm';
}
```

- [ ] **Step 4: Run it, expect PASS**.

### Task 4: Packed-enum decoders (resolution/framerate, format) + WB

**Files:**
- Modify: `lib/ptp_ip/camera_props.dart`
- Test: `test/ptp_ip/camera_props_test.dart` (append)

- [ ] **Step 1: Write the failing test** (append inside `main`):

```dart
  test('decodeScreenSize: 0x0F000870001E0000 -> 3840x2160 + 30 fps', () {
    final m = decodeScreenSize(0x0F000870001E0000);
    expect(m.width, 3840);
    expect(m.height, 2160);
    expect(m.fps, 30);
    expect(m.label, '3840×2160');
  });
  test('decodeFileType: 0x00010800 -> H.265 8-bit MOV', () {
    expect(decodeFileType(0x00010800), 'H.265 8-bit MOV');
    expect(decodeFileType(0x00100A00), 'ProRes 422 HQ 10-bit MOV');
  });
  test('decodeWbMode maps known modes, falls back to hex', () {
    expect(decodeWbMode(0x0002), 'Auto');
    expect(decodeWbMode(0x8012), 'Color temp');
    expect(decodeWbMode(0x1234), '0x1234');
  });
```

- [ ] **Step 2: Run it, expect FAIL**.

- [ ] **Step 3: Implement** (append to `lib/ptp_ip/camera_props.dart`):

```dart
/// Decoded `MovieRecordScreenSize` (0xD0A0): resolution + frame rate.
class ScreenSize {
  const ScreenSize({required this.width, required this.height, required this.fps});
  final int width;
  final int height;
  final int fps;
  String get label => '$width×$height';
}

/// Unpacks `MovieRecordScreenSize` UINT64: bits 48–63 H-res, 32–47 V-res,
/// 16–23 fps (integer).
ScreenSize decodeScreenSize(int raw) => ScreenSize(
      width: (raw >> 48) & 0xFFFF,
      height: (raw >> 32) & 0xFFFF,
      fps: (raw >> 16) & 0xFF,
    );

const Map<int, String> _codecNames = {
  0x00: 'H.264',
  0x01: 'H.265',
  0x02: 'N-RAW',
  0x10: 'ProRes 422 HQ',
  0x11: 'ProRes RAW HQ',
  0x31: 'R3D NE',
};
const Map<int, String> _containerNames = {0: 'MOV', 1: 'MP4', 2: 'NEV', 3: 'R3D'};

/// Unpacks `MovieFileType` UINT32: bits 16–23 codec, 8–15 bit-depth, 0–7 container.
String decodeFileType(int raw) {
  final codec = _codecNames[(raw >> 16) & 0xFF] ?? '0x${((raw >> 16) & 0xFF).toRadixString(16)}';
  final depth = (raw >> 8) & 0xFF;
  final container = _containerNames[raw & 0xFF] ?? '0x${(raw & 0xFF).toRadixString(16)}';
  return '$codec $depth-bit $container';
}

const Map<int, String> _wbModeNames = {
  0x0002: 'Auto',
  0x0004: 'Sunny',
  0x0005: 'Fluorescent',
  0x0006: 'Incandescent',
  0x0007: 'Flash',
  0x8010: 'Cloudy',
  0x8011: 'Shade',
  0x8012: 'Color temp',
  0x8013: 'Preset',
  0x8016: 'Natural auto',
};

/// `MovieWhiteBalance`/`WhiteBalance` UINT16 mode → label, else hex.
String decodeWbMode(int raw) =>
    _wbModeNames[raw] ?? '0x${raw.toRadixString(16)}';
```

- [ ] **Step 4: Run it, expect PASS**.

### Task 5: CameraState snapshot

**Files:**
- Modify: `lib/ptp_ip/camera_props.dart`
- Test: `test/ptp_ip/camera_props_test.dart` (append)

- [ ] **Step 1: Write the failing test**:

```dart
  test('CameraState.copyWith replaces one field, keeps the rest', () {
    const a = CameraState(iso: 800, fnumber: 'f/2.8');
    final b = a.copyWith(fnumber: 'f/4');
    expect(b.iso, 800);
    expect(b.fnumber, 'f/4');
  });
```

- [ ] **Step 2: Run it, expect FAIL**.

- [ ] **Step 3: Implement** (append):

```dart
/// Immutable snapshot of the camera's decoded settings for the overlay. Each
/// round-robin read replaces one field via [copyWith].
class CameraState {
  const CameraState({
    this.iso,
    this.shutterSpeed,
    this.shutterAngle,
    this.fnumber,
    this.wbMode,
    this.wbKelvin,
    this.resolution,
    this.fps,
    this.fileType,
    this.focalLength,
    this.lens,
    this.timecode,
  });

  final int? iso;
  final String? shutterSpeed;
  final String? shutterAngle;
  final String? fnumber;
  final String? wbMode;
  final int? wbKelvin;
  final String? resolution;
  final int? fps;
  final String? fileType;
  final String? focalLength;
  final String? lens;
  final Timecode? timecode;

  CameraState copyWith({
    int? iso,
    String? shutterSpeed,
    String? shutterAngle,
    String? fnumber,
    String? wbMode,
    int? wbKelvin,
    String? resolution,
    int? fps,
    String? fileType,
    String? focalLength,
    String? lens,
    Timecode? timecode,
  }) =>
      CameraState(
        iso: iso ?? this.iso,
        shutterSpeed: shutterSpeed ?? this.shutterSpeed,
        shutterAngle: shutterAngle ?? this.shutterAngle,
        fnumber: fnumber ?? this.fnumber,
        wbMode: wbMode ?? this.wbMode,
        wbKelvin: wbKelvin ?? this.wbKelvin,
        resolution: resolution ?? this.resolution,
        fps: fps ?? this.fps,
        fileType: fileType ?? this.fileType,
        focalLength: focalLength ?? this.focalLength,
        lens: lens ?? this.lens,
        timecode: timecode ?? this.timecode,
      );
}
```

- [ ] **Step 4: Run it, expect PASS**.

### Task 6: `getProperty` + frame-with-header fetch

**Files:**
- Modify: `lib/ptp_ip/ptp_ip_client.dart`

- [ ] **Step 1: Add `getProperty`** (after `liveViewFrameJpeg`, mirrors `readMovieFrameRate`):

```dart
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
```

- [ ] **Step 2: Add a header-preserving frame fetch.** Add `LiveViewFrame` to `lib/ptp_ip/live_view.dart`:

```dart
/// A fetched LiveViewObject split into its header and JPEG.
class LiveViewFrame {
  const LiveViewFrame({required this.jpeg, required this.timecode});
  final Uint8List jpeg;
  final Timecode timecode;
}
```

Add `liveViewFrame` to `ptp_ip_client.dart` and make the existing `liveViewFrameJpeg`
**delegate** to it (keeps any internal probe callers working — do NOT delete it):

```dart
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
```

- [ ] **Step 3: Checkpoint** — `flutter analyze`. Expect errors in `live_view_stream.dart` (still calls `liveViewFrameJpeg`); fixed in Task 7.

### Task 7: Loop-routed round-robin poll

**Files:**
- Modify: `lib/ptp_ip/live_view_stream.dart`

- [ ] **Step 1: Add state + the poll.** Add imports `import 'camera_props.dart';` and `import 'live_view.dart';`. Add fields:

```dart
  /// Decoded camera settings for the overlay (updated one field at a time).
  final ValueNotifier<CameraState> cameraState =
      ValueNotifier<CameraState>(const CameraState());

  // Round-robin cursor over the read-only property set.
  int _pollCursor = 0;
  static const List<int> _pollProps = [
    PtpProp.isoControlSensitivity,
    PtpProp.movieShutterAngle,
    PtpProp.movieShutterSpeed,
    PtpProp.movieFnumber,
    PtpProp.movieWhiteBalance,
    PtpProp.movieWbColorTemp,
    PtpProp.movieRecordScreenSize,
    PtpProp.movieFileType,
    PtpProp.focalLength,
    PtpProp.lensId,
  ];
```

(Add `import 'ptp_constants.dart';` if not present.)

- [ ] **Step 2: Read one property per safe point.** In `_maybeReconfigure`, after the fps re-check block, append:

```dart
    await _pollOneProperty();
```

and add the method:

```dart
  Future<void> _pollOneProperty() async {
    final code = _pollProps[_pollCursor];
    _pollCursor = (_pollCursor + 1) % _pollProps.length;
    try {
      final bytes = await client.getProperty(code).timeout(_frameTimeout);
      final bd = ByteData.sublistView(bytes);
      final s = cameraState.value;
      switch (code) {
        case PtpProp.isoControlSensitivity:
          cameraState.value = s.copyWith(iso: bd.getUint32(0, Endian.little));
        case PtpProp.movieShutterAngle:
          cameraState.value =
              s.copyWith(shutterAngle: decodeShutterAngle(bd.getInt32(0, Endian.little)));
        case PtpProp.movieShutterSpeed:
          cameraState.value =
              s.copyWith(shutterSpeed: decodeShutterSpeed(bd.getUint32(0, Endian.little)));
        case PtpProp.movieFnumber:
          cameraState.value =
              s.copyWith(fnumber: decodeFnumber(bd.getUint16(0, Endian.little)));
        case PtpProp.movieWhiteBalance:
          cameraState.value =
              s.copyWith(wbMode: decodeWbMode(bd.getUint16(0, Endian.little)));
        case PtpProp.movieWbColorTemp:
          cameraState.value = s.copyWith(wbKelvin: bd.getUint16(0, Endian.little));
        case PtpProp.movieRecordScreenSize:
          final ss = decodeScreenSize(bd.getUint64(0, Endian.little));
          cameraState.value = s.copyWith(resolution: ss.label, fps: ss.fps);
        case PtpProp.movieFileType:
          cameraState.value =
              s.copyWith(fileType: decodeFileType(bd.getUint32(0, Endian.little)));
        case PtpProp.focalLength:
          cameraState.value =
              s.copyWith(focalLength: decodeFocalLengthMm(bd.getUint32(0, Endian.little)));
        case PtpProp.lensId:
          cameraState.value = s.copyWith(lens: 'Lens #${bd.getUint32(0, Endian.little)}');
      }
    } on Object {
      // Unsupported/unreadable property in this mode — leave prior value.
    }
  }
```

- [ ] **Step 3: Switch the loop to `liveViewFrame()`** and publish timecode. In `_loop`, change the fetch and decode:

Replace `var next = client.liveViewFrameJpeg();` → `var next = client.liveViewFrame();`
Replace `next = client.liveViewFrameJpeg();` (both occurrences) → `next = client.liveViewFrame();`
Change `Uint8List jpeg;` / `jpeg = await next...` to:

```dart
      final LiveViewFrame frame;
      try {
        frame = await next.timeout(_frameTimeout);
      } on Object catch (e) {
        // ... unchanged terminal/transient handling, but: next = client.liveViewFrame();
      }
      cameraState.value = cameraState.value.copyWith(timecode: frame.timecode);
      final jpeg = frame.jpeg;
```

(`_decode(jpeg)` and `FrameSample(bytes: jpeg.length, …)` stay the same.)

- [ ] **Step 4: Checkpoint** — `flutter analyze` clean; `flutter test` all pass.

### Task 8: Read-only overlay panel

**Files:**
- Create: `lib/camera_panel.dart`
- Modify: `lib/live_view_page.dart`

- [ ] **Step 1: Implement `lib/camera_panel.dart`**:

```dart
import 'package:flutter/material.dart';

import 'ptp_ip/camera_props.dart';
import 'ptp_ip/live_view_stream.dart';

/// Collapsible overlay showing the camera's live settings (read-only, Stage 1).
class CameraPanel extends StatelessWidget {
  const CameraPanel({required this.stream, super.key});

  final LiveViewStream stream;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraState>(
      valueListenable: stream.cameraState,
      builder: (context, s, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('TC', s.timecode?.on == true ? s.timecode!.label : '—'),
              _row('ISO', s.iso?.toString() ?? '—'),
              _row('Shutter', s.shutterAngle ?? s.shutterSpeed ?? '—'),
              _row('Aperture', s.fnumber ?? '—'),
              _row('WB', _wb(s)),
              _row('Lens', s.lens ?? '—'),
              _row('Focal', s.focalLength ?? '—'),
              _row('Rec', _rec(s)),
              _row('Format', s.fileType ?? '—'),
            ],
          ),
        ),
      ),
    );
  }

  static String _wb(CameraState s) {
    if (s.wbMode == null) return '—';
    return s.wbKelvin != null ? '${s.wbMode} · ${s.wbKelvin}K' : s.wbMode!;
  }

  static String _rec(CameraState s) {
    if (s.resolution == null) return '—';
    return s.fps != null ? '${s.resolution} · ${s.fps}p' : s.resolution!;
  }

  static Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 64,
              child: Text(label,
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ),
            Text(value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        ),
      );
}
```

- [ ] **Step 2: Host it in `live_view_page.dart`.** Add `import 'camera_panel.dart';`, a `bool _showInfo = false;` field, an info toggle button in the top-right overlay `Column` (above the resolution dropdown):

```dart
                        IconButton(
                          icon: Icon(_showInfo ? Icons.info : Icons.info_outline,
                              color: Colors.white),
                          tooltip: 'Camera info',
                          onPressed: () => setState(() => _showInfo = !_showInfo),
                        ),
```

and, inside the `SafeArea` `Stack`, a bottom-left panel:

```dart
                if (_showInfo)
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: CameraPanel(stream: _stream),
                    ),
                  ),
```

- [ ] **Step 3: Checkpoint** — `flutter analyze` clean; `flutter test` all pass; `just check` exit 0.

**Stage 1 on-device validation (before Stage 2):** open live view → toggle Camera info → confirm ISO/shutter/aperture/WB/lens/focal/resolution/format/timecode show plausible values and update live. Note any property that reads `—` (unsupported over Wi-Fi in this mode) — that informs Stage 2.

---

## Stage 2 — Adjust

> Tasks below add the write path. The `describeProperty` byte layout and per-property
> settability are `[VERIFY-ON-HW]`; confirm with Stage 1's on-device results first.

### Task 9: Encoders

**Files:**
- Modify: `lib/ptp_ip/camera_props.dart`
- Test: `test/ptp_ip/camera_props_test.dart` (append)

- [ ] **Step 1: Write the failing test**:

```dart
  test('encodeUint16/encodeUint32 little-endian', () {
    expect(encodeUint16(280), [0x18, 0x01]);
    expect(encodeUint32(5000), [0x88, 0x13, 0x00, 0x00]);
  });
  test('encodeFnumber: 2.8 -> 280 LE', () {
    expect(encodeFnumber(2.8), [0x18, 0x01]);
  });
```

- [ ] **Step 2: Run it, expect FAIL**.

- [ ] **Step 3: Implement** (append to `camera_props.dart`):

```dart
import 'dart:typed_data';

Uint8List encodeUint16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();

Uint8List encodeUint32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

Uint8List encodeUint64(int v) =>
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

/// f-number (e.g. 2.8) → UINT16 ×100 little-endian.
Uint8List encodeFnumber(double f) => encodeUint16((f * 100).round());
```

(Move the existing `import 'live_view.dart' show Timecode;` to sit with the new `dart:typed_data` import at the top.)

- [ ] **Step 4: Run it, expect PASS**.

### Task 10: `setProperty` + `describeProperty`

**Files:**
- Modify: `lib/ptp_ip/ptp_ip_client.dart`

- [ ] **Step 1: Add `setProperty`** (mirrors `configureLiveView`'s data-out path):

```dart
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
```

- [ ] **Step 2: Add `describeProperty`** (best-effort enum extraction; `[VERIFY-ON-HW]`):

```dart
  /// Best-effort read of a property's currently-supported enum values via
  /// GetDevicePropDescEx (0x943A). Returns an empty list if the form is a range
  /// or the layout can't be parsed. The exact New-API DevicePropDesc offsets are
  /// hardware-unconfirmed; callers must tolerate an empty result.
  Future<List<int>> describePropertyEnum(int code, {required int valueBytes}) async {
    final (resp, data) = await _transact(
      code: PtpOp.getDevicePropDescEx,
      transactionId: _nextTransactionId++,
      params: [code],
      dataPhase: DataPhase.dataIn,
    );
    if (resp.code != PtpResponse.ok) return const [];
    return parseDevicePropDescEnum(data, valueBytes: valueBytes);
  }
```

Add the pure parser to `lib/ptp_ip/camera_props.dart` with its own test in Task 11.

- [ ] **Step 3: Checkpoint** — `flutter analyze` clean.

### Task 11: DevicePropDesc enum parser

**Files:**
- Modify: `lib/ptp_ip/camera_props.dart`
- Test: `test/ptp_ip/camera_props_test.dart` (append)

The PTP DevicePropDesc enum form ends with: FormFlag (0x02 = enum), UINT16 count, then `count` values of `valueBytes` each. We scan from the end of the buffer (robust to the unconfirmed header size): read the trailing enum array.

- [ ] **Step 1: Write the failing test**:

```dart
  test('parseDevicePropDescEnum reads a trailing UINT16 enum array', () {
    // ...header... formFlag=0x02, count=3, values [1,2,3] as UINT16 LE
    final b = BytesBuilder()
      ..add([0, 0, 0, 0]) // opaque header stand-in
      ..add([0x02]) // form flag = enum
      ..add([0x03, 0x00]) // count = 3
      ..add([0x01, 0x00, 0x02, 0x00, 0x03, 0x00]);
    expect(parseDevicePropDescEnum(b.toBytes(), valueBytes: 2), [1, 2, 3]);
  });
  test('parseDevicePropDescEnum returns empty when count/size mismatch', () {
    expect(parseDevicePropDescEnum(Uint8List.fromList([0x02, 0x05, 0x00]), valueBytes: 2), isEmpty);
  });
```

- [ ] **Step 2: Run it, expect FAIL**.

- [ ] **Step 3: Implement** (append to `camera_props.dart`):

```dart
/// Extracts the enum value array from a DevicePropDesc data blob, located by its
/// trailing `formFlag(0x02) + count(UINT16) + count×valueBytes` tail. Returns an
/// empty list if the tail doesn't match (range form, or unexpected layout).
List<int> parseDevicePropDescEnum(Uint8List data, {required int valueBytes}) {
  for (var i = 0; i + 3 <= data.length; i++) {
    if (data[i] != 0x02) continue;
    final count = data[i + 1] | (data[i + 2] << 8);
    final start = i + 3;
    if (count > 0 && start + count * valueBytes == data.length) {
      final bd = ByteData.sublistView(data, start);
      return [
        for (var k = 0; k < count; k++)
          valueBytes == 2
              ? bd.getUint16(k * 2, Endian.little)
              : bd.getUint32(k * valueBytes, Endian.little),
      ];
    }
  }
  return const [];
}
```

- [ ] **Step 4: Run it, expect PASS**.

### Task 12: Write queue in the stream

**Files:**
- Modify: `lib/ptp_ip/live_view_stream.dart`

- [ ] **Step 1: Add the queue + enqueue API**:

```dart
  final List<({int code, Uint8List value})> _writeQueue = [];

  /// Queues a property write to run at the next safe point. [onError] is called
  /// with the response/exception string if the camera rejects it.
  void setCameraProperty(int code, Uint8List value, {void Function(String)? onError}) {
    _writeQueue.add((code: code, value: value));
    _lastWriteError = onError;
  }

  void Function(String)? _lastWriteError;
```

- [ ] **Step 2: Drain a write before polling.** At the START of `_maybeReconfigure`, before the quality/fps blocks, add:

```dart
    if (_writeQueue.isNotEmpty) {
      final w = _writeQueue.removeAt(0);
      try {
        await client.setProperty(w.code, w.value).timeout(_frameTimeout);
      } on Object catch (e) {
        _lastWriteError?.call(e.toString());
      }
      return; // re-read happens on the next round-robin tick
    }
```

- [ ] **Step 3: Checkpoint** — `flutter analyze` clean; `flutter test` pass.

### Task 13: Editable controls in the panel

**Files:**
- Modify: `lib/camera_panel.dart`
- Modify: `lib/live_view_page.dart` (pass enum option sets)

- [ ] **Step 1: Make rows editable.** Convert `CameraPanel` to a `StatefulWidget` that, for each settable row, shows a stepper (ISO ±, Kelvin ±100, F-stop ±, shutter speed cycle) or a dropdown (resolution/format/framerate/WB) whose options come from `describePropertyEnum` (fetched once when the panel opens via `stream`-routed calls — enqueue describe through the same safe point or call while paused). On change call:

```dart
    stream.setCameraProperty(
      PtpProp.movieFnumber,
      encodeFnumber(newF),
      onError: (msg) => setState(() => _note = 'Aperture: $msg'),
    );
```

Show `_note` (e.g. "needs A/M mode") inline under the row; clear it on the next successful read.

- [ ] **Step 2: Checkpoint** — `flutter analyze` clean; `flutter test` pass; `just check` exit 0.

**Stage 2 on-device validation:** for each settable field, change it in the panel and confirm the camera applies it (and that rejected writes in the wrong A/S/M mode show the inline note rather than crashing).

### Task 14: Final verification

- [ ] `dart format .`
- [ ] `flutter analyze` → "No issues found!"
- [ ] `flutter test` → all pass
- [ ] `just check` → exit 0
