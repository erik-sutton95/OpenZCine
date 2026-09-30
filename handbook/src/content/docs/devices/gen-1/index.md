---
title: Original Z 5, Z 6, Z 7 and Z 50
description: Generation 1 Nikon Z bodies, their vendor surface, live-view header and field reports.
---

The original Z 5, Z 6, Z 7 and Z 50 share the generation 1 vendor surface. They
are untested on the landing page. Field reports from a Z 5, a Z 6 and a Z 7 have
shaped a separate connect sequence for them, and live view over USB-C is
confirmed on a Z 7. OpenZCine support is documented separately in the
[iOS](../../apps/ios/) and [Android](../../apps/android/) pages.

## Find a finding

| Reference | Contents |
| --- | --- |
| [Connection and reconnect](./connection/) | The generation 1 connect sequence, the name fallback when DeviceInfo is missing, USB ordering and the live-view configuration fix |

## Vendor surface

| Surface | Generation 1 | Generation 3 (ZR) |
| --- | --- | --- |
| App control | Write `1` to `ApplicationMode` (`0xD1F0`) | `ChangeApplicationMode` (`0x9435`) |
| Network pairing | None. Joining the camera's network is the trust boundary. | `GetPairingInfo` / `ConfirmPairing` |
| Vendor codes | `GetVendorPropCodes` (`0x90CA`, 2-byte codes) | `GetVendorCodes` (`0x9439`) |
| Extended property ops | Not implemented | `0x943A` to `0x943C` |
| Live-view header | 512 bytes before the JPEG | 1024 bytes |

When `GetDeviceInfo` does not arrive and the camera name is an original Z 5, Z 6,
Z 7 or Z 50, the app assumes this conservative operation set:

```text
0x90CA 0x90C2 0x9201 0x9202 0x9203 0x9428 0x90C7 0x941C 0x90C8
0x100E 0x9207 0x90C0 0x90CB 0x920C
```

It is not a model table for a live body: advertised operations still win. It
exists so a failed probe cannot fall through to the pairing and app-mode
operations these bodies never implemented.

### Live-view header

**Observed on a Z 7 over USB-C
([#368](https://github.com/erik-sutton95/OpenZCine/pull/368)):** the display-info
header before the JPEG is 512 bytes, not the 1024 confirmed on the ZR. The
fields the ZR carries past byte 512 (sound level at 824, record state at 828,
rotation at 839, level angles) are generation 3 additions. The parser caps the
header at 512 bytes when the JPEG start marker sits there, so those fields fall
back to safe defaults instead of reading picture data.

## Field reports

| Report | Body | Finding | Status |
| --- | --- | --- | --- |
| [#292](https://github.com/erik-sutton95/OpenZCine/issues/292) | Z 5 | The camera showed a wireless error during connect: pairing and app-mode operations ran before DeviceInfo could gate them | Fixed; `[verify-on-HW]` Z 5 over the camera access point |
| [#348](https://github.com/erik-sutton95/OpenZCine/issues/348) | Z 6, firmware 3.80 | Neither USB nor Wi-Fi completed from an iPad | Name fallback and USB ordering fixed; awaiting a hardware matrix |
| [#368](https://github.com/erik-sutton95/OpenZCine/pull/368) | Z 7 | Live view never started over USB-C | Fixed and confirmed on a Z 7 over USB-C |

Keep the landing page status at untested for each body until USB and the
camera's connect-to-computer Wi-Fi both complete on real hardware
([investigation](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/investigations/debug/z6-firmware-3.80-ipad-connect.md)).
