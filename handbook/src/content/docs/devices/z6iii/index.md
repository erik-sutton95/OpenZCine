---
title: Nikon Z 6III
description: Nikon Z 6III field reports organized by connection, picker and focus findings, with evidence levels.
---

The Nikon Z 6III is listed as untested on the landing page. It is a generation 3
body with the same vendor surface as the ZR, and owner reports from a Z 6III
have driven several fixes. This reference records those reports and what the
code now does about them. OpenZCine support is documented separately in the
[iOS](../../apps/ios/) and [Android](../../apps/android/) pages.

The repository does not record the Z 6III firmware version behind these
reports. Most fixes are pinned by synthetic tests against a fake camera
configured as a Z 6III; the reporting owner's hardware retest is the remaining
qualification.

## Find a finding

| Reference | Contents |
| --- | --- |
| [Connection and reconnect](./connection/) | USB product-name matching, the Android USB dead-write retry, camera access-point joins and two bodies sharing one address |
| [Coverage and implementation](./coverage/) | Codec bit depth, release-mode order, the focus-drive wedge, shutter angle preservation and remaining qualification |

Shared framing and operations remain in the
[command catalog](../../protocol/commands/). ZR values in the
[ZR reference](../zr/) apply where the Z 6III advertises the same property.

## Differences from the ZR

| Area | Z 6III boundary |
| --- | --- |
| Access-point name | The ZR's network name can be derived from its PTP name; a Z 6III's cannot. Camera access-point setups without a stored name join by Nikon brand prefix instead. |
| USB product name | Nikon reports `NIKON DSC Z6_3`. The `_3` is a generation mark and must be rewritten to `Z6III` before matching, or the body reads as an original Z 6. |
| Codec depths | The body advertises H.265 at both 8-bit and 10-bit. |
| Release modes | The body's own order is Single, CL, CH, CH+. |
| Dual-base ISO | R3D NE and its dual-base drums are ZR behavior; the Z 6III uses the unified ISO drum. |

## How to read the evidence

The evidence levels match the [ZR reference](../zr/#how-to-read-the-evidence).
**Observed** here means an owner's field report from a physical Z 6III.
**Synthetic** means the fix is pinned by a wire test against the fake camera.
