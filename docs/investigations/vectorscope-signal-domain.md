# Vectorscope signal domain

Status: resolved in the native iOS and Android implementations.

## Symptom

The vectorscope trace stayed close to neutral even at 4x trace gain, while the monitored image
contained clearly distinguishable colours.

## Finding

The scope sampler receives the clean camera JPEG before any operator LUT or view assist. Its RGB
bytes are not scene-linear "pre-log" data: they are wide-gamut, log-encoded camera values
(REDWideGamutRGB/Log3G10 for R3D NE or N-Gamut/N-Log for N-Log recording). The old vectorscope
incorrectly applied a Rec.709 RGB-to-CbCr matrix directly to those values. That compressed the
trace and made its positions colorimetrically misleading.

## Resolved pipeline

The vectorscope plots one fixed conversion of the camera signal:

camera log decode -> source gamut to Rec.709 -> display tone map -> BT.1886 display code ->
Rec.709 CbCr.

The conversion is the same camera-matched transform that generates OpenZCine's built-in
Log3G10-to-709 and N-Log-to-709 looks, chosen by the camera curve alone (the shared
`MonitorAssistConfiguration.defaultScopeLook` on iOS, `ScopeVectorLutRequest(curveOrdinal)` on
Android). It is independent of the operator's LUT toggle and selected creative/custom LUT, and
false colour, zebra, and focus peaking cannot contaminate the measurement. Waveform, RGB parade,
histogram, and Traffic Lights use the untouched camera samples. Scopes measure the camera signal,
not the LUT-applied picture: a regression in which VECTOR followed the armed monitoring LUT was
fixed in OpenCine #314 and its OpenZCine follow-up.

The log transform is applied only when the signal label positively identifies R3D/Log3G10 or
N-Log. Containers that can carry several tone modes (N-RAW, ProRes, H.265, and H.264) fall back to
decoded display RGB rather than being incorrectly assumed to be N-Log. Wiring the body-reported
tone-mode property will let those ambiguous containers select the log transform automatically.

Playback clips do not yet persist trustworthy per-clip transfer/gamut metadata. Playback scopes
therefore take the playback mapping's curve: the connected camera's recording curve, or Log3G10
with no camera connected. Once clip metadata carries a verified curve, playback should use it
instead.

Each density bin also accumulates its sampled RGB colour. Rendering normalizes that average into a
readable hue while logarithmic bin density controls opacity; neutral samples remain white.

## Validation

- Independent 75% colour-bar Cb/Cr constants and 128-bin coordinates verify the Rec.709 matrix,
  orientation, and scale against SMPTE RP 219-style bars.
- Encoded Log3G10 and N-Log fixtures land at the same 75% targets in Monitor mode at 1x gain.
- Neutral ramps remain on the centre axis through both monitor transforms.
- Simulator A/B captures use the same log still and panel position for Monitor 1x and Source/Log
  1x, confirming that the corrected display transform expands the readable trace without gain.

The normative references are [ITU-R BT.709](https://www.itu.int/rec/R-REC-BT.709-6-201506-I/en)
and [SMPTE RP 219-1](https://pub.smpte.org/latest/rp219-1/rp0219-1-2014.pdf).
