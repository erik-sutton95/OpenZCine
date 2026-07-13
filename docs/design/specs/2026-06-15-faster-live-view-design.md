# Faster, Buttery-Smooth Live View — Design

**Date:** 2026-06-15
**Status:** Approved (brainstorming) — ready for implementation plan
**Production-stack note:** This Flutter/Dart design remains valuable as prototype evidence. Production
implementation should preserve the same transport and smoothness requirements in native SwiftUI and
Jetpack Compose shells, with pure live-view parsing/state in the shared Swift core and platform-native
decode/render paths.

## Goal

Raise the live-view frame rate from the current ~20fps cap to match the camera's
live-view rate (target 25fps, ideally 50fps when the camera runs 50p), and make
the displayed stream **buttery smooth** — no judder or stutter, even when frame
arrival is irregular.

## Background — why it's ~20fps today

The streaming loop in `lib/live_view_page.dart` is serial and throttled:

```
request frame → await full JPEG → decode + render → sleep 33ms → repeat
```

Bottlenecks, in rough order of cost:

1. A hard `await Future.delayed(33ms)` per iteration — a 30fps ceiling by
   construction.
2. **Nagle's algorithm**: sockets are created without `TCP_NODELAY`. Our tiny
   request / wait-for-reply pattern is the pathological case for Nagle +
   delayed-ACK, which can add ~40ms stalls per request.
3. Decode + render sit on the critical path — the socket idles while we draw.
4. Per-frame JPEG size — bigger frames take longer to move over Wi-Fi.

## Constraints & decisions

- **Codec is JPEG (MJPEG), and that's correct.** The ZR exposes only the JPEG
  `LiveViewObject` (`GetLiveViewImageEx 0x9428`) for live view over PTP-IP. Its
  H.264/H.265/ProRes/N-RAW/R3D codecs (`MovieFileType 0xD0AF`) are *recording*
  codecs that write files to the card — not a live stream. There is no live
  H.264/AV1 stream to request, and re-encoding on the phone would only add
  latency for local display. MJPEG is intra-frame (zero GOP/buffer latency) and
  hardware-decoded on iOS — the right tool for a low-latency monitor.
- **Resolution ceiling: XGA (1024×768).** The LV feed maxes at XGA; true
  high-res monitoring is the HDMI/SDI path, out of scope here.
- **Quality↔fps: fps-first.** We may shrink to VGA/QVGA and higher compression
  to hit the rate (user decision).
- **Smoothness is a first-class requirement**, not polish.
- **`[VERIFY-ON-HW]`** Setting `LiveViewImageSize 0xD1AC` / `LiveViewImageCompression 0xD1BC`
  programmatically may be **read-only in "Connect to PC" mode** (sibling prop
  `LiveViewSelector 0xD1A6` is). If the camera rejects the write, the fallback is
  setting LV image size in the camera menu; the app must degrade gracefully.

## Architecture (Approach A — layered, decoupled pipeline)

Three layers, shippable and measurable independently:

1. **Transport + de-throttle + instrumentation.** Enable `TCP_NODELAY`; remove
   the 33ms sleep; add fps **and jitter** instrumentation.
2. **Camera shrink.** `configureLiveView` writes `0xD1AC`/`0xD1BC` (best-effort).
3. **Decoupled producer/consumer pipeline** — the throughput *and* smoothness win.

### The producer/consumer split

- **Producer** (`LiveViewStream` controller, no Flutter widgets): a fetch loop
  that keeps **exactly one frame request in flight**, decodes each JPEG to a
  `ui.Image` off the UI isolate, and publishes the newest image into a single
  "latest" slot. Pipelining: request frame N+1 *before* decoding N, so decode
  overlaps N+1's transfer instead of blocking it.

  ```
  var next = client.liveViewFrameJpeg();        // request frame 0
  while (running) {
    final jpeg = await next;                     // receive frame N (+ response)
    next = client.liveViewFrameJpeg();           // request N+1 now (one in flight)
    final img = await decode(jpeg);              // decode N while N+1 transfers
    frame.value = img;                           // publish latest
    recordSample(bytes: jpeg.length, decodeMs, tMs);
  }
  ```

- **Consumer** (`LiveViewPage`): renders `frame` via `RawImage` inside a
  `RepaintBoundary`. A `ValueNotifier<ui.Image?>` drives it; Flutter coalesces
  rapid producer updates into **one repaint per vsync**, so display cadence is
  steady (60/120Hz) regardless of arrival jitter. Latency stays ~1 frame — no
  multi-frame jitter buffer (that would add lag).

This is what delivers "buttery": arrival is decoupled from display, decode never
blocks the UI thread, and the screen always shows the freshest frame at a steady
cadence.

## Components / changes

| File | Change |
|---|---|
| `lib/ptp_ip/ptp_ip_client.dart` | `setOption(SocketOption.tcpNoDelay, true)` on both sockets after connect. Add a **data-out** path to `_transact` (send Start_Data + End_Data after the request). Add `configureLiveView({size, compression})` using `SetDevicePropValueEx 0x943C` on `0xD1AC`/`0xD1BC` — best-effort, records results, never throws. |
| `lib/ptp_ip/ptp_operation.dart` | Helpers `buildStartDataPayload(tid, totalLength)` and `buildEndDataPayload(tid, data)` for the data-out phase. |
| `lib/ptp_ip/ptp_constants.dart` | `LiveViewImageSize 0xD1AC`, `LiveViewImageCompression 0xD1BC` prop codes; size enum (1=QVGA,2=VGA,3=XGA); compression value used. |
| `lib/ptp_ip/live_view_stream.dart` (new) | `LiveViewStream` producer controller: `start()`/`stop()`, exposes `ValueListenable<ui.Image?> frame` and `ValueListenable<LiveViewStats> stats`. Owns the pipelined fetch+decode loop and image lifecycle. |
| `lib/ptp_ip/live_view_stats.dart` (new) | Immutable `LiveViewStats` (fps, jitterMs, avgFrameKB, avgDecodeMs) + a **pure** `computeStats(List<FrameSample>, nowMs)` over a rolling 1s window. |
| `lib/live_view_page.dart` | Consume `LiveViewStream`: `RawImage` + `RepaintBoundary`; overlay shows fps + jitter (bottom-right). |

### Data-out framing (SetDevicePropValueEx)

```
Operation_Request (type 6): DataPhaseInfo=2 (dataOut), Code=0x943C, TID, Param1=<propCode>
Start_Data (type 9):        TID + TotalLength(UINT64 LE)
End_Data  (type 0x0C):      TID + value bytes  (UINT8 prop → 1 byte)
Operation_Response (type 7): expect 0x2001 OK
```

Default config for fps-first: `LiveViewImageSize = VGA (2)` (drop to QVGA (1) for
50fps), `LiveViewImageCompression = Normal-Size (2)` (drop to Basic-Size (0) for
max fps). Optionally call
`GetLiveViewCompressedSize 0x9423` after configuring to confirm the per-frame
byte cap shrank.

## Image lifecycle

Each decoded `ui.Image` holds native memory; at VGA×50fps that's ~60MB/s of
allocation. Dispose the **previously displayed** image after the next frame has
rendered (post-frame callback) — bounds memory without disposing an in-use
image, and avoids finalizer-driven GC hitches that would cause stutter.

## Instrumentation

Per-frame samples (arrival time, JPEG bytes, decode ms) feed `computeStats`:
- **fps** — frames in the last 1s.
- **jitter** — stddev of inter-frame intervals (lower = smoother); the
  smoothness metric.
- **avg frame KB**, **avg decode ms** — to see whether transfer or decode
  dominates, guiding which layer to push next.

Overlay shows at least `fps` + `jitter`; the rest aids tuning.

## Error handling

- `configureLiveView` never fails the stream (camera may reject writes in PC
  mode → log, continue at default).
- Transient frame errors (e.g., `Not_LiveView 0xA00B`, frame-not-ready): skip and
  continue.
- Persistent errors surface in the UI.
- `stop()` halts the loop, then `stopLiveView`; all `ui.Image`s disposed.

## Testing

Pure, unit-testable:
- `buildStartDataPayload` / `buildEndDataPayload` — exact bytes.
- `SetDevicePropValueEx` request bytes for `0xD1AC`/`0xD1BC` (dataPhase=2, param,
  value).
- `computeStats` — fps and jitter from synthetic frame samples.

On-device (validated by the overlay): achieved fps, jitter, and visual
smoothness at VGA and QVGA.

## Layered rollout (measure between each)

1. `TCP_NODELAY` + remove throttle + stats overlay → expect a jump toward 30fps;
   read jitter.
2. `configureLiveView` VGA/QVGA → expect transfer time to drop, fps to rise.
3. Decoupled producer/consumer pipeline → hides decode/render behind the network
   and smooths cadence → push toward 50fps and low jitter.

## Out of scope (YAGNI)

- H.264/AV1/any non-JPEG live stream (not exposed by the protocol).
- Phone-side re-encoding / re-broadcast.
- >XGA monitoring (HDMI/SDI territory).
- Recording control, AF/exposure overlays from the LV header (separate work).
