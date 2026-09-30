---
title: ZR exposure, focus and audio
description: Dual-base ISO, Auto ISO, shutter angle and speed, white balance, focus and AF-area tables, and audio properties on the Nikon ZR.
---

Part of the [Nikon ZR reference](../).
Read the overview for firmware, survey scope and evidence levels.

## Exposure

### ISO by codec

The ZR keeps dual-base sensitivity hardware in every codec, but exposes it
differently. The rules live in
[`ISOPickerPolicy.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/ISOPickerPolicy.swift):

| Codec | ISO write | Picker | Auto ISO |
| --- | --- | --- | --- |
| R3D NE | `MovieISOSensitivity` `0x0001_D09E`, range follows the active base circuit | Separate Low and High drums | Not available; always manual, in every exposure mode |
| N-RAW, ProRes, H.264, H.265 | `MovieExposureIndex` `0xD1AA` (R3D NE rejects it) | One drum with native-base markers | `MovISOAutoControl` `0xD0AD` On/Off; manual ISO only in exposure mode M |

| Base circuit | `MovieBaseISO` `0x0001_D09D` | Steps | Native marker |
| --- | --- | --- | --- |
| Low | `1` | 200 to 3200 in third stops | 800 |
| High | `2` | 1600 to 25600 in third stops | 6400 |

While Auto ISO is on, the readout shows the live working ISO with an `A`
prefix. Under R3D NE the body's Auto ISO flag keeps its last value from another
codec while inert, so the app ignores it there. A manual ISO write while Auto is
active first turns Auto off, then writes the value. Movie ISO Auto is
independent of the exposure program (`0x500E` Auto).

The dual-base and ZR-only codes are `[ZR-only · verify-on-HW]` in source. Nikon's
ZR RAW video guide describes the R3D base circuits
([online manual](https://onlinemanual.nikonimglib.com/zr/en/19-12.html)).

### Shutter and iris

`MovieShutterMode` (`0x0001_D074`, UINT8) selects `1` speed or `2` angle. Speed is
`MovieShutterSpeed` (`0xD1A8`, numerator and denominator packed); angle is
`MovieShutterAngle` (`0x0001_D075`, degrees × 100). `MovieTVLockSetting`
(`0x0001_D00F`) is the body's speed/angle lock. The value write must target the
property that matches the current mode; writing the other flips the mode.

Iris is `MovieFNumber` (`0xD1A9`, f-number × 100). The picker uses the camera's
enumerated f-numbers, which cover only stops valid for the mounted lens. Until
they arrive it falls back to a third-stop ladder from the lens's marked maximum
aperture (parsed from the lens descriptor) to f/22.

### Exposure mode and camera-owned values

`ExposureProgramMode` (`0x500E`, UINT16) follows the libgphoto2 table:

| Value | Label | Value | Label |
| --- | --- | --- | --- |
| `0x0001` | M | `0x8010` | Auto |
| `0x0002` | P | `0x8050` | U1 |
| `0x0003` | A | `0x8051` | U2 |
| `0x0004` | S | `0x8052` | U3 |

Scene values `0x8011` to `0x8019` decode for display but are not offered.
`[verify-on-HW]`: whether the ZR's movie mode dial reports through this stills
property.

**Observed (field report):** in A, P, S and Auto, Nikon bodies often do not
announce camera-owned shutter, ISO and iris changes on `DevicePropChanged`
(`0x4006`). A photo A-mode body read 1/30 and ISO 1000 while the app still
showed 1/125 and A900. Both apps now re-read that set on a bounded cadence, one
property per tick, and skip it in M with manual ISO
([`CameraAutoExposureReadouts.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/CameraAutoExposureReadouts.swift)).

`ExposureIndicateStatus` (`0xD1B1`, INT8) is the body's exposure meter in 1/6 EV
steps (±60 is ±10 EV). It is only defined while `ExposureIndicateLightup`
(`0xD1B3`) reads `0` (lit). It feeds the photo-mode EV meter.

## White balance

`MovieWhiteBalance` (`0xD23A`) modes:

| Value | Mode | Value | Mode |
| --- | --- | --- | --- |
| `0x0002` | Auto | `0x8010` | Cloudy |
| `0x0004` | Sunny | `0x8011` | Shade |
| `0x0005` | Fluorescent | `0x8012` | Color temp |
| `0x0006` | Incandescent | `0x8013` | Preset |
| `0x0007` | Flash | `0x8016` | Natural auto |

- **Kelvin.** `MovieWBColorTemp` (`0xD21A`, UINT16 Kelvin). Range 2500 to 10000 K
  per the ZR Reference Guide. The drum mirrors the body dial's ~10 mired steps,
  so it shows 5560 K rather than a round 5600 K. Select Color temp first, then
  write the temperature.
- **Tint.** One fine-tune property per mode (`0xD212` Auto to `0xD23C` Natural;
  stills `0xD017` to `0xD15E`), decoded as a 13×13 tune grid. libgphoto2 has the
  codes but no value tables, so the encoding is app-decoded and `[verify-on-HW]`.
- **R3D NE.** **Observed:** the ZR's own white-balance menu hides Auto and
  Natural auto while recording R3D NE, so the picker drops them there.
  `[verify-on-HW]`: whether N-RAW and ProRes RAW share the restriction.

## Focus

Value tables for movie AF are app-decoded (libgphoto2 has no `config.c` tables)
and `[verify-on-HW]`.

| `MovieFocusMode` `0xD1FA` | Label |
| --- | --- |
| `0` | AF-S |
| `1` | AF-C |
| `2` | AF-F (full-time servo) |
| `3` | MF, fixed by a lens focus-ring override |
| `4` | MF, selected in the menu or app (the value the app writes) |

After a lens focus-ring override the body can narrow its advertised focus-mode
list to MF only. The picker keeps offering AF-S, AF-C, AF-F and MF so AF stays
reachable.

| `MovieFocusMeteringMode` `0xD1F8` (AF area) | Label |
| --- | --- |
| `0x8010` | Single |
| `0x8011` | Auto |
| `0x8018` / `0x8019` | Wide-S / Wide-L |
| `0x801E` / `0x801F` | Wide-C1 / Wide-C2 |
| `0x8033` | Subject tracking |

Stills add Dyn-S `0x0002`, 3D tracking `0x8012`, Dyn-M `0x8013`, Dyn-L `0x8014`
and Pinpoint `0x8017`.

`MovieAFSubjectDetection` (`0x0001_D006`, UINT8): `0` Off, `1` Auto, `2` People,
`3` Animal, `4` Vehicle, `5` Bird, `6` Airplane. Subject detection is a
different setting from the Subject tracking AF area; the picker names them
apart ([#274](https://github.com/erik-sutton95/OpenZCine/issues/274)).

## Audio

| Property | Values | Evidence |
| --- | --- | --- |
| `MovMicrophone` `0xD0A2` | `0` Auto, `1` High, `2` Medium, `3` Low, `4` Off | libgphoto2 table |
| `MovRecordMicrophoneLevelValue` `0xD0A8` | Manual level, shown as a number | App-decoded |
| `MovWindNoiseReduction` `0xD0AA` | `0` Off, non-zero On | App-decoded |
| `MovieAttenuator` `0xD23D` | `0` Off, non-zero On | App-decoded |
| `AudioInputSelection` `0x0001_D04D` | `1` mic, `2` line | `[ZR-only · verify-on-HW]` |
| `Movie32BitFloatAudioRecording` `0x0001_D065` | `0` / `1` | `[ZR-only · verify-on-HW]` |
| `MovieAudioInputSensitivity` `0x0001_D070` | `0xFF` Auto, `1` to `20` manual; the body refuses `0` | `[ZR-only · verify-on-HW]` |

### Level meters, not program audio

Live audio monitoring is not possible over PTP-IP. The live-view object carries
a JPEG and a metadata header, not audio, and the ZR does not advertise the PTP
streaming operations (`GetStream`, `GetStreamInfo`)
([feasibility note](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/live-audio-monitoring.md)).
Program audio leaves the body only through its headphone jack and HDMI.

What the header does carry is the body's own segmented meter: four bytes at
offsets 824 to 827, peak-hold then current, left and right, each `0` to `14`
(`0` is silence). The apps draw these as VU meters. The mapping of segments to
dBFS (segment 14 at 0 dBFS, evenly spaced in dB) is `[ZR · verify-on-HW]`.

## Tone curves for assists

False color, waveform, parade, histogram and Traffic Lights read the live
picture against the recording's transfer curve: RED Log3G10 for R3D NE, Nikon
N-Log for N-Log modes, and SDR or HLG otherwise. Curve sources and exposure
anchors are summarized in the
[Log3G10 and N-Log reference](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/red-log3g10-reference.md).
