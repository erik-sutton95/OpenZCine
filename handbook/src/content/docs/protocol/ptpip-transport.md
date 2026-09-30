---
title: PTP-IP and USB transport
description: Two TCP sockets on port 15740, the Init handshake, serialized transactions, the event channel, and PTP over USB-C.
---

After the camera is [reachable](../wifi/), control, live view and media share
one PTP session. Framing is the [PTP-IP packet](../ptpip-packet/); this page
covers the sockets and sessions around it.

## Two sockets

PTP-IP (CIPA DC-005) uses **two TCP connections to port 15740**:

1. **Command socket.** Send `Init_Command_Request` with the app's initiator GUID
   and name. The camera answers `Init_Command_Ack` with a connection number and
   its own name, or `Init_Fail`.
2. **Event socket.** Send `Init_Event_Request` carrying that connection number;
   wait for `Init_Event_Ack`.

If either step fails, both sockets close. The initiator GUID is stable per
install: Nikon bodies key their pairing profiles to it, so a new GUID on every
launch would force re-pairing. Once stored it is never replaced.

## Transactions

Every operation, whether a live-view frame, a property read or write, an event
poll, a media chunk or a keep-alive, is **one serial transaction on the command
socket** behind a FIFO gate. There is no pipelining. That is why poll cadence
and chunk size matter to the live picture ([live view](../live-view/)).

| Deadline | Value |
| --- | --- |
| Command transaction | Short whole-transaction deadline; a wedged or dribbling camera cannot hold the gate |
| First live-view frame | 10 s |
| Steady-state live-view frame | 6 s |
| USB first command | Long, because iOS may still be cataloguing a full card |

A blocked socket read cannot be cancelled, so an expired deadline closes the
command socket and recovery takes over. An idle `DeviceReady` keeps a quiet
command channel warm.

## Events

The camera pushes events on the event socket (record started `0xC10A`, record
complete `0xC108`, record interrupted `0xC105`, DevicePropChanged `0x4006`).
The app **drains that socket continuously**: an unread channel backs up the
camera's send buffer and can stall the session deep into a long take. It also
answers `Probe_Request` there.

Nikon bodies deliver capture events (`ObjectAdded`, `CaptureComplete`) and many
`DevicePropChanged` announcements through the **`GetEventEx` poll** (`0x941C`,
parameter 0 clears the queue) rather than the socket. The app polls it between
live-view frames in every monitor mode. An announcement carries no value, so it
only schedules an authoritative read; a bounded batch is re-read per poll,
oldest first.

## Recovery

A dropped link keeps the monitor on the last frame while bounded, jittered
retries run
([`SessionRecovery.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/SessionRecovery.swift),
[`ReconnectBackoff.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/ReconnectBackoff.swift)).
When the budget is spent, or reconnects keep succeeding but die young, automatic
recovery stops and the operator chooses. Rapid session churn can wedge a Nikon
body until its battery is pulled, so the app sends `CloseSession`, waits a
settle interval before a fresh `Init`, and never probes a just-dropped camera
with an extra handshake. Background:
[connection reliability audit](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/connection-reliability-audit.md).

## USB-C

The same PTP operations, properties and datasets ride PIMA 15740 generic
containers on the USB bulk pipe.

| Platform | USB path |
| --- | --- |
| iOS / iPadOS | ImageCaptureCore: `ICDeviceBrowser` discovery and authorization, `requestSendPTPCommand` for each whole transaction, `ptpEventHandler` into the event drain |
| Android | USB Host finds a complete PTP interface, asks per-device consent, and hands raw bulk and interrupt bytes to the Swift facade, which owns container framing and the session |

Differences from Wi-Fi:

- `GetDeviceInfo` is sent before `OpenSession`. On iOS, ImageCaptureCore often
  has the session open already; `Session_Already_Open` (`0x201E`) counts as
  success.
- There is **no pairing**. The pairing operations are absent from the USB
  operation set; the cable is the trust boundary.
- The ZR boots USB sessions in PC-camera mode and refuses app control until
  `ChangeCameraMode` remote mode is set. The body then shows its connected to
  computer screen.
- Saved USB cameras use a local `usb:` device key, never a raw USB serial or a
  network address, and reconnect silently when plugged in.

## The CameraTransport boundary

Wi-Fi and USB share one session layer behind the transaction-level
`CameraTransport` protocol
([`CameraTransport.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/CameraTransport.swift)).
One call runs a whole transaction: request, optional data-out, any data-in, and
the response. It cannot sit lower, because ImageCaptureCore only exposes whole
transactions on iOS. Conformers assign transaction IDs and serialize
internally.

| Layer | iOS | Android |
| --- | --- | --- |
| Wi-Fi transport | `ios/Runner/PTPIPTransport.swift` (BSD TCP sockets) | Kotlin socket adapter, Swift facade session |
| USB transport | `ios/Runner/USBCameraTransport.swift` | Android USB Host adapter, Swift facade session |
| Session orchestration | `NativeCameraSession` | `Sources/OpenZCineAndroidFacade/PTPIPClientSession.swift` |

Kotlin never builds PTP operations. Decisions live in the portable core; see
[ARCHITECTURE.md](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/ARCHITECTURE.md).
