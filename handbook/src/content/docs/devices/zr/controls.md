---
title: ZR focus drive and capture controls
description: AF area moves, AF and MF drives, the focus dial, tracking release, stabilization and still release on the Nikon ZR.
---

Part of the [Nikon ZR reference](../).
Read the overview for firmware, survey scope and evidence levels.

The ZR has no zoom or gimbal to drive. Its remote physical controls are the
lens focus motor, the AF point, stabilization and the shutter. All of them share
the single serial PTP command channel with the live-view fetch, so every drive
below is bounded in wall-clock time.

## AF area and tap to focus

`ChangeAfArea` (`0x9205`) moves the live-view AF point: p1 `x`, p2 `y`, in the
live-view header's whole-size coordinate space (6048×3400 on the ZR). Moving
the point is not focusing. Whether a tap must also fire a one-shot AF drive
depends on the mode:

| Chrome | Focus mode | After the area move |
| --- | --- | --- |
| Video | AF-C, AF-F | Nothing; the body's continuous AF chases the new point |
| Video | AF-S | `AfDrive` (`0x90C1`) once, or the point moves and nothing focuses |
| Photo | Any AF mode | `AfDrive` once; stills live view does not run continuous AF until a half-press |
| Either | MF | Never drive; the body would refuse |

An unknown mode keeps the earlier photo-only behavior. Each chrome reads and
drives only its own focus mode: a stills-side focus event must not repaint the
movie FOCUS readout or trigger an AF-S drive against a body in AF-C.

## AF and MF drives

| Operation | Parameters | Use |
| --- | --- | --- |
| `AfDrive` `0x90C1` | none | One-shot autofocus at the current point |
| `AfDriveCancel` `0x9206` | none | Stop an in-flight drive and free the channel |
| `MfDrive` `0x9204` | p1 `1` toward near / `2` toward infinity, p2 pulses `1` to `32767` | Focus-by-wire pull |
| `DeviceReady` `0x90C8` | none | Readiness poll after a drive or release |

`MfDrive` completion is read from the readiness poll. `0xA00C` (step end) means
the lens hit the end of travel; `0xA00E` (step insufficiency) means the request
was below what the lens can move. `Device_Busy` (a stepping-motor lens still
initializing) and `Access_Denied` (AF still settling) are always transient.

### Focus dial

The on-feed focus dial drives `MfDrive` in video and photo. Eligibility is one
shared rule
([`PTPOperation.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/PTPOperation.swift)):

| Body focus mode | Dial |
| --- | --- |
| Not read yet, or MF | Not offered; the lens ring owns focus |
| AF-F | Shown inert; full-time servo overrides every pull |
| AF-S, AF-C | Drivable; focus holds between acquisitions |

The channel budget is wall clock, not a retry count: at most 12 readiness polls
at 0.12 s inside one drive, and at most 1.2 s of refusal retries at 0.08 s. An
AF tap pre-empts an in-flight drive rather than queueing behind it.

**Observed (field report on a Z 6III,
[#272](https://github.com/erik-sutton95/OpenZCine/issues/272)):** when a drive
overran the readiness poll on a native Z-mount STM lens, the body answered busy
to `ChangeAfArea` until a half-press. The app now sends `AfDriveCancel` when the
poll ceiling is reached, so tap-to-focus is not wedged. The still release that
follows a dial pull uses the no-AF form so the pull is kept (see
[still release](#still-release)).

## Tracking release

A focus reset that must recenter while subject tracking is engaged runs a
release sequence before `ChangeAfArea`:

1. `EndTracking` (`0x9425`, `[ZR-only · verify-on-HW]`), then `AfDriveCancel`.
2. Temporarily set subject detection to Off and the AF area from Subject
   tracking to Single, only where they were active.
3. Wait for the live-view header to show the tracking lock cleared, within a
   frame budget.
4. `ChangeAfArea` to the center.
5. Repeat `EndTracking` and `AfDriveCancel`. **Observed:** `ChangeAfArea` can
   re-latch target tracking on ZR hardware.
6. Restore the saved AF area and subject detection unless the operator changed
   them during the reset. Restoration writes mode settings only; it never starts
   tracking.

The decision reads the live-view header as well as the polled properties,
because polled values can lag while tracking is already engaged.

`ChangeAELock` (`0x9426`) is cataloged but not used by either app.

## Stabilization

| Property | Values | Evidence |
| --- | --- | --- |
| `MovieVibrationReduction` `0xD1F9` | `0` OFF, `1` ON, `2` SPORT | Code in libgphoto2; value table `[ZR-only · verify-on-HW]` |
| `ElectronicVR` `0xD314` | `0` Off, `1` On | `[verify-on-HW]` |
| `ElectronicFrontCurtainShutter` `0xD20D` | Off / On | Stills only; not polled |

The command monitor summarizes the first two as one stabilization readout.
Stabilization behavior also varies with lens, recording mode and firmware.

## Still release

`InitiateCaptureRecInMedia` (`0x9207`) is preferred wherever advertised, with
`InitiateCapture` (`0x100E`) as the fallback. Its first parameter selects the
release:

| p1 | Release |
| --- | --- |
| `0xFFFFFFFE` | AF drive, then release: a half-press then fire, like the body's shutter button |
| `0xFFFFFFFF` | Plain release with no AF step; keeps a focus-dial pull |

`[verify-on-HW]`: that `0xFFFFFFFF` skips AF while the body is in an AF focus
mode.

In the continuous release modes a remote release latches until
`TerminateCapture` (`0x920C`), so the shutter control ends the burst on finger
up (`[verify-on-HW]` per body). The stills shutter property `0xD100` also
carries the open-shutter sentinels `0xFFFFFFFF` Bulb, `0xFFFFFFFD` Time and
`0xFFFFFFFE` X-sync. Busy answers during a release include `0xA200` (bulb
release busy), `0xA201` (silent release busy) and `0xA202` (movie frame release
busy); `DeviceReady` is classified while a release is in flight.

Shots released on the body itself register in the app from the event poll
(`ObjectAdded`, `CaptureComplete`), not from the PTP-IP event socket. The
interval and focus-shift operations `0x9445` to `0x9447` exist on generation 3
bodies and remain `[verify-on-HW]`.
