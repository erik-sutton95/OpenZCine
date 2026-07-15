# Android RAW crop-mode investigation

Status: **IMPLEMENTED, hardware verification pending**

Scope: Android's Swift facade and Compose-facing recording-format presentation. No iOS app-shell
code is changed by this work.

Tracked by Kaneo OPE-95.

## Finding

Nikon ZR does not use a separate selectable video image-area control for N-RAW or R3D NE. Nikon
states that image area follows the selected frame size/frame rate for those RAW formats, and its
ordinary `Image area > Choose image area` setting does not apply. Nikon's RAW mode table documents
the FX 6048×3402 and 4032×2268 modes, plus the DX 3984×2240 modes.

Sources:

- [Nikon ZR video image area options](https://onlinemanual.nikonimglib.com/zr/en/19-11.html)
- [Nikon ZR RAW frame-size and frame-rate options](https://onlinemanual.nikonimglib.com/zr/en/19-02.html)

The user-visible issue was therefore not a missing independent crop control. Android loaded the
camera's `MovScreenSize` (`D0A0`) descriptor at connection time, but a confirmed codec
(`MovFileType`, `D0AF`) change did not immediately reload that codec-dependent descriptor. Until a
later timed refresh, Android could show the old codec's available frame-size modes.

## Android behavior

- After every confirmed codec write, camera-originated codec property event, or newly detected
  codec change during normal polling, Android reloads `D0A0` and re-reads the active screen-size
  value before publishing the next property snapshot.
- The existing resolution/frame-rate picker shows `[FX]` for device-advertised 6048×3402 and
  4032×2268 modes, and `[DX]` for device-advertised 3984×2240 modes, but only for an identified
  Nikon ZR while N-RAW or R3D NE is active.
- The picker still writes the exact 64-bit descriptor value supplied by the camera. There is no
  synthetic crop property or hand-packed frame-size value.
- Unknown bodies, non-RAW codecs, and unrecognised dimensions retain their existing generic labels.

The fake ZR now supports codec-specific screen-size descriptor domains. The regression test changes
from H.265 to R3D NE and N-RAW, verifies the immediate descriptor reload and FX/DX labels, then
verifies that selecting the DX mode writes its exact advertised raw value.

## Hardware follow-up

**[VERIFY-ON-HW]** With a supported Nikon ZR over Wi-Fi and USB-C, switch among H.265, N-RAW, and
R3D NE and confirm that every available frame-size option refreshes immediately, displays the
camera's FX/DX semantics correctly, and is accepted by the camera. Do not probe or write possible
Nikon crop-related properties until a real ZR descriptor capture establishes their meaning in RAW
video.
