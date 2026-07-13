# RED Log3G10 and exposure tools reference

Engineering summary for OpenZCine's Log3G10- and N-Log-aware exposure assists (R3D/N-RAW proxies,
false colour, waveform/parade/histogram, traffic lights). This document links to the manufacturers'
official sources and records how the portable core maps camera signal values onto operator-facing
scales.

> **Copyright:** RED's white papers and manuals are proprietary. This file is a short summary plus
> links — not a redistribution of RED PDFs or full curve tables.

## Official sources

| Document | URL |
| --- | --- |
| **White Paper on REDWideGamutRGB and Log3G10** (Rev C) | [docs.red.com PDF](https://docs.red.com/955-0187/PDF/915-0187%20Rev-C%20%20%20RED%20OPS%2C%20White%20Paper%20on%20REDWideGamutRGB%20and%20Log3G10.pdf) |
| **IPP2 overview** (Log3G10 intro, RWG context) | [RED support article](https://support.red.com/hc/en-us/articles/115004913827-IPP2-Overview) |
| **In-camera exposure tools** (goal posts, traffic lights) | [RED 101 — Exposure with RED Cameras](https://www.red.com/red-101/red-camera-exposure-tools) |
| **False Color Video Mode** (published IRE zones) | [RED operation guide](https://docs.red.com/955-0215/955-0215_V1.3.6_Rev-A%20RED%20PS%2C%20V-RAPTOR%20RHINO%208K%20S35%20Operation%20Guide%20HTML/Content/4_Menus/d_Monitor/False_Color_Video_Mode.htm) |
| **RED ONE Build 20 firmware notes** (legacy stop landmarks) | [RED firmware history](https://www.red.com/download/red-one-firmware) |
| **IPP2 pipeline stages** (Log3G10 in primary raw development) | [docs.red.com PDF](https://docs.red.com/915-0190/915-0190%20Rev-D%20%20%20RED%20OPS%2C%20IPP2%20Image%20Pipeline%20Stages.pdf) |
| **N-Log Specification Document** (curve, N-Gamut) | [Nikon Download Center PDF](https://download.nikonimglib.com/archive3/deHU500g8zYS03Crat379bMLUc33/N-Log_Specification_%28En%2901.pdf) |
| **N-Log exposure guide** (code 372 / approximately 35% middle grey) | [Nikon technical guide](https://onlinemanual.nikonimglib.com/technicalguide/log_raw/video_recording_editing/en/correct_exposure_10.html) |
| **Log/RAW Technical Guide** (ZR Log3G10/N-Log exposure, ISO behavior, dynamic-range charts) | [Nikon PDF](https://onlinemanual.nikonimglib.com/technicalguide/log_raw/video_recording_editing/en/pdf/TG_Log-RAW_%28En%2902.pdf) |
| **ZR RAW video guide** (R3D base circuits and early overexposure warning) | [Nikon online manual](https://onlinemanual.nikonimglib.com/zr/en/19-12.html) |
| **ZR brightness display** (ISO-dependent R3D warning line) | [Nikon online manual](https://onlinemanual.nikonimglib.com/zr/en/09-05-94.html) |

The implementation was additionally checked page-by-page against Nikon's supplied February 2026
`R3D_NE_datasheet_for_Zebra_pattern_FU1_1_En(De)01.pdf` and October 2025
`Nikon_Log-RAW_(En)01.pdf`. Those local reference files remain under the gitignored `ref/` directory
and are not redistributed.

## Log3G10 — key facts

Log3G10 is RED's IPP2 log encoding for **REDWideGamutRGB (RWG)** camera data. The name encodes two
design targets:

- **3G** — 18% mid grey (linear light `0.18`) maps to **one third** of the normalized code range
  (`1/3` ≈ `0.333333`).
- **10** — the curve reaches encoded value **1.0** at **10 stops above mid grey** (linear light
  `0.18 × 2^10 = 184.32`).

### Curve parameters (from the white paper)

| Symbol | Value | Role |
| --- | --- | --- |
| `a` | `0.224282` | Log slope |
| `b` | `155.975327` | Linear-to-log scale |
| `c` | `0.010` | Toe offset |
| `g` | `15.1927` | Linear extension gradient below `-c` |

Encode (linear light → Log3G10):

```text
x' = x + c
if x' < 0:  output = x' × g
else:       output = a × log10(x' × b + 1)
```

Decode is the inverse (see `Log3G10` in `ExposureScale.swift` — constants match the white paper).

### Reference mapping values (normalized 0–1 encoded)

| Linear light input | Log3G10 encoded |
| --- | --- |
| `-0.010` | `0.000000` |
| `0.000` | `0.091551` |
| **`0.180` (18% grey)** | **`0.333333`** |
| `1.000` | `0.493449` |
| **`184.322` (10 stops above mid grey)** | **`1.000000`** |

On an 8-bit axis, mid grey lands near **native code 85** (`0.333 × 255`). The **mathematical**
encoding ceiling is native **255** at linear `184.32` — this is the top of the Log3G10 container,
not where a given sensor/ISO actually clips in camera.

### Relation to Rec.709

Log3G10 is a **log encoding**, not a display gamma. Grading to Rec.709 (or Rec.2020, ACES, etc.)
requires a **color-space transform** from RWG plus an output transform / tone map. The white paper
publishes 3×3 matrices between RWG and Rec.709 (and Rec.2020, ACES AP0). OpenZCine's generated
RWG/Log3G10→Rec.709 monitor LUTs follow that path in `MonitorLUT` / `LUTLibrary`.

False colour intentionally measures the **incoming log signal before a display LUT**. It decodes
each channel first and then forms scene-linear luminance using RED's published RWG→XYZ Y row
(`[0.286694, 0.842979, −0.129673]`). Applying Rec.709 weights directly to Log3G10-encoded RGB is
mathematically invalid because both the transfer function and source gamut are wrong at that point.

## REDWideGamutRGB (brief)

RWG is RED's standardized camera RGB space: primaries and D65 white point are defined in the white
paper, with published matrices to/from XYZ, ACES AP0, Rec.709, and Rec.2020. Nikon ZR R3D NE
footage is Log3G10-encoded in an RWG-compatible pipeline; OpenZCine treats **`ExposureToneCurve.redLog3G10`**
as the default assist curve for that feed.

## Nikon N-Log (brief)

Nikon defines N-Log as a 10-bit code curve over scene reflectance (`0.18` == stop 0), with N-Gamut
equal to BT.2020/D65. The published encode is:

```text
if y < 0.328: x = 650 × (y + 0.0075)^(1/3)
else:         x = 150 × ln(y) + 619
```

Canonical normalized N-Log is `x / 1023`, while operator-facing IRE uses legal video range:
`100 × (x − 64) / 876`. Consequently, true black is code ≈127.23 / **7.22 IRE**, and 18% grey is
code ≈372.03 / **35.16 IRE**. Treating full-code percentage (`x / 1023 × 100`) as IRE mixes domains
and shifts both the floor and stop ruler.

## OpenZCine values vs RED spec

OpenZCine separates five layers that must not be conflated:

1. **RED Log3G10 math** — encode/decode constants match the white paper (`Log3G10` in
   `ExposureScale.swift`).
2. **Canonical encoded code** — normalized Log3G10 float or normalized N-Log 10-bit code.
3. **Raw/log signal IRE** — Log3G10 uses `encoded × 100`; N-Log uses its 64–940 legal range.
4. **Normalized raw-scope IRE** — waveform, histogram, zebra, and traffic-light logic expand the
   useful encoded interval from transfer-function black to the camera's current clipping warning
   across 0–100. This remains a full-range raw/log ruler, distinct from broadcast/legal IRE.
5. **False-colour monitor IRE** — decoded scene luminance passes through OpenZCine's generated
   display transform. It fixes 18% grey at 42 IRE and the current clip at 100 before applying the
   RED Video Mode-style categories.

| Anchor | RED Log3G10 spec | OpenZCine (`ExposureToneCurve.redLog3G10`) | Notes |
| --- | --- | --- | --- |
| 18% mid grey | Encoded **`1/3`** (linear `0.18`) | Signal IRE **≈33.3** (native **≈85**); raw-scope IRE **≈39.4** at ISO 800; false-colour monitor IRE **42** | Raw-scope placement follows available headroom; false colour uses a fixed display anchor |
| Encoding ceiling | Encoded **`1.0`** at linear **184.32** | Not used as clip — would be native **255** | Container top; real highlights clip earlier |
| Practical highlight clip | ISO-dependent sensor clip | Native **145…215** depending on base circuit and metadata ISO; normalized **100%** | Nikon's 3D-LUT-off warning table, not Log3G10 `1.0` |
| Shadow / toe floor | Linear `0.000` → encoded `0.09155` (native ≈23) | Signal IRE **9.16**; normalized **0%** | Derived from `encode(0.0)`, not hand-tuned |
| Legal black (Rec.709 swing) | N/A | Native **16**, below Log3G10 true black, therefore normalized **0%** | Retained only as a named diagnostic reference |

### Nikon R3D NE exposure behavior

Nikon's ZR documentation makes several points that are easy to misread from the compressed native
histogram/waveform:

- The raw circuit records at ISO 800 (low base) or ISO 6400 (high base). The selected ISO is stored
  as R3D metadata, but Nikon still changes the camera's overexposure warning with that metadata ISO.
- Both base circuits follow the same relative warning progression. Representative 8-bit-equivalent
  codes are low-base ISO 200/800/3200 → **145/180/215** and high-base ISO
  1600/6400/25600 → **145/180/215**. `R3DNEHighlightWarning` contains every published step.
- At native base ISO, 18% grey is about code **85** and the highlight warning is about code **180**.
  The fact that usable highlights occupy only the lower portion of the 0–255 container does not mean
  code 255 is a valid clip target.
- Nikon's dynamic-range charts keep approximately 15 stops total while ISO redistributes them around
  neutral grey: low base moves from roughly −10/+5 stops at ISO 200 through −8/+7 at ISO 800 to
  −6/+9 at ISO 3200; high base repeats that pattern at ISO 1600/6400/25600.

OpenZCine does not reproduce the camera's visually compressed 0–70%-ish scope. Its raw scopes
linearly map:

```text
Raw-scope IRE = clamp((native − logBlack) / (currentClip − logBlack), 0, 1) × 100
```

This keeps black at 0 and the current, ISO-correct warning at 100 while preserving all ordering and
relative spacing between them. It also means middle grey correctly moves on the normalized axis as
ISO changes the available highlight headroom.

### Nikon N-Log exposure behavior

Nikon's N-Log mid-grey reference is 10-bit code **372** (about native **93** and approximately 35%
on a conventional legal-range waveform). The published curve places transfer-function black near
10-bit code **127** (native ≈32). At normal ISO, OpenZCine uses nominal legal white, code **940**
(native ≈234), because Nikon does not publish a normal-ISO sensor-clip table.

The ZR guide does publish reduced maximum output for extended-low N-Log settings, so the mapping uses
those exact warnings: Lo 2.0 (ISO 200 equivalent) → native **200**; Lo 1.0 through Lo 0.3 (ISO
400/500/640 equivalent) → native **230**. These are clip endpoints, not middle-grey targets.

Nikon's zebra setup numbers are also code values, not percentages: with the display LUT off, Nikon
recommends approximately **85 ±5** for R3D NE middle grey and **95 ±5** for N-Log middle grey. Those
match the respective 8-bit-equivalent codes (about 85 and 93), while the camera waveform describes
the same patches as roughly 33% and 35%. Treating “zebra 95” as “95 IRE” is therefore a unit error.

### Z-stop placement

`ExposureScale.signalNative(zStop:curve:)` encodes `0.18 × 2^stop` through the selected published
curve. `FalseColorMap` performs the inverse per pixel: decode RGB, form source-gamut luminance, then
calculate `log2(Y / 0.18)`. Z-stop **0** therefore means 18% grey for both Log3G10 and N-Log rather
than an app-defined IRE threshold.

### False-colour bands

The three modes classify different physical quantities:

- **ZC Stops:** sparse, one-third-stop exposure landmarks inspired by the supplied RED ONE Build 20
  reference, but with an independently tuned palette and OpenZCine naming. RED's official notes
  define the landmark meanings and state that other picture values remain luminance-only:

  | Scene exposure | ZC colour | Meaning |
  | --- | --- | --- |
  | Below −5⅚ | Purple | Minimum exposure, centred around −6 |
  | −3 ± ⅙ | Teal | Three stops under 18% grey |
  | 0 ± ⅙ | Green | 18% grey reference |
  | +1 ± ⅙ | Pink | Skin reference; +1 is OpenZCine's explicit assumption |
  | +2 ± ⅙ | Straw | Two stops over 18% grey |
  | M−⅔ ± ⅙ | Yellow | Two-thirds of a stop below mapped maximum |
  | M−⅓ ± ⅙ | Orange | One-third of a stop below mapped maximum |
  | M−⅙ and above | Red | Mapped maximum exposure |

  `M = log2(decoded camera clip / 0.18)`, so the final warnings follow the active Log3G10 or N-Log
  clipping code rather than pretending that +6 is universal. Unmarked values use tone-mapped
  greyscale. Coloured landmarks retain 40% luminance detail rather than becoming flat fields.
- **IRE:** published RED Video Mode integer categories applied to OpenZCine's curve-aware monitor
  IRE. RED publishes the following ranges, but not normative RGB coordinates or feathering values;
  OpenZCine therefore uses an independently tuned, muted palette and smooth transitions:

  | IRE | Colour family | Exposure meaning |
  | --- | --- | --- |
  | 0–4 | Purple | Black clip |
  | 5 | Blue | Just above black clip |
  | 10–12 | Teal | Deep shadow reference |
  | 41–48 | Green | Middle-grey region |
  | 61–70 | Pink | Skin-highlight region |
  | 92–93 | Straw | High highlight |
  | 94–95 | Yellow | Near clip |
  | 96–98 | Orange | Immediate pre-clip warning |
  | 99–100 | Red | Highlight clip |

- **Limits:** four OpenZCine extreme warnings only — purple at 0–4, blue at 5–9, yellow at 94–98,
  and red at 99–100. Pixels between those ranges retain their original encoded RGB colour. This is
  deliberately not labelled RED Exposure Mode: it keeps the earlier OpenZCine requirement for both
  near-limit and terminal-limit warnings over the untouched image.

In the compact iOS reference key, IRE and Limits bands occupy their true proportional positions on
a 0–100 ruler. ZC Stops places its sparse landmarks on a −6-to-mapped-maximum stop ruler. Neutral
gaps progress from shadow to highlight grey; the key layout does not alter classification math.

For all three modes, RGB is first decoded through the codec-selected transfer function, then reduced
to scene-linear luminance in the matching source gamut: REDWideGamutRGB coefficients for Log3G10,
and BT.2020/N-Gamut coefficients for N-Log. ZC Stops calculates `log2(Y / 0.18)` directly.

IRE and Limits feed `Y` through `MonitorDisplayToneMap`, the same original anchored shoulder used by
the generated monitor LUT. The false-colour instance derives scene white from the camera's current
clip code, solves its two anchors exactly, and applies the inverse BT.1886 EOTF:

```text
18% scene grey → 42 monitor IRE
current camera clip → 100 monitor IRE
```

This avoids treating an encoded Log3G10 or N-Log percentage as display IRE. It also means the same
scene patch enters the same false-colour category on both curves. Unpainted ZC Stops and IRE values
use tone-mapped monitor luminance as greyscale; unpainted Limits values retain source colour.

ZC Stops feathers each boundary by ±0.05 stop, leaving a solid centre inside every one-third-stop
landmark. IRE and Limits use ±0.5 IRE smoothstep feathers, so adjacent categories blend and isolated
categories fade cleanly without erasing RED's narrow single-IRE blue reference.

There is no persisted manual signal override. R3D NE is unambiguously Log3G10. Nikon documents that
N-RAW and ProRes RAW can instead use SDR, however, and the current PTP snapshot does not yet expose a
decoded tone-mode property. Consequently the non-R3D log-monitoring path is valid only while the
camera is actually set to N-Log; wiring the body-enumerated tone property is a required protocol
follow-up before claiming automatic SDR/N-Log discrimination.

RED's documented Video Mode runs on the processed monitor/video path. OpenZCine adapts its published
IRE categories to the generated, clip-calibrated monitor transform so raw/log demo and live feeds
remain comparable; this is not a claim of bit-exact RED camera output.

The iOS renderer supplies camera JPEG components to Core Image as unmanaged code data, preventing
the framework's normal sRGB-to-linear input conversion from moving thresholds. All three scales use
a cached 64³ GPU colour cube generated from the same pure mapping code, keeping live view and
playback transitions consistent.

## Code cross-references

| Module | Path | Role |
| --- | --- | --- |
| Log curve math, ISO warning tables, normalized mapping, Z-stops | [`Sources/OpenZCineCore/ExposureScale.swift`](../Sources/OpenZCineCore/ExposureScale.swift) | `ExposureToneCurve`, `R3DNEHighlightWarning`, `ExposureSignalMapping` |
| Shared display/IRE tone map | [`Sources/OpenZCineCore/MonitorDisplayToneMap.swift`](../Sources/OpenZCineCore/MonitorDisplayToneMap.swift) | Exact 18%-grey and current-clip monitor anchors |
| False-colour bands and cube LUT | [`Sources/OpenZCineCore/FalseColor.swift`](../Sources/OpenZCineCore/FalseColor.swift) | Curve selection, source-linear luminance, stop/IRE bands |
| iOS false-colour rendering | [`ios/Runner/ImageEffectsCompositor.swift`](../ios/Runner/ImageEffectsCompositor.swift) | Cached cube application across live, playback, and demo feeds |
| Histogram traffic lights / crush floor | [`Sources/OpenZCineCore/ScopeSampler.swift`](../Sources/OpenZCineCore/ScopeSampler.swift) | Crush/clip edge detection on the reference scale |
| Traffic Lights meter | [`Sources/OpenZCineCore/TrafficLightsMeter.swift`](../Sources/OpenZCineCore/TrafficLightsMeter.swift) | Per-channel goal-post readout |
| Tests | [`Tests/OpenZCineCoreTests/ExposureScaleTests.swift`](../Tests/OpenZCineCoreTests/ExposureScaleTests.swift), [`FalseColorTests.swift`](../Tests/OpenZCineCoreTests/FalseColorTests.swift) | Golden anchors and round-trips |

## Goal posts and traffic lights

RED cameras expose two raw-data edge indicators beside the histogram ([RED 101 article](https://www.red.com/red-101/red-camera-exposure-tools)):

- **Goal posts** — vertical bars at the histogram edges showing **raw** shadow noise and highlight
  clip limits, unaffected by ISO/look settings (unlike the main histogram).
- **Traffic lights** — RGB dots that light when **~2%** of pixels in a channel are clipped (per-channel
  clip visibility).

OpenZCine implements RED-inspired **traffic lights** and crush/clip guides on the normalized
black-to-current-clip scale (`ScopeSampler`, `TrafficLightsMeter`, waveform/parade safe-border
guides). Thresholds are
configurable in assist settings (`OperatorPreferences`). Crush detection anchors at the log toe floor
(`blackIRE`), not native code 0 or legal black — matching the Log3G10 toe behaviour described above.

## Related docs

- [`docs/frameio-setup.md`](frameio-setup.md) — proxy upload (LUT-baked exports use RWG/Log3G10 paths)
- [`docs/live-audio-monitoring.md`](live-audio-monitoring.md) — live audio metering (separate from exposure)
- [`docs/design/specs/2026-06-26-lut-feature-architecture.md`](design/specs/2026-06-26-lut-feature-architecture.md) — RWG/Log3G10→Rec.709 conversion architecture
