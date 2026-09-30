---
title: ZR shooting modes and formats
description: Codec and frame-size descriptors, RAW FX/DX modes, photo mode, release modes, image quality and vertical shooting on the Nikon ZR.
---

Part of the [Nikon ZR reference](../).
Read the overview for firmware, survey scope and evidence levels.

## Codec and container

The recording codec is `MovieFileType` (`0xD0AF`), a UINT32 that packs three
bytes. OpenZCine decodes it in
[`PTPCameraProperties.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/PTPCameraProperties.swift):

```text
MovieFileType: [unused:u8] [codec:u8] [bit depth:u8] [container:u8]
Example: 0x0001_0A00 = H.265, 10-bit, MOV
```

| Codec byte | Codec | Container byte | Container |
| --- | --- | --- | --- |
| `0x00` | H.264 | `0` | MOV |
| `0x01` | H.265 | `1` | MP4 |
| `0x02` | N-RAW | `2` | NEV |
| `0x10` | ProRes 422 HQ | `3` | R3D |
| `0x11` | ProRes RAW HQ | | |
| `0x31` | R3D NE | | |

The picker offers only the values the body advertises in the property's
descriptor enumeration, and writes the chosen raw value back unchanged. A value
whose codec byte OpenZCine cannot name is dropped from the picker rather than
offered. Identity is the raw value, not the label: a body that advertises H.265
at both 8-bit and 10-bit gets one H.265 row with a bit-depth pair, and each depth
writes its own advertised value
([#276](https://github.com/erik-sutton95/OpenZCine/issues/276)). The depth is
read from the packed depth byte, never inferred from the label.

## Frame size and rate

`MovieRecordScreenSize` (`0xD0A0`) is an 8-byte value:

```text
bits 48-63: width   bits 32-47: height   bits 16-23: frame rate
```

The body enumerates its accepted combinations in the descriptor (form flag
`0x02`, a UINT16 count, then 8-byte values). OpenZCine labels each one
("6K · 25p") and drops implausible entries (width outside 640 to 8192, height
outside 360 to 5000, rate outside 1 to 240) so a misanchored parse cannot surface
a value to write. Some Nikon Ex responses append a short tail after the
enumeration; the parser accepts a tail of up to 64 bytes.

**Observed:** writing a combination the body did not advertise, such as 6K at
60p, makes the ZR close the connection. Writing the 2-byte `MovScreenSize` or
`MovFileType` with the Ex operation also closes it. Both go through
`SetDevicePropValue` (`0x1016`) during live view via the safe-point write queue.

The frame-size domain depends on the codec. After a codec change the descriptor
must be reloaded before the frame-size picker is trusted; Android now reloads
`0xD0A0` after every confirmed codec write or camera codec event
([investigation](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/investigations/android-raw-crop-modes.md)).

### RAW image area

The ZR has no separate writable image-area control for N-RAW or R3D NE. Nikon
documents that the image area follows the selected frame size and rate for those
formats: FX modes at 6048×3402 and 4032×2268, and DX modes at 3984×2240
([Nikon ZR online manual](https://onlinemanual.nikonimglib.com/zr/en/19-02.html)).
Both apps tag those exact advertised modes `[FX]` or `[DX]`, only for an
identified ZR with a RAW codec active, and still write the camera's own 64-bit
value. There is no synthetic crop property.

The labelling is **synthetic** (fake-camera regression test).
`[verify-on-HW]`: switching H.265, N-RAW and R3D NE on a real ZR over Wi-Fi and
USB-C and confirming the refreshed options are accepted. Do not probe or write
possible crop-related properties until a real descriptor capture establishes
their meaning.

## Photo mode

`LiveViewSelector` (`0xD1A6`, UINT8) reports the photo/video lever: `0` photo,
`1` video. The monitor re-reads it every other poll tick so the app swaps
between cinema and photography controls within about a second of the lever
moving. In photo mode the app polls the stills properties instead of the movie
ones. `[verify-on-HW]`: remote mode may also write the selector; PC-camera mode
may only report the physical lever.

**Observed:** the stills enumerations (stills shutter, photo white-balance
presets, image sizes) are always rejected while the ZR is in movie mode. That
rejection is expected and must not mark the camera as unsupported.

### Release modes

`StillCaptureMode` (`0x5013`) values, in the body's own release order:

| Value | Mode |
| --- | --- |
| `0x0001` | Single |
| `0x8010` | Continuous L |
| `0x0002` | Continuous H |
| `0x8019` | Continuous H+ |
| `0x810F`, `0x811E`, `0x813C`, `0x8178` | C15, C30, C60, C120 high-speed frame capture (body-dependent) |
| `0x8011` | Self-timer |
| `0x8100` | Quick (release-mode dial position) |

The ZR enumerates these by raw value, which interleaves them (Single, CH, CL,
Self-timer, CH+). The drive picker keeps the advertised set but applies release
order, and removes Self-timer and Quick: the app's timer tab owns the countdown,
and Quick is a dial-only position
([#274](https://github.com/erik-sutton95/OpenZCine/issues/274)).

### Image quality

| Property | Values |
| --- | --- |
| `CompressionSetting` `0x5004` | `0` to `5` JPEG Basic / Normal / Fine, each plain (size priority) or ★ (optimal quality); `6` TIFF; `7` RAW; `8` to `13` RAW+JPEG at each grade. `[verify-on-HW]` |
| `RawCompressionType` `0xD016` | `0` Lossless compression, `1` Compressed, `2` Uncompressed, `3` High efficiency★, `4` High efficiency. Union across generations; current bodies use `0`, `3`, `4`. `[verify-on-HW]` |
| `CaptureAreaCrop` `0xD030` | Photo image area (FX, DX, 1:1, 16:9). |
| `ActivePicCtrlItem` `0xD200` | `1` to `11` built-in picture controls, `101` to `120` creative, `201` to `209` registered custom. |
| `StillToneMode` `0x0001_D01C` | `0` SDR, `2` HLG. Drives the photo-mode exposure assists; bodies without it stay SDR. |
| `ExposureRemaining` `0xD1F1` | Frames recordable to the card; the photo shots-remaining counter. |

User banks U1 to U3 are offered only when the `ExposureProgramMode` descriptor
advertises them; the Zf, for example, never gets a U bank it does not have.

## Vertical shooting

Byte 839 of the live-view header reports how the body is held, with the same
enumeration as the read-only `Orientation` property (`0xD10E`):

| Value | Body position | Feed rotation |
| --- | --- | --- |
| `0` | Landscape, or auto-rotate off | None |
| `1` | Portrait, grip up (rotated 90° counter-clockwise) | Rotate to read upright |
| `2` | Portrait, grip down (rotated 90° clockwise) | Rotate to read upright |
| `3` | Upside down | 180° |

Both apps use this to rotate the monitoring picture and switch to a portrait
layout. **Auto-Rotate Feed** in Settings > Controls turns the rotation off; the
recording is never affected. `[verify-on-HW]`: the polarity was confirmed on
paper (axis map and EXIF cross-check), not yet against a physically rotated ZR.
