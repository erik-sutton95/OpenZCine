---
title: ZR coverage and implementation
description: What has been observed on a Nikon ZR, what remains verify-on-hardware, and open implementation work.
---

Part of the [Nikon ZR reference](../).
Read the overview for firmware, survey scope and evidence levels.

## General status and remaining work

| Area | Observed coverage | Remaining qualification |
| --- | --- | --- |
| Connection | Wi-Fi connect, pairing, reconnect and live view on a ZR; field reports from phone hotspot and router paths shaped the reconnect and adaptive-stream fixes | Reconnect settle time, graceful-close effect and first-frame deadline against a real ZR; router behavior under congestion |
| USB-C | Transport-aware wizard and session layer shipped on both platforms | ZR hardware pass over iOS ImageCaptureCore; PC-camera to remote-mode switch |
| Live view | Header offsets, AF boxes and whole-size coordinates confirmed against raw ZR dumps; recording state and timecode from the header | Rotation byte polarity on a physically rotated body |
| Recording format | Codec and frame-size descriptors; the camera closes the connection on unadvertised combinations or Ex writes of 2-byte codes | FX/DX RAW labels and codec-dependent descriptor reload on hardware |
| Exposure | Dual-base R3D NE ISO, Auto ISO rules, shutter angle/speed, iris enumeration | ZR-only extended codes (`0x0001_Dxxx`); whether the movie mode dial reports through `0x500E` |
| White balance | Presets and Kelvin; R3D NE hides automatic modes on the body | Tint grid encoding; the same restriction under N-RAW and ProRes RAW |
| Focus | AF area moves, tap-to-focus rules, the focus dial, tracking release; `ChangeAfArea` can re-latch tracking | Movie AF value tables; `EndTracking`; no-AF still release in AF modes |
| Audio | Level meters from the header; live program audio shown not to be available over PTP-IP | ZR-only audio codes; meter segment to dBFS mapping |
| Media | Card-present storage IDs, proxy and master pairing, proxy timecode from a real ZR proxy | ZR movie format codes, clips of 4 GiB or more, `GetPartialObjectEx` and `GetObjectSize`, R3D NE header layout, timecode in Frame.io |
| Body status | Five-step battery reporting; clock sync policy | The `WarningStatus` overheat bit; the `MovieRecordInterrupted` error-value table |

## Open verify-on-hardware seams

These are deliberately inert or conservative until a ZR confirms them:

- **Overheat bit.** `WarningStatus` (`0xD102`) is an aggregate UINT8 whose bit
  positions the body enumerates at runtime and no open source publishes. The app
  shows any non-zero value as a warning (`CHECK`), but the camera-driven
  live-view step-down is gated on an overheat mask that defaults to disabled, so
  it never fires on a guess. The phone's own thermal state still drives the
  preview step-down
  ([`CameraWarningStatus.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/CameraWarningStatus.swift)).
- **Record interruption.** `MovieRecordInterrupted` (`0xC105`) is surfaced
  without interpreting its error values.
- **Open capture.** Interval and focus-shift capture (`0x9445` to `0x9447`) are
  cataloged but unverified.
- **Large objects.** `GetObjectSize` and `GetPartialObjectEx` follow
  libgphoto2's decoders and have not been exercised on a ZR.

## Implementation follow-up

The deferred items from the
[connection reliability audit](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/connection-reliability-audit.md)
wait for a ZR on the bench, in this order:

1. Close the event socket as well as the command socket on a command timeout,
   and tear the transport down when the event drain fails.
2. Escalate repeated keep-alive or event-drain failures into a real reconnect,
   only after item 1 and the shipped graceful close are verified.
3. Back off the discovery probe of a host dropped in the last few seconds, so
   discovery adds no `Init` pressure during the camera's slot-release window.

Other gaps before exposing more ZR controls:

1. Confirm FX/DX RAW labels and the codec-dependent frame-size reload on a ZR
   over Wi-Fi and USB-C before probing any crop-related property.
2. Fill the overheat mask against a hot ZR before letting the camera's warning
   drive the preview step-down.
3. Confirm the movie VR value table and electronic VR before treating their
   writes as qualified.
4. Run the manual proxy-timecode check through Frame.io.

This inventory guides future implementation. It does not add those controls to
either app or replace physical verification.
