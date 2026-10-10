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

CineStop measures the incoming scene signal before the creative display LUT. Nikon's source
adapter decodes each channel and forms scene-linear luminance using RED's published RWG→XYZ Y row
(`[0.286694, 0.842979, −0.129673]`). Encoded RGB weighted directly is a different measurement from
this scene-linear source-gamut luminance. Video, IRE and Limits use the shared monitor-signal
reading instead; their optional 709 reading uses the built-in monitor look, independently of the
selected creative LUT.

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
5. **False-colour monitor reading**: OpenCineMedia owns the CineStop, Video, IRE and Limits
   categories. CineStop reads scene stops; the other scales classify the shared monitor-signal
   reading in LOG or, when an official look exists, 709. There is no separate forced 42-IRE
   middle-grey transform for these categories.

| Anchor | RED Log3G10 spec | OpenZCine (`ExposureToneCurve.redLog3G10`) | Notes |
| --- | --- | --- | --- |
| 18% mid grey | Encoded **`1/3`** (linear `0.18`) | Signal IRE **≈33.3** (native **≈85**); raw-scope IRE **≈39.4** at ISO 800; CineStop **0 stops** | Raw-scope placement follows available headroom; Video/IRE readings depend on LOG/709 |
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

### CineStop source adapter

`ExposureScale.signalNative(zStop:curve:)` encodes `0.18 × 2^stop` through the selected published
curve. `FalseColorMap` performs the inverse per pixel: decode RGB, form source-gamut luminance, then
calculate `log2(Y / 0.18)`. Z-stop **0** therefore means 18% grey for both Log3G10 and N-Log rather
than an app-defined IRE threshold.

### False-colour bands

All four choices use OpenCineMedia's canonical bands and feathering through the Nikon source
adapter (`FalseColorMap`); they share the monitor menu and defaults with Pocket and Insta:

- **CineStop:** complete exposure zones around 18% grey: −2, −1, 0, +1 and +2 stops, with flat
  shadow/highlight grey, crush and a camera-calibrated clip shelf. This replaces the sparse
  one-third-stop ZC Stops ramp and its luminance-detail blend. The saved `Stops` key still selects
  CineStop. Native ordinals remain CineStop 0, IRE 1 and Limits 2; Video is appended as 3.
- **Video:** the nine canonical monitor-signal categories. The published Video Mode ranges remain:

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

- **IRE:** six canonical zones: BDL, NBDL, 18%MG, MG+1, 80%WC and 95%WC. This is distinct from
  Video's nine categories; unpainted gaps are monochrome monitor-signal values.
- **Limits:** four extreme warnings at 0–4, 5–9, 94–98 and 99–100. Unpainted pixels preserve the
  normal underlying image and selected creative look. This is not labelled RED Exposure Mode.

LOG reads the source signal. 709 reads the built-in Rec.709 monitor look when the source has one;
this choice does not select or depend on the creative LUT. Without an official look (currently
sRGB/HLG), the reading remains on the source and the reference retains its actual transfer label.
CineStop keeps scene exposure in both choices; 709 changes its clipping reference. The compact key
uses the common labels and proportional signal bands or the calibrated scene-stop ruler.

Nikon's CineStop adapter retains per-channel source decoding and source-gamut luminance. Pocket's
encoded-luma path is a different source measurement; common options and palettes do not promise
identical RGB classification between them. The existing Nikon HLG diffuse-white rounding and
camera clip assumptions also remain explicit calibration limits. Video, IRE and Limits use the
shared signal lattice; canonical Media owns categorical colours, gaps and smooth transitions.

There is no persisted manual signal override. R3D NE is unambiguously Log3G10. Nikon documents that
N-RAW and ProRes RAW can instead use SDR, however, and the current PTP snapshot does not yet expose a
decoded tone-mode property. Consequently the non-R3D log-monitoring path is valid only while the
camera is actually set to N-Log; wiring the body-enumerated tone property is a required protocol
follow-up before claiming automatic SDR/N-Log discrimination.

RED's documented Video Mode runs on the processed monitor/video path. The shared monitor adapts
its published categories to the selected LOG/709 reading and source calibration; this is not a
claim of bit-exact RED camera output.

The iOS renderer supplies camera JPEG components to Core Image as unmanaged code data, preventing
the framework's normal sRGB-to-linear input conversion from moving thresholds. All four scales use
cached 64³ cubes; Limits uses paint and weight cubes over the normal image. Live rendering uses the
live-source mapping, while video playback uses the playback mapping and its reference calibration.

Mirror options select horizontal and vertical axes independently (horizontal selected by default,
vertical off), applied only when the tool is visible. Both axes transform presentation and inverse
focus mapping, leaving raw scopes and recordings unmirrored. Waveform/parade brightness uses the
common gain: 100% is unity and 200% doubles it. This replaces Nikon's quarter-strength gain; equal
settings do not establish equal physical trace density across native backends.

## Code cross-references

| Module | Path | Role |
| --- | --- | --- |
| Log curve math, ISO warning tables, normalized mapping, Z-stops | [`Sources/OpenZCineCore/ExposureScale.swift`](../Sources/OpenZCineCore/ExposureScale.swift) | `ExposureToneCurve`, `R3DNEHighlightWarning`, `ExposureSignalMapping` |
| Source display tone map | [`Sources/OpenZCineCore/MonitorDisplayToneMap.swift`](../Sources/OpenZCineCore/MonitorDisplayToneMap.swift) | Source-derived display fallback, separate from canonical false-colour categories |
| False-colour source adapter and cubes | [`Sources/OpenZCineCore/FalseColor.swift`](../Sources/OpenZCineCore/FalseColor.swift) | Source-linear CineStop adapter; canonical `OpenCineMedia.LiveColorScience` bands and `MonitorFalseColorLattice` |
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
