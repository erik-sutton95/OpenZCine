---
title: Z 6III coverage and implementation
description: Codec bit depth, release-mode order, focus-drive recovery, camera authority and remaining qualification on the Nikon Z 6III.
---

Part of the [Nikon Z 6III reference](../).
Read the overview for firmware, survey scope and evidence levels.

## Field reports and fixes

| Report | Finding | Fix | Evidence |
| --- | --- | --- | --- |
| [#276](https://github.com/erik-sutton95/OpenZCine/issues/276) Codec picker | The body advertises H.265 at 8-bit (`0x0001_0800`) and 10-bit (`0x0001_0A00`). Collapsing both into one "H.265" row pinned the picker to the first, so returning to H.265 landed on 8-bit. | Identity is the raw value. One H.265 row carries an 8-bit/10-bit pair, and each writes its own advertised value. | Synthetic (Z 6III-shaped fake) |
| [#274](https://github.com/erik-sutton95/OpenZCine/issues/274) Release modes | The fallback drive list was sorted by raw value, which puts CH before CL. The Z 6III order is Single, CL, CH, CH+. | Advertised set, release order; Self-timer and Quick removed from the drum. | Synthetic |
| [#274](https://github.com/erik-sutton95/OpenZCine/issues/274) Focus labels | AF area `0x8033` read "Subject", which looked like subject detection in the next tab. | Labelled "Subject tracking". | Code |
| [#272](https://github.com/erik-sutton95/OpenZCine/issues/272) Focus dial | A focus-by-wire drive kept the command channel for tens of seconds. The body answered busy to `ChangeAfArea`, so the dial and tap-to-focus were dead until a half-press. | Wall-clock channel budget; `AfDriveCancel` when the readiness poll ceiling is reached; an AF tap pre-empts the drive. | Observed report; synthetic budget tests |
| [#257](https://github.com/erik-sutton95/OpenZCine/issues/257) Camera authority | After a session with a Z5II on shutter speed, a Z 6III set to shutter angle came back on speed. | The camera is authoritative: connecting reads `MovieShutterMode`, never writes the previous body's mode. | Synthetic wire test with two fakes |

Focus-drive and release details are on the ZR
[controls page](../../zr/controls/); they apply to the Z 6III through the same
operations.

## Remaining qualification

| Area | Remaining |
| --- | --- |
| Connection | Owner retest of USB-C and camera access point after the product-name fix |
| Android USB | Reconnect after a pending live view without the dead-write error |
| Pickers | The H.265 bit-depth pair and release order against the body's live descriptors |
| Focus | Focus dial and tap-to-focus after a long pull on a native STM lens |
| Everything else | Formats, exposure, audio and media on a Z 6III have no dedicated evidence; treat ZR findings as unverified here |

This inventory guides future work. It does not change the landing page's
untested status for the Z 6III.
