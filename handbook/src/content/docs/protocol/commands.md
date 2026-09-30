---
title: Command catalog
description: PTP operation codes, Nikon vendor operations, device properties, events and response codes that OpenZCine uses.
---

Operations, properties and events OpenZCine uses on the
[connection spine](../connection/), camera control, live view and media.
Framing is in [PTP-IP packet](../ptpip-packet/). This is not a complete Nikon
dictionary, only what the app sends or decodes.

Names mirror the libgphoto2 symbols (`PTP_OC_*`, `PTP_OC_NIKON_*`, `PTP_DPC_*`)
per the [sourcing policy](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/nikon-mtp.md).
**[verify-on-HW]** marks behavior not yet confirmed on a real body; **ZR-only**
marks codes absent from libgphoto2 and seen only on the ZR. The source of truth
is [`PTPOperation.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/PTPOperation.swift).

## Session, pairing and mode

| Opcode | Name | Notes |
| --- | --- | --- |
| `0x1001` | GetDeviceInfo | Operations and properties the body advertises. Drives every generation decision. |
| `0x1002` | OpenSession | Transaction ID 0 |
| `0x1003` | CloseSession | Sent before dropping sockets, so the camera frees its session slot |
| `0x952B` | GetPairingInfo | Returns the pairing challenge; the camera shows a four-digit code. ZR-only, network only |
| `0x935A` | ConfirmPairing | After the operator confirms the code. ZR-only, network only |
| `0x9435` | ChangeApplicationMode | `p1 = 1` enters app control. Gen 2 and Gen 3 |
| `0x90C2` | ChangeCameraMode | `p1`: 0 PC-camera, 1 remote. Needed over USB on the ZR [verify-on-HW] |
| `0x9439` | GetVendorCodes | Vendor operation and property lists (Gen 3) |
| `0x90CA` | GetVendorPropCodes | Vendor property list on Gen 1 and Gen 2 |
| `0x90C8` | DeviceReady | Readiness poll after live view start or a drive; also the idle keep-alive |

## Properties

| Opcode | Name | Notes |
| --- | --- | --- |
| `0x1014` | GetDevicePropDesc | Allowed values for a picker |
| `0x1015` | GetDevicePropValue | 2-byte `0xDxxx` and standard `0x50xx` codes |
| `0x1016` | SetDevicePropValue | 2-byte codes, including recording format |
| `0x943A` | GetDevicePropDescEx | 4-byte `0x0001_Dxxx` extended codes (Gen 3) |
| `0x943B` | GetDevicePropValueEx | Extended codes |
| `0x943C` | SetDevicePropValueEx | Extended codes only. An Ex write of a 2-byte recording-format property makes the ZR close the connection |

Pickers write back the camera's own advertised raw values; codec and resolution
are never hand-packed.

## Live view, record and focus

| Opcode | Name | Notes |
| --- | --- | --- |
| `0x9201` | StartLiveView | Then poll DeviceReady |
| `0x9202` | EndLiveView | Sent whenever the feed is fully hidden |
| `0x9428` | GetLiveViewImageEx | Header plus JPEG, see [live view](../live-view/) |
| `0x920A` | StartMovieRecInCard | No parameters, no data |
| `0x920B` | EndMovieRec | No parameters, no data |
| `0x9205` | ChangeAfArea | `p1` x, `p2` y in the header's coordinate space |
| `0x90C1` | AfDrive | One-shot AF |
| `0x9206` | AfDriveCancel | |
| `0x9204` | MfDrive | Focus-by-wire step for the on-feed focus dial |
| `0x9425` | EndTracking | ZR-only [verify-on-HW] |
| `0x9426` | ChangeAELock | |
| `0x941C` | GetEventEx | Nikon event queue poll, `p1 = 0` clears it |
| `0x90C7` | GetEvent | Older event poll |

A focus drive holds the single command channel, so its retries are budgeted in
wall-clock time and a tap-to-focus pre-empts an in-flight drive.

## Still capture

| Opcode | Name | Notes |
| --- | --- | --- |
| `0x9207` | InitiateCaptureRecInMedia | Preferred still release; `p1` capture sort, `p2` card destination |
| `0x100E` | InitiateCapture | Standard fallback |
| `0x90C0` | InitiateCaptureRecInSdram | Capture into camera memory |
| `0x90CB` | AfAndCaptureRecInSdram | AF, then capture into memory |
| `0x920C` | TerminateCapture | Ends bulb or open capture |
| `0x9445` / `0x9446` / `0x9447` | Initiate / Terminate / GetOpenCaptureInfo | Interval and focus-shift capture on Gen 3 [verify-on-HW] |

## Media

| Opcode | Name | Notes |
| --- | --- | --- |
| `0x9209` | GetVendorStorageIDs | Card-present storage IDs. Standard `GetStorageIDs` reports placeholder slots |
| `0x1004` | GetStorageIDs | |
| `0x1005` | GetStorageInfo | Capacity and free space |
| `0x1007` | GetObjectHandles | `p1` storage, `p2` format filter, `p3` association |
| `0x1008` | GetObjectInfo | Filename, size, dimensions, capture date |
| `0x100A` | GetThumb | Embedded JPEG thumbnail |
| `0x101B` | GetPartialObject | 32-bit offset and length |
| `0x9421` | GetObjectSize | 64-bit size [verify-on-HW] |
| `0x9431` | GetPartialObjectEx | 64-bit offset and length as low/high words [verify-on-HW] |
| `0x100B` | DeleteObject | Protected objects are refused |
| `0x9803` / `0x9804` | Get / SetObjectPropValue | Star rating on a card object, see [media](../media/) |

## Key device properties

| Code | Property | Notes |
| --- | --- | --- |
| `0xD1A4` | LiveViewProhibitionCondition | Why live view cannot start |
| `0xD1AC` | LiveViewImageSize | Stream preset: 1 about QVGA, 2 about VGA, 3 about XGA |
| `0xD1BC` | LiveViewImageCompression | Quality bias, six grade and priority values |
| `0xD0A4` | MovieRecProhibitionCondition | Why recording cannot start |
| `0xD0A0` / `0xD0AF` | Movie screen size / file type | Resolution, frame rate and codec |
| `0xD1A6` | LiveViewSelector | 0 photo, 1 video. Read often so the chrome follows the body's lever |
| `0xD1AA` | Movie ISO | Rejected on R3D NE |
| `0x0001_D09D` / `0x0001_D09E` | Movie base ISO / dual-base ISO | ZR-only [verify-on-HW] |
| `0xD0AD` | Movie ISO auto | On/off, independent of exposure program |
| `0x0001_D074` | Movie shutter mode | 1 speed, 2 angle. ZR-only |
| `0xD1A8` / `0x0001_D075` | Movie shutter speed / angle | Angle is ZR-only |
| `0xD1A9` | Movie f-number | |
| `0xD23A` / `0xD21A` | Movie white balance / color temperature | Tint fine-tune is one property per WB mode, app-decoded [verify-on-HW] |
| `0xD1FA` / `0xD1F8` | Movie focus mode / AF-area mode | App-decoded tables [verify-on-HW] |
| `0x0001_D005` / `0x0001_D006` | Subject detection (still / movie) | |
| `0xD0A2`, `0xD0A8`, `0xD0AA`, `0xD23D` | Microphone, level, wind filter, attenuator | [verify-on-HW] |
| `0x0001_D04D`, `0x0001_D065`, `0x0001_D070` | Audio input, 32-bit float, input sensitivity | ZR-only [verify-on-HW] |
| `0xD1F9` / `0xD314` | Movie VR / electronic VR | |
| `0x5001` | BatteryLevel | The ZR reports 1, 20, 40, 60, 80 or 100 |
| `0xD101` | AC power | Non-zero on external or USB power |
| `0xD102` | WarningStatus | Bitfield shown as OK or CHECK; bit meanings [verify-on-HW] |
| `0x5011` | DateTime | Read at connect; set once when drifted more than five seconds, never while recording |
| `0xD1B1` / `0xD1B3` | Exposure indicator / lit state | 1/6 EV steps; undefined while unlit |
| `0xD1F0` | ApplicationMode | Gen 1 app control, a write of 1 |

Photo mode adds the standard still properties (`0x5003` image size through
`0x5013` drive mode), still focus, ISO auto, shutter, card slot, RAW
compression, image area, Picture Control and remaining shots. Model-specific
values: [Nikon ZR command comparison](../../devices/zr/commands/).

## Events

| Code | Event | Notes |
| --- | --- | --- |
| `0x4002` | ObjectAdded | One per file; a RAW plus JPEG pair emits two |
| `0x400D` | CaptureComplete | |
| `0x4006` | DevicePropChanged | `p1` is the property code. Schedules one read |
| `0xC10A` | MovieRecordStarted | Also caught from the live-view header |
| `0xC108` | MovieRecordComplete | |
| `0xC105` | MovieRecordInterrupted | `p1` is a raw camera error. Nikon does not publish the table; the app shows it rather than guessing |

## Response codes

| Code | Meaning |
| --- | --- |
| `0x2001` | OK |
| `0x2019` | Device busy; transient during lens start-up or a drive |
| `0x2013` | Access denied; the current mode disallows it |
| `0x201E` | Session already open; success over USB on iOS |
| `0xA004` | Invalid status |
| `0xA00B` | Not in live view |
| `0xA00C` / `0xA00E` | MF drive hit the end / step too small |
| `0xA021` / `0xA022` | Store error / unformatted card |
| `0xA200`, `0xA201`, `0xA202` | Bulb, silent or movie-frame release busy |
