# Camera Control Panel (Live-View Overlay) — Design

**Date:** 2026-06-15
**Status:** Approved (verbal), pending spec review
**Author:** Claude Code (with Erik Sutton)
**Wireframe alignment:** See
`docs/design/specs/2026-06-20-wireframe-kit-app-design.md` for the broader monitor shell, `DISP`
modes, picker panels, assist toolbar, and settings model that this camera-control work should plug
into.
**Production-stack note:** This Flutter/Dart spec now describes prototype behavior to preserve and
port. Production implementation should move the pure protocol/state logic into the shared Swift core
and implement UI surfaces in SwiftUI and Jetpack Compose.

## Goal

A camera info + control panel overlaid on the live-view screen that **displays** and
(where the camera allows) **adjusts** the key shooting settings of the Nikon ZR over
PTP-IP: ISO, shutter (angle or speed), F-stop, white balance (+ Kelvin), focal length,
attached lens, recording resolution, format/codec, framerate, and running timecode.
Primarily a testing/inspection tool.

## Key constraint: one command socket, owned by the live-view loop

Every property read/write is a PTP transaction on the **command socket**, which the
live-view pull loop already owns. Issuing transactions from the UI concurrently would
interleave with an in-flight `GetLiveViewImageEx` and corrupt the PTP response stream.

**Therefore all camera I/O is serialized through the loop's existing safe point** — the
moment between receiving a frame and issuing the next request, when the socket is idle
(this is where `_maybeReconfigure` already runs quality changes + the fps re-read). Each
safe-point visit performs **at most one** transaction:

- if a write is queued → execute it, then re-read that property;
- else → read the **next** property in a round-robin and update the displayed snapshot.

One transaction per frame keeps the stream smooth while refreshing the full set a few
times per second. **Timecode is parsed from the live-view frame header (offsets 831–835)
on every frame — free, no transaction.**

## Property map (what we read/write)

New-API access: `GetDevicePropValueEx 0x943B` (read), `SetDevicePropValueEx 0x943C`
(write), `GetDevicePropDescEx 0x943A` (describe → current value, supported value set,
writability). Exact bit layouts and enum value tables are established per property from
libgphoto2 and observed camera behavior; this doc keeps codes + roles only.

| Setting | Code | Role |
| --- | --- | --- |
| ISO (effective) | `0xD0B5` ISOControlSensitivity | read; video ISO write via `0xD1AA` MovieExposureIndex |
| Shutter speed (video) | `0xD1A8` MovieShutterSpeed | read/write; num/den packed |
| Shutter angle (video) | `0x0001D075` MovieShutterAngle | read/write; angle×100, enum set |
| Shutter mode | `0x0001D074` MovieShutterMode | selects angle vs speed; describe at runtime |
| F-number (video) | `0xD1A9` MovieFnumber | read/write; aperture×100 |
| WB mode (video) | `0xD23A` MovieWhiteBalance | read/write; enum |
| WB Kelvin (video) | `0xD21A` MovieWbColorTemp | read/write; Kelvin |
| Resolution + framerate | `0xD0A0` MovieRecordScreenSize | read/write; UINT64, packs H/V res + fps + scan + slow-mo |
| Format / codec | `0xD0AF` MovieFileType | read/write; UINT32, packs codec + bit-depth + container |
| Focal length | `0x5008` FocalLength | **read-only**; mm×100 |
| Lens | `0xD0E0` LensID (+ LensSort/min-max focal/aperture) | **read-only** |
| Timecode (running) | LV-frame header offsets 831–835 | **read-only**; status + HH:MM:SS:FF |

**Read-only by nature:** focal length, lens info, running timecode.
**Adjustable:** ISO, shutter (angle/speed), F-stop, WB mode + Kelvin, resolution, format,
framerate. Resolution and framerate are the same 64-bit value (`0xD0A0`) — changing
framerate means selecting a supported resolution+fps enum, not an independent field.

## Architecture & components

- **`lib/ptp_ip/camera_props.dart`** *(pure, no I/O)* — property-code constants, a
  `CameraState` immutable snapshot of decoded values, and per-setting **encode/decode**
  helpers: unpack `0xD0A0`→`(width,height,fps,…)`, `0xD0AF`→`(codec,bitDepth,container)`,
  shutter speed num/den→`"1/60"`, shutter angle×100→`"180°"`, F-number×100→`"f/2.8"`,
  WB mode enum→label, Kelvin, focal length, lens summary. Each is unit-testable with
  sample bytes.
- **`lib/ptp_ip/live_view.dart`** — add pure `parseTimecode(Uint8List header)` →
  `Timecode(on, hh, mm, ss, ff)`.
- **`lib/ptp_ip/ptp_ip_client.dart`** — generic `getProperty(int code)→Uint8List`,
  `setProperty(int code, Uint8List value)`, `describeProperty(int code)→PropDesc`
  (parses current value + form: enum list or range + get/set flag). The New-API
  DevicePropDesc binary layout is `[VERIFY-ON-HW]`.
- **`lib/ptp_ip/live_view_stream.dart`** — add a `ValueNotifier<CameraState> cameraState`;
  a round-robin read cursor + a write queue, both drained at the safe point (extends
  `_maybeReconfigure`); `setCameraProperty(int code, Uint8List value)` enqueues a write;
  decode the per-frame header timecode into `cameraState`.
- **`lib/camera_panel.dart` / monitor UI widgets** — the first implementation may remain a
  collapsible overlay, but the Penpot wireframe target is a persistent bottom camera-value strip
  (ISO, shutter, iris, WB, focus) plus larger transient picker panels for edits. Read-only values
  such as lens, focal length, and timecode also feed Command mode cards. Enum options still come
  from `describeProperty` when available.

## Data flow

```text
loop safe point (each frame, socket idle):
  if writeQueue not empty:
      pop write → setProperty(code, value) → getProperty(code) → decode → update cameraState
  else:
      code = next in round-robin → getProperty(code) → decode → update cameraState
every frame:
  parseTimecode(header) → update cameraState.timecode   (no transaction)

overlay: ValueListenableBuilder<CameraState> renders rows;
  edit control → stream.setCameraProperty(code, encoded) → enqueued
```

## Error & mode handling

- A rejected write (`Access_Denied`, wrong A/S/M mode, `Device_Busy`) is caught; a brief
  inline note appears on that row, and the value reverts to the camera's actual (the
  re-read). No crash, no disconnect.
- A single failed read leaves the prior value (content error, not connection error —
  same split the frame loop uses; only timeouts/socket errors disconnect).
- Settings the camera doesn't expose (describe returns nothing / get fails) are hidden.
- Enum dropdowns offer only the **currently supported** values from `describeProperty`,
  so mode-gating is reflected (e.g. F-number not settable outside A/M shows no options or
  a disabled control).

## Testing

- **Unit (pure):** `camera_props_test.dart` decodes/encodes real KB byte samples — e.g.
  `0xD0A0 0x0F000870001E0000` → 3840×2160 30p; `0xD1A8 0x0001003C` → 1/60; `0xD0AF
  0x00010800` → H.265 8-bit MOV; shutter angle `18000` → 180°; F-number `0x0118` → f/2.8.
  `parseTimecode` from sample header bytes.
- **Not unit-tested (flagged):** `getProperty`/`setProperty`/`describeProperty` (live
  PTP), the loop poll/write-queue routing, and the overlay — covered by on-device
  validation, not hidden behind a green suite.

## Verify-on-HW

1. Whether writes are accepted over "Connect to PC" Wi-Fi (same open question as the
   live-view quality controls).
2. The `GetDevicePropDescEx` New-API binary layout (current value + form parsing).
3. The untranscribed ZR cine-prop types/enums (`MovieShutterMode 0x0001D074`, base ISO) —
   discovered via `describeProperty` at runtime; hidden if absent.
4. Whether cine writes require application mode (we already issue `ChangeApplicationMode`
   after pairing).

Reads are the safe foundation; the write surface is the verify-heavy part.

## Phasing (single spec, two plan stages)

- **Stage 1 — Read-only.** `camera_props` decoders + `parseTimecode` + `getProperty` +
  loop-routed round-robin poll + the overlay displaying all 10 values (incl. timecode).
  Certain-useful; confirms codes/decoding/loop-routing on hardware.
- **Stage 2 — Adjust.** `describeProperty` + `setProperty` + write queue + editable
  controls (wireframe-style picker panels backed by describe-sourced options) + mode-gate/error
  handling.

- **Stage 3 — Wireframe alignment.** Move the information architecture from a debug-style overlay
  into the monitor shell: bottom value strip, Command mode cards, and shared picker panels. This is
  planned in `docs/design/plans/2026-06-20-wireframe-kit-app.md`.

Stage 1 ships and is testable on its own before Stage 2's write surface is built.

## Out of scope (YAGNI)

- Photo-mode (still) exposure controls — video/cine settings only.
- Autofocus / focus controls, AF-area tap (separate feature).
- Persisting or presetting camera configurations.
- A standalone (non-overlay) camera screen.
