---
title: Connection spine
description: PTP-IP over Wi-Fi or PTP over USB-C. Order of operations from discovery to live view and media.
---

OpenZCine speaks standard PTP to Nikon Z bodies: PTP-IP over Wi-Fi, or PTP over
the USB-C cable. There is no Bluetooth step and no vendor SDK. Every control,
live-view frame and media byte rides the same serialized PTP session. Order of
operations on Wi-Fi:

```text
discover → TCP :15740 Init_Command → Init_Event → OpenSession → GetDeviceInfo → pair (first time) → app-control mode → live view → media
```

1. **[Reach the camera](../wifi/).** Join the camera's own access point, share a
   router with it, or let it join the phone's hotspot. Discovery browses
   Bonjour `_ptp._tcp` and probes the local subnet.
2. **[Init handshake](../ptpip-transport/).** Command socket first
   (`Init_Command_Request` / `Init_Command_Ack`), then the event socket with the
   connection number the camera assigned. Both on TCP port **15740**.
3. **[OpenSession](../commands/).** Transaction ID 0, then `GetDeviceInfo`. The
   operations the body advertises decide every later step, not the model name.
4. **Pairing (first time only).** Gen-3 bodies show a four-digit code; the
   operator confirms it on both screens (`GetPairingInfo`, `ConfirmPairing`).
   USB-C and original Z 5 / Z 6 / Z 7 / Z 50 bodies have no pairing step: the
   cable, or joining the camera's own network, is the trust boundary.
5. **App-control mode.** `ChangeApplicationMode` on Gen-2 and Gen-3 bodies, a
   write of `ApplicationMode` (`0xD1F0`) on Gen 1. Over USB the ZR also needs
   `ChangeCameraMode` remote mode.
6. **Vendor discovery.** `GetVendorCodes` (or `GetVendorPropCodes` on older
   bodies) lists the vendor properties the body can report, which gates polling.
7. **[Live view](../live-view/)** and **[media](../media/)** run as ordinary
   transactions on the same command channel.

A saved camera skips pairing: the app runs a quiet profile probe, and if the
app-control switch answers OK the session continues. A refusal or a hangup is
treated as the camera's word, and the app falls back to one fresh pairing.

Disconnects send `CloseSession` before closing the sockets, and a reconnect
waits a short settle so the camera can release its single session slot. A body
that never sees the old session end can refuse or wedge on a fast re-Init.

:::caution[Do not publish captures]
Packet captures and connect logs can carry Wi-Fi keys, pairing codes and camera
identifiers. Keep them local and out of issues. Share Diagnostics in the app
produces a privacy-filtered trace instead.
:::

Implementation lives in `Sources/OpenZCineCore/` (packets, handshake, policies)
and the platform transports (`ios/Runner/PTPIPTransport.swift`,
`ios/Runner/USBCameraTransport.swift`, `Sources/OpenZCineAndroidFacade/`).
Platform shells own sockets, permissions and the Wi-Fi join. Body generations
and per-model differences are in [Nikon Z Devices](../../devices/).
