# Built-in display LUTs (N-Log→709, Log3G10→709) — design

Branch: `ui/general-improvements` · Approved 2026-07-07

## Goal

Upgrade the two built-in log→Rec.709 monitor looks from bare technical transforms into proper
display looks — contrast and soft highlight rolloff visually comparable to the operator's
reference conversions (RED IPP2 "medium contrast / medium rolloff" and a commercial N-Log
"natural" LUT) — while remaining 100 % clean-room.

## Provenance rules (non-negotiable)

- Inputs are published math only: Nikon "N-Log Specification Document" (curve; N-Gamut ≡ BT.2020),
  RED "REDWideGamutRGB and Log3G10" white paper Rev B (curve + RWG→709 matrix), ITU-R BT.1886
  (display EOTF), and the IPP2 white papers' *published structure* (contrast s-curve + selectable
  highlight rolloff) — structure, never coefficients.
- Tone-map constants are original and eyeball-tuned. **No numeric fitting, sampling, or
  resampling of any vendor .cube data — that would make ours a derivative work.** The two
  reference cubes stay local (gitignored `ref/` or the operator's disk), used only for visual
  side-by-side QA as locally-loaded custom LUTs.
- Bit-exact vendor output is explicitly out of scope; the app's RED LUT download feature remains
  the path to RED's exact IPP2 output.
- The doc comment on the tone map states all of the above in brief.

## Change

All in `Sources/OpenZCineCore/MonitorLUT.swift` (`MonitorLUT.logToRec709` pipeline):

1. **Keep verbatim:** log decode functions (`nLogToLinear`, `log3G10ToLinear`) and the two gamut
   matrices — already correct, published math.
2. **Insert tone map** between the gamut matrix and the encode, applied per channel in
   scene-linear (per-channel application yields the natural highlight desaturation these
   conversions are expected to have):
   - Anchored filmic s-curve: mid grey pinned — scene-linear 0.18 maps to display-linear ≈0.117,
     i.e. an output code value ≈0.41 after the 2.4 encode — with a gentle toe and a soft shoulder.
   - Per-format white point: the shoulder compresses each format's real headroom
     (Log3G10 encodes up to ≈184× mid-grey-relative scene white; N-Log ≈16.4×) into display
     range instead of hard-clipping at 1.0.
   - Named constants (contrast, shoulder start, white point per format), documented as
     eyeball-tuned originals.
3. **Replace the encode:** BT.709 camera OETF → **BT.1886 display encode (pure 2.4 gamma
   inverse)**, matching how display-referred 709 conversions are actually built.
4. **Remove `tealOrange`** — the look is gone from the enum and the picker. Persistence
   migration: a stored selection that decodes to the removed look (raw value "Teal/Orange")
   falls back to the default selection instead of failing decode — implemented wherever
   `LUTSelection`/`MonitorLUT` decoding is centralized, with a test.
5. **Reorder the built-ins** (CaseIterable order drives the picker): `log3G10Rec709` first,
   then `nLogRec709`, then `monochrome`. The two camera-matched conversions lead the list;
   Mono stays last.
6. Untouched: `monochrome`'s look itself, cube generation (33³ default), titles of the
   remaining entries.

## Tests (extend the existing MonitorLUT coverage)

For both formats: mid-grey anchor within tolerance; per-channel monotonicity along the neutral
axis across the full 33³ input range; endpoints (encoded black → ≈0, encoded max → 1.0, no hard
clip below the shoulder); no NaN/inf anywhere in the generated cube; existing tests updated where
they asserted the old OETF output values. Plus: decoding a persisted "Teal/Orange" selection
falls back to the default without throwing; the picker order test reflects Log3G10 → N-Log → Mono.

## Verification

Unit tests green, plus simulator side-by-sides on the demo log feed (`ZC_DEMO_LOG_FEED=1`) and,
where available, real R3D/N-Log footage: our built-in vs the reference cube loaded as a local
custom LUT. Screenshot pairs saved for the record. Tuning iterates on the constants until the
match is visually satisfying on skin tones, mids, and highlight rolloff; residual differences in
extreme saturated highlights are accepted.

## Out of scope

- New menu entries or look variants; LUT engine/UI changes beyond the enum reorder + removal.
- Bit-exact vendor matching; shipping or fitting to any vendor LUT data.
