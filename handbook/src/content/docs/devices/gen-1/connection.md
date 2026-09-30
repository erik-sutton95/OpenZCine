---
title: Generation 1 connection and reconnect
description: The connect sequence for the original Nikon Z 5, Z 6, Z 7 and Z 50, USB ordering and the live-view configuration fix.
---

Part of the [original Z 5, Z 6, Z 7 and Z 50 reference](../).
Read the overview for firmware, survey scope and evidence levels.

## Connection sequence

Both apps probe `GetDeviceInfo` right after `OpenSession` and gate every later
step on the advertised operations
([#292](https://github.com/erik-sutton95/OpenZCine/issues/292)):

| Step | Generation 1 | Generation 3 |
| --- | --- | --- |
| 1 | `OpenSession`, then `GetDeviceInfo` | Same |
| 2 | No pairing; `GetPairingInfo` is never polled | First-time pairing where advertised |
| 3 | `SetDevicePropValue` `ApplicationMode` (`0xD1F0`) = `1` | `ChangeApplicationMode` (`0x9435`) |
| 4 | Vendor property discovery only through `0x90CA`; no Ex-property probe | `GetVendorCodes` and Ex-property diagnostics |
| 5 | Identity, then connected | Identity, then connected |

**Observed:** polling an operation a body never advertised is how a Z 5 ended up
showing a wireless error on its own screen while the app kept connecting.
**Synthetic:** the Android fake camera has an advertised-operations personality,
and an end-to-end test pins the generation 1 sequence: no pairing operations, no
`ChangeApplicationMode`, app control by property write.

### When DeviceInfo is missing

An unknown operation list keeps the modern default, so a bad fetch cannot lock a
generation 3 body out of first pairing. That default was still wrong for an
original Z 6 whose probe was missing
([#348](https://github.com/erik-sutton95/OpenZCine/issues/348)). Now, when the
PTP-IP friendly name or USB product name is an original Z 5, Z 6, Z 7 or Z 50,
the app uses the generation 1 fallback set instead. `Z 6II`, `Z 6III` and `ZR`
keep the modern default. Diagnostics record the fallback as
`gateFallback=gen1-name`.

## USB-C

- **iOS** now probes `GetDeviceInfo` before `OpenSession`, matching Android.
  Relying on ImageCaptureCore having opened the session left an original Z 6
  possibly stuck on its first command.
- **Android** parses the pre-session DeviceInfo and passes that policy into app
  control, instead of discarding it.

### Live-view configuration

**Observed on a Z 7 over USB-C
([#368](https://github.com/erik-sutton95/OpenZCine/pull/368)):** the app set the
live-view size and compression with `SetDevicePropValueEx` (`0x943C`). Generation
1 bodies do not implement that operation, and sending it over USB wedged the PTP
stack, so `StartLiveView` and `DeviceReady` never answered. Both apps now write
2-byte property codes with `SetDevicePropValue` (`0x1016`) and use the Ex form
only for 4-byte extended codes. Generation 2 bodies lack the Ex operations too.

## Wi-Fi

Use the camera's connect-to-computer Wi-Fi menu. The smart-device (SnapBridge)
connection is not PTP-IP. The wizard's menu names follow the ZR and may differ
on these bodies.

## Remaining qualification

| Body | Remaining |
| --- | --- |
| Z 5 | Connect over the camera access point without a wireless error |
| Z 6 | USB-C and connect-to-computer Wi-Fi from the reporting iPad and another device |
| Z 7 | Wi-Fi paths; USB-C live view is confirmed |
| Z 50 | No report yet |
