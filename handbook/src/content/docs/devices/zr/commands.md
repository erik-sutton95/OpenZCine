---
title: ZR command comparison
description: Index of the PTP operation and property families used with the Nikon ZR, and model-specific differences.
---

Use this index with the [ZR evidence levels](../) and the
[shared command catalog](../../../protocol/commands/). Follow each link for
value tables, restrictions and remaining limits. A shared operation code does
not establish a shared property domain or feature set.

## Command families

| Family | Operations and properties | ZR evidence |
| --- | --- | --- |
| Session and identity | `GetDeviceInfo` `0x1001`, `OpenSession` `0x1002`, `CloseSession` `0x1003` | Cited. DeviceInfo is probed right after `OpenSession` and gates the rest of the sequence ([connection](../connection/#connection-sequence)). |
| Network pairing | `GetPairingInfo` `0x952B`, `ConfirmPairing` `0x935A` | `[ZR-only · verify-on-HW]` codes; the first pairing on a physical ZR shows a PIN on the camera ([pairing](../connection/#pairing)). |
| App control mode | `ChangeApplicationMode` `0x9435`, `ChangeCameraMode` `0x90C2` | `0x9435` on Wi-Fi; `0x90C2` p1 `1` selects remote mode over USB ([USB-C](../connection/#usb-c)). |
| Vendor code discovery | `GetVendorCodes` `0x9439` (p1 `0x0D` for the property list) | Generation 3 surface; vendor properties never appear in the standard DeviceInfo array. |
| Property read and write | `GetDevicePropDesc` `0x1014`, `GetDevicePropValue` `0x1015`, `SetDevicePropValue` `0x1016`; Ex forms `0x943A` to `0x943C` | 2-byte `0xDxxx` codes use the standard ops; 4-byte `0x0001_Dxxx` codes use the Ex ops. See [below](#differences-to-preserve). |
| Live view | `StartLiveView` `0x9201`, `EndLiveView` `0x9202`, `GetLiveViewImageEx` `0x9428`, `DeviceReady` `0x90C8` | Observed. Header offsets confirmed against raw ZR dumps ([live view](../../../protocol/live-view/)). |
| Movie record | `StartMovieRecInCard` `0x920A`, `EndMovieRec` `0x920B` | No parameters and no data phase. Recording state also arrives in every live-view header. |
| Recording format | `MovieRecordScreenSize` `0xD0A0`, `MovieFileType` `0xD0AF` | Write only camera-advertised raw values ([formats](../modes/#codec-and-container)). |
| Exposure | `MovieExposureIndex` `0xD1AA`, `MovieISOSensitivity` `0x0001_D09E`, `MovieBaseISO` `0x0001_D09D`, `MovISOAutoControl` `0xD0AD`, `MovieShutterMode` `0x0001_D074`, `MovieShutterSpeed` `0xD1A8`, `MovieShutterAngle` `0x0001_D075`, `MovieFNumber` `0xD1A9` | [Exposure](../settings/#exposure). Dual-base and angle codes are ZR-only and `[verify-on-HW]`. |
| White balance | `MovieWhiteBalance` `0xD23A`, `MovieWBColorTemp` `0xD21A`, per-mode tune properties `0xD212` to `0xD23C` | [White balance](../settings/#white-balance). Tint encoding is app-decoded. |
| Focus | `MovieFocusMode` `0xD1FA`, `MovieFocusMeteringMode` `0xD1F8`, `MovieAFSubjectDetection` `0x0001_D006`; `ChangeAfArea` `0x9205`, `AfDrive` `0x90C1`, `AfDriveCancel` `0x9206`, `MfDrive` `0x9204`, `EndTracking` `0x9425` | [Focus tables](../settings/#focus) and [drive controls](../controls/). |
| Audio | `MovMicrophone` `0xD0A2`, `MovWindNoiseReduction` `0xD0AA`, `MovieAttenuator` `0xD23D`, `AudioInputSelection` `0x0001_D04D`, `Movie32BitFloatAudioRecording` `0x0001_D065`, `MovieAudioInputSensitivity` `0x0001_D070` | [Audio](../settings/#audio). The ZR-only codes are `[verify-on-HW]`. |
| Stabilization | `MovieVibrationReduction` `0xD1F9`, `ElectronicVR` `0xD314` | [Stabilization](../controls/#stabilization). The VR value table is ZR-only and `[verify-on-HW]`. |
| Stills | `LiveViewSelector` `0xD1A6`, `InitiateCaptureRecInMedia` `0x9207`, `TerminateCapture` `0x920C`, `StillCaptureMode` `0x5013`, `CompressionSetting` `0x5004`, `RawCompressionType` `0xD016` | [Photo mode](../modes/#photo-mode) and [still release](../controls/#still-release). |
| Events | `GetEventEx` `0x941C`, `GetEvent` `0x90C7`; `DevicePropChanged` `0x4006`, `ObjectAdded` `0x4002`, `CaptureComplete` `0x400D`, movie events `0xC105` / `0xC108` / `0xC10A` | Body-side dial changes arrive as `0x4006`; body-fired stills are read from the event poll. |
| Storage and objects | `GetVendorStorageIDs` `0x9209`, `GetObjectHandles` `0x1007`, `GetObjectInfo` `0x1008`, `GetThumb` `0x100A`, `GetPartialObject` `0x101B`, `GetPartialObjectEx` `0x9431`, `GetObjectSize` `0x9421`, `DeleteObject` `0x100B`, `Get/SetObjectPropValue` `0x9803` / `0x9804` | [Original media](../media/). The large-object ops are `[verify-on-HW]`. |
| Body status | `BatteryLevel` `0x5001`, `DateTime` `0x5011`, `ACPower` `0xD101`, `WarningStatus` `0xD102`, `ExposureIndicateStatus` `0xD1B1` | [Coverage](../coverage/#general-status-and-remaining-work). The overheat bit is unknown. |

## Differences to preserve

| Area | Model-specific boundary |
| --- | --- |
| Property op width | A 2-byte recording-format property written with `SetDevicePropValueEx` makes the ZR close the connection. Always route 2-byte codes through `SetDevicePropValue` (`0x1016`). Generation 1 and 2 bodies do not implement the Ex ops at all ([generation 1](../../gen-1/connection/)). |
| Recording format | Never hand-pack a frame size or codec. An unadvertised combination (for example 6K at 60p) makes the ZR close the connection. Write the exact 8-byte `MovScreenSize` or 4-byte `MovFileType` value from the body's descriptor. |
| Movie ISO | Under R3D NE the body rejects `MovieExposureIndex` and uses `MovieISOSensitivity` on the active base circuit. Other codecs use `MovieExposureIndex` ([exposure](../settings/#exposure)). |
| Shutter | Speed and angle are separate properties. Writing the one that does not match `MovieShutterMode` flips the body's mode as a side effect. |
| White balance | A Kelvin value takes two writes: `MovieWhiteBalance` to Color temp, then `MovieWBColorTemp`. The temperature alone leaves the body on its current preset. |
| Camera authority | Connecting must not reconfigure a body. A Z 6III on shutter angle stays on angle after a session with a Z5II on speed ([#257](https://github.com/erik-sutton95/OpenZCine/issues/257), synthetic wire test). |
| Live-view header | Generation 3 bodies use a 1024-byte display-info header, confirmed on the ZR. Generation 1 uses 512 bytes, confirmed on a Z 7. |

The [coverage and implementation reference](../coverage/) records what still
needs qualification. A cited code, an accepted write, a camera readback and an
inspected file remain distinct evidence.
