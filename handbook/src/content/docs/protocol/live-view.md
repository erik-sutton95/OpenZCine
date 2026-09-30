---
title: Live view
description: StartLiveView, GetLiveViewImageEx frames as JPEG plus a display-info header, stream presets, poll pacing, the watchdog and camera load management.
---

Nikon live view over PTP is **pulled, not streamed**. The host asks for one
frame at a time with `GetLiveViewImageEx` on the ordinary command channel. The
parser is `Sources/OpenZCineCore/PTPLiveViewObject.swift`. Confirmed on the ZR;
Gen-1 layout confirmed on a Z 7.

## Start and stop

1. `StartLiveView` (`0x9201`).
2. Poll `DeviceReady` (`0x90C8`) until OK, about 50 ms apart.
3. Loop `GetLiveViewImageEx` (`0x9428`) as fast as each transaction completes.
   There is no target frame rate and no pacing sleep.
4. `EndLiveView` (`0x9202`) whenever the feed is completely hidden: Command
   mode or a full-screen panel. It resumes when the operator can see the feed.

If live view will not start, `LiveViewProhibitionCondition` (`0xD1A4`) says
why. The first frame has a 10 s deadline and later frames 6 s.

## Frame layout

Each LiveViewObject is a **display-info header followed by a JPEG**.

| Body | Header | Notes |
| --- | --- | --- |
| Gen 3 (ZR, Z 8, Z 9, Z 6III and peers) | 1024 bytes | Confirmed on ZR |
| Gen 1 (Z 5, Z 6, Z 7, Z 50) | 512 bytes | Confirmed on Z 7. No sound, record, rotation or level fields |

The JPEG starts at the header length (`FF D8 FF`); an unknown body falls back
to a bounded scan for the JPEG start. The header is **big-endian**, unlike the
little-endian PTP containers around it.

| Offset | Field | Notes |
| --- | --- | --- |
| 12 | JPEG length | `u32` |
| 16 / 18 | Whole width / height | `u16`, the AF coordinate space (6048×3400 on the ZR) |
| 42 | Focus result | 2 focused, 1 not focused |
| 43 | Subject detection active | 1 when subject detection drives AF |
| 44 / 45 | Box count / selected box | |
| 46 | Tracking active | 1 during target tracking |
| 48 | AF boxes | `[w, h, cx, cy]` `u16` each, 8 bytes per box. Box 0 is the AF area; with subject detection, then face and eye |
| 824–827 | Sound indicator | Peak L, peak R, current L, current R, `0…14` segments |
| 828 | Recording | 0 live view, 1 recording. Catches a take started on the body |
| 831–835 | Timecode | On flag, then hours, minutes, seconds, frames |
| 839 | Rotation | 0 landscape, 1 grip up, 2 grip down, 3 upside down [verify-on-HW polarity] |
| 840 / 844 / 848 | Roll / pitch / yaw | Signed 16.16 fixed point, degrees = value / 65536. `FFFFFFFF` means unreliable |

The feed is the camera's monitoring JPEG, not the recorded image. OpenZCine
treats header state as authoritative for recording, timecode and level, which
is why these are not polled separately during a take.

The sound indicator is **metering only**. PTP live view carries no program
audio, and the body advertises no PTP streaming operations
([feasibility note](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/live-audio-monitoring.md)).
Use the camera's headphone jack.

## Stream presets

Two camera-side bytes shape the stream. Both are remembered per
[setup](../wifi/), and the camera access point starts on Fast.

| Setting | Property | Fast | Balanced | Quality |
| --- | --- | --- | --- | --- |
| Stream Preset (frame size) | `LiveViewImageSize` `0xD1AC` | `1`, up to about 320×240 | `2`, up to about 640×480 | `3`, up to about 1024×768 |
| Quality Bias (compression) | `LiveViewImageCompression` `0xD1BC` | `0` Basic, size priority | `3` Normal, quality priority | `5` Fine, quality priority [verify-on-HW] |

The app asks for a smaller frame, never a larger one than the preset, while
recording (capped to VGA), when the phone is thermally stressed, or when the
camera reports a warning. Command mode and HDMI capture only need the header,
so they request the smallest size.

## Polls between frames

Every property read and every `GetEventEx` is a round trip the next frame
queues behind. `LiveViewPollPacing` scales the poll stride by the measured
round trip, so a slow router path does not turn a fixed cadence into a
periodic hitch. Body-announced changes (`DevicePropChanged`) keep a fast
cadence; the background round-robin spreads out. During a take only battery,
power and warning status are polled, storage every 15 s, and lens and mode
descriptors every 60 s outside a take.

## Watchdog and heat

`LiveViewWatchdog` declares a stall after 6 s without a good frame, a streak of
unparsable frames, or the **same JPEG repeating** for 4 s. A wedged body can
keep answering with one cached frame, and a live sensor never produces the same
bytes twice. A stall restarts the stream through [session recovery](../ptpip-transport/#recovery).

Under serious or critical phone thermal state the app slows only its own feed
display and scope sampling (×1.5 and ×2). It never changes the camera's
recording resolution, codec or take.

## One camera, many screens

A body serves one PTP-IP initiator. Other screens get the picture from the
phone that holds the camera: Share This Feed re-encodes the monitor as HEVC
(JPEG fallback) and advertises Bonjour `_openzcine-mon._tcp`. Control is
proxied by the broadcaster, never transferred. See
[Share This Feed](../../guides/share-feed/) and the
[streaming architecture](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/streaming-architecture.md).
