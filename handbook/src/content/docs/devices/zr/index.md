---
title: Nikon ZR
description: Nikon ZR reference organized by command family, recording format, controls, media output and evidence.
---

The Nikon ZR is OpenZCine's primary hardware target. This reference collects
what the repository records about the ZR's PTP surface: operation and property
codes, value tables, restrictions the camera enforces, and which of those have
been exercised on a physical body. OpenZCine support is documented separately
in the [iOS](../../apps/ios/) and [Android](../../apps/android/) pages.

The repository does not record the ZR firmware version these observations were
made on. Firmware updates can add properties, change descriptor layouts or
change what the body accepts, so note the firmware version when you add or
contradict a finding.

## Find a command or capability

| Reference | Contents |
| --- | --- |
| [Command comparison](./commands/) | Command families used with the ZR, standard versus extended property access, and differences from other Z bodies |
| [Shooting modes and formats](./modes/) | Codec and frame-size descriptors, RAW FX/DX modes, photo mode, release modes, image quality and vertical shooting |
| [Exposure, focus and audio](./settings/) | Dual-base ISO, Auto ISO, shutter angle and speed, white balance, focus and AF-area tables, audio properties and level meters |
| [Focus drive and capture controls](./controls/) | AF area moves, AF and MF drives, the focus dial, tracking release, AE lock, stabilization and still release |
| [Original media](./media/) | Storage and object operations, RAW masters and proxies, proxy timecode, ratings and still-size classes |
| [Connection and reconnect](./connection/) | Camera access point, router, phone hotspot and USB-C paths, pairing, reconnect behavior and clock sync |
| [Coverage and implementation](./coverage/) | What has been observed on hardware, what is still `[verify-on-HW]`, and open implementation work |

Shared framing and reusable operations remain in the
[command catalog](../../protocol/commands/). The pages here keep the ZR values,
restrictions and evidence needed to apply them.

## How to read the evidence

| Evidence | What it establishes |
| --- | --- |
| **Cited** | The code, name or dataset layout comes from PIMA 15740 (PTP), CIPA DC-005 (PTP-IP) or the libgphoto2 `ptp.h` catalog. A cited code does not prove the ZR's value encoding. |
| **Observed** | Behavior recorded against a physical ZR: raw live-view dumps, a real proxy file, a field report with a log, or an owner hardware session. |
| **Synthetic** | Exercised only against the in-repo fake camera (`FakeZRServer`) or unit tests. It proves the app's encoding and sequencing, not the camera's answer. |
| **`[verify-on-HW]`** | Marked in source as not yet confirmed on a camera. Codes absent from libgphoto2 carry `[ZR-only · verify-on-HW]`. Not a replay contract. |

The sourcing policy is in
[`docs/nikon-mtp.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/nikon-mtp.md)
and the no-vendor-SDK statement in
[`docs/nikon-sdk.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/nikon-sdk.md).
Value tables that libgphoto2 names but does not decode are app-decoded; the
source marks them `[verify-on-HW]` until a body confirms them.

This is a bounded set of observations gathered while building the apps, not a
complete survey of every menu, setting combination or body feature. Private
footage, credentials, identifiers, serial numbers and raw captures are excluded
from this reference.
