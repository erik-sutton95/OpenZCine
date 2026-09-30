---
title: Nikon Z Devices
description: Model-specific command surfaces, capability notes and evidence for Nikon Z cameras.
---

These references describe behavior recorded for specific Nikon Z bodies. Use
them alongside the [shared command catalog](../protocol/commands/). A matching
PTP operation code does not establish a matching property domain, capability or
app support.

| Device | Status | Reference scope |
| --- | --- | --- |
| [Nikon ZR](./zr/) | Working; primary development target | Command surface, formats, exposure, focus, audio, media, connection and open hardware checks |
| [Nikon Z 6III](./z6iii/) | Untested on the landing page; field reports fixed in code | Connection, USB and picker fixes from owner reports |
| [Original Z 5, Z 6, Z 7 and Z 50](./gen-1/) | Untested (Z 7 USB-C live view confirmed) | The generation 1 connect sequence and live-view header |
| Nikon Z9, Z5II | Working on the landing page | No dedicated reference yet. The repository records no model-specific survey. |
| Nikon Z6II, Z7II, Zf, Z8 | Untested | No dedicated reference. Generation rules below apply. |

Status follows the landing page's camera list. "Working" means the owner or
testers have connected and monitored that body. It does not mean every control
on the body has been qualified.

## Body generations

OpenZCine selects operations from the list the body advertises in
`GetDeviceInfo`, not from a model table. The lineup still falls into three
vendor surfaces, recorded in
[`ZCameraCapabilityProfile.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/ZCameraCapabilityProfile.swift):

| Generation | Bodies | App-control entry | Vendor code discovery | Extended property ops | Network pairing |
| --- | --- | --- | --- | --- | --- |
| 1 | Z 5, Z 6, Z 7, Z 50 | Write `1` to `ApplicationMode` (`0xD1F0`) | `GetVendorPropCodes` (`0x90CA`) | No | No; joining the camera network is the trust boundary |
| 2 | Z 6II, Z 7II, Z fc, Z 30 | `ChangeApplicationMode` (`0x9435`) | `GetVendorPropCodes` (`0x90CA`) | No | Advertised per body |
| 3 | Z 8, Z 9, Z 6III, Z f, Z 5II, Z 50II, ZR | `ChangeApplicationMode` (`0x9435`) | `GetVendorCodes` (`0x9439`) | `0x943A` to `0x943C` for 4-byte codes | `GetPairingInfo` / `ConfirmPairing` |

`GetLiveViewImageEx` (`0x9428`), `GetEventEx` (`0x941C`), `DeviceReady`
(`0x90C8`), `ChangeCameraMode` (`0x90C2`) and `InitiateCaptureRecInMedia`
(`0x9207`) are advertised across the whole lineup, so the app carries no
fallback for those. Pairing operations are a network surface and never appear
in the USB operation set; gate pairing on the live operation list.

When `GetDeviceInfo` fails, the app infers a generation from the PTP-IP friendly
name, USB product name or camera access-point name. The longest model token
wins, so `Z 6III` is never read as an original `Z 6`. Nikon USB product names
mark the generation with an underscore digit (`Z6_3`, `Z5_2`), which is rewritten
before matching. An unknown name keeps the generation 3 default, so a failed
probe cannot lock a modern body out of first pairing.

## How to use the references

Start with the device overview and its evidence scope. Follow its command pages
for model-specific properties, values and restrictions. Use
[Shared protocol](../protocol/connection/) for PTP-IP framing, USB transport,
connection sequencing and common operation definitions.

Evidence levels distinguish a cited standard, behavior observed on a camera,
behavior exercised only against the fake camera in tests, and code still marked
`[verify-on-HW]`. An untested control stays untested even when another Z body
supports it. These references are implementation notes, not a statement that
either OpenZCine app exposes every listed property.
