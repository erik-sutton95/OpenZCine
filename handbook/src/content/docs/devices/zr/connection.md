---
title: ZR connection and reconnect
description: Camera access point, router, phone hotspot and USB-C paths, pairing, reconnect behavior and clock sync on the Nikon ZR.
---

Part of the [Nikon ZR reference](../).
Read the overview for firmware, survey scope and evidence levels.

## Connection paths

Each way of reaching a body is a saved setup of its own, declared when it is
added and never inferred from the network afterwards
([transport architecture](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/transport-architecture.md)).

| Setup | Link | ZR notes |
| --- | --- | --- |
| Camera access point | The phone joins the ZR's own Wi-Fi network | Only this setup may prompt a Wi-Fi join. The ZR's network name can be derived from its PTP friendly name (a `NIKON_ZR_` prefix and digits). Every Nikon camera access point serves the camera at the same address, so two bodies can share one host. |
| Router | Phone and camera on the same network | Bonjour `_ptp._tcp` browse plus a bounded local subnet probe; manual host entry after two empty passes. Never touches Wi-Fi configuration. |
| Phone hotspot | The ZR joins the phone's hotspot | The phone hosts and waits for the camera to appear. |
| USB-C | Data cable | PTP over USB. See [USB-C](#usb-c). |

On the camera, the app's wizard points at the connect-to-computer Wi-Fi menu;
its menu names match the ZR and may differ on other bodies. The camera-AP step
can read the network name and key from the camera's connection screen with
on-device text recognition, and the operator confirms the result before any
join. Keys are kept in the platform keychain or keystore, never in logs.

Stream preset and quality bias are stored per setup. A camera access point
setup starts at the Fast quality bias, because the camera's own radio fixes its
bandwidth; every other path starts from the app-wide default.

## Connection sequence

1. PTP-IP handshake on TCP port 15740: command socket `Init_Command`, then the
   event socket `Init_Event` ([transport](../../../protocol/ptpip-transport/)).
2. `OpenSession`, then `GetDeviceInfo` immediately, so every later step is gated
   on the advertised operations.
3. First-time pairing where `GetPairingInfo` is advertised (see
   [pairing](#pairing)).
4. `ChangeApplicationMode` into app control, then identity and property
   bootstrap.
5. `StartLiveView`, then the frame loop with property and event polls between
   frames ([live view](../../../protocol/live-view/)).

### Pairing

The app polls `GetPairingInfo` up to 10 times, 250 ms apart, until the camera
returns a pairing challenge, then sends `ConfirmPairing`. The operator confirms
on the camera body, which restarts the camera's access point. **Observed:**
calling `ChangeApplicationMode` or identity reads straight after `ConfirmPairing`
races that restart on real hardware, so both apps end the temporary session and
reconnect with the saved profile instead.

The app presents a stable initiator identity so the camera recognizes a
returning client without pairing mode. A saved identity is never replaced,
because the camera's pairing profile is keyed to it. The camera's word beats the
app's records: if the camera refuses or hangs up on a connect that skipped
pairing, the app falls back to one fresh pairing.

### USB-C

- `[verify-on-HW]`: over USB the ZR boots into PC-camera mode and
  denies vendor app control until `ChangeCameraMode` (`0x90C2`) p1 `1` selects
  remote mode.
- There is no Nikon pairing gate over USB; the pairing operations are absent
  from the USB operation set.
- On iOS, ImageCaptureCore holds the USB session, so the app's own
  `OpenSession` can return `SessionAlreadyOpen` (`0x201E`). The session is
  usable.
- Android probes `GetDeviceInfo` before `OpenSession`, because
  OpenSession-first hung on the cable. iOS now probes DeviceInfo first as well.
- Saved USB setups use a local reconnect key derived from the device, never the
  raw USB serial.

USB-C hardware verification on the ZR is still pending for the iOS
ImageCaptureCore path.

## Reconnect and dropouts

**Observed (field report, ZR over an iPhone hotspot):** the connection dropped
often, and reconnecting sometimes wedged the camera until its battery was
pulled. The camera holds a single PTP session slot and releases it only when it
notices the TCP connection die; a hotspot drop can lose that notice. A new
`Init` inside that window asks for a slot the camera cannot grant
([audit](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/connection-reliability-audit.md)).

| Fix | Behavior | Evidence |
| --- | --- | --- |
| Graceful close | Best-effort `CloseSession` (`0x1003`), bounded to 2 s, before the sockets close on every teardown | `[verify-on-HW]` |
| Reconnect settle | 1200 ms after teardown before a fresh `Init`, reconnects only. This is the calibration knob for the camera's slot-release time. | `[verify-on-HW]` |
| Frame deadlines | 10 s for the first frame, 6 s steady state; a breach closes the command socket so a stuck fetch cannot hold the transaction gate | Shipped; the 10 s bound versus real first-frame latency is `[verify-on-HW]` |
| Adaptive stream | Sustained slow frames step `LiveViewImageSize` down, and 45 s of health steps back toward the operator's preset | Shipped ([wireless audit](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/wireless-transport-audit.md)) |

Do not tighten the socket timeout or add aggressive auto-retry on the hotspot
path: more `Init` attempts are more pressure on a camera still holding a stale
session.

While recording, property polling narrows to battery, external power and
warning status at a low cadence; recording state, timecode and the virtual
horizon already arrive in every live-view header. **Observed:** the ZR reports
`BatteryLevel` (`0x5001`) only as 1, 20, 40, 60, 80 or 100, so the app draws a
five-bar gauge.

## Clock sync

`DateTime` (`0x5011`) is a PTP string `YYYYMMDDThhmmss` with no time zone. At
session bootstrap both apps compare it with the phone's local wall clock and set
the body once when it has drifted more than 5 seconds
([`CameraClockSync.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/CameraClockSync.swift)).
The write never happens while recording, because time-of-day timecode derives
from that clock, and never on an unreadable value.
