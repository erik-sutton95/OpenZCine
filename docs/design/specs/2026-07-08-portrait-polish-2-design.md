# Portrait polish round 2 — design (chain G)

**Date:** 2026-07-08 late · **Branch:** `ui/general-improvements` (base 69fac0b)
**Source:** operator device punch list (5 items, real-ZR session), full autonomous overnight
mandate ("I expect all these points to be fixed").

Landscape stays byte-identical (feed-content drift excluded) — every task A/Bs against the prior
chain-E screenshot baseline.

## G1 — Fill mode: edge-to-edge width (no pillar bars)

The true-9:16 fill frame (d297098) pillarboxes ~10pt per side; the operator rejects the bars.
**Change** (`MonitorPortraitLayout.zones` `.fill` branch): the fill frame returns to FULL
viewport width (`x: 0, width: viewportWidth`), top still at `topBar.maxY`, height =
`min(span, viewportWidth * 16 / 9)` (the 16:9-of-width cap keeps tall viewports sane; on
phones span governs). Content behavior unchanged: aspect-fill center-crop via the over-widened
16:9 content box. Update the doc comment (the frame is "as much of the span as edge-to-edge
width allows", not "true 9:16") and the zone tests (full width; tall-viewport cap kept;
centering assertion dropped).

## G2 — Floating scopes must not be sliced by the feed frame

On device the WAVE panel renders cut mid-panel at the fill frame's edge. G1's full-width frame
removes the pillar-boundary slice; additionally the fill floating-scopes mount drops its
`.clipped()` (MonitorUnified.swift, the `MonitorScopes(.scopesFloating)` mount) — MovablePanel
already clamps panels inside its bounds, so clipping only ever manifests as a sliced panel.
Acceptance: with 2+ scopes in fill on the sim, drag-default positions render complete panels;
no panel is ever visually truncated at a frame edge.

## G3 — View Assist settings tab: single column in portrait

`ViewAssistSettingsRows` (MonitorPanels.swift:3288) is a hand-rolled two-column masonry —
cramped and right-clipped on portrait phones. **Change:** thread the existing `portrait` local
(computed at `OperatorSettingsPanel.body`, MonitorPanels.swift:2719) down through
`settingsContent`/`settingsRows` as a parameter; `ViewAssistSettingsRows` gains
`var portrait: Bool` and renders a SINGLE full-width `VStack(spacing: 8)` in reading order —
False Color, Zebra, Waveform, Parade, Histogram, Peaking, Traffic Lights — when portrait; the
existing two-column masonry stays byte-identical in landscape. Cards keep `compact: true`
(the portrait single column ≈ the landscape column width; density is already right — the
complaint is the two-column cramming, not the card innards).

## G4 — Parade YRGB: white Y lane on the GPU path

`ParadeMode.yrgb` renders 4 lanes on the CPU plot (correct) but the GPU scatter path
(`ZC_GPU_SCOPES=1`, which the operator's device build runs) has a hardcoded 3-pass RGB list —
`ScopeScatterView.Coordinator.passes(for:)`, WaveformMetalView.swift:120-140 — and the mode is
never passed in (dropped at MonitorOverlays.swift:1223-1227). **Change:** thread
`scopes.paradeMode` into `ScopeScatterView` and emit a 4th pass (luma channel — the shader's
`channel==3u` luma dot-product already exists for the waveform pass) drawn FIRST in the Y lane,
with lane slicing = 1/count (quarters in YRGB, thirds in RGB) and the Y lane tinted like the
CPU plot's `ScopePalette.luma`. CPU/GPU lane order and appearance must match (Y, R, G, B).
Header chip already correct. Mode changes must re-render live (the pass list must depend on
the current mode, not init-time state).

## G5 — Resolution/Codec pickers: portrait bottom sheet

`.resolution`/`.codec` are hardcoded `isTopBar == true` (NativeAppRoot.swift:5328) and
`PanelHost` routes them to `topPickerBody`, whose no-anchor fallback pins a card top-left —
wrong in portrait (no top-deck cells exist there). **Change:** route on
`picker.isTopBar && !isPortrait` (MonitorPanels.swift:614) so portrait sends them through
`bottomPickerBody`'s existing portrait bottom-sheet branch — the exact presentation the
view-assist options already use. Landscape drop-down behavior untouched. Acceptance:
portrait resolution picker = full-width bottom sheet (glass, X/tap-outside close), identical
chrome to the assist-options sheet; landscape resolution picker unchanged vs baseline.

## Verification

Per repo recipe (sim UDID 21926DCF-8092-4790-BE19-69F172349192, fresh derivedData + mtime,
uninstall-first, SIMCTL_CHILD_ exports). GPU parade cells need `SIMCTL_CHILD_ZC_GPU_SCOPES=1`
+ `ZC_METAL_FEED=1` (the demo feed only routes through Metal scopes with both — see chain-F
F3 report). `just native-check` per task (env ABI-crash fallback rule applies). Zone changes
carry updated unit tests; golden parity tests adapt by construction.
