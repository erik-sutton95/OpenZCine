# Portrait monitor v2 (DISP 1) + rotation morph — design

Branch: `ui/general-improvements` · From the operator's mockup + points, 2026-07-07

Redesign of the portrait monitor's **live** mode. Clean and command modes keep their current
structure. Landscape stays untouched except where rung-2 rotation morphing tags shared elements.

## 1. Top bar — overlays the feed

The feed rises to the top of the safe area; the info bar renders ON the feed (glass/scrim like
the landscape top deck), freeing its previous 44pt for content below.

- **Left:** timecode, with the frames field in the accent color exactly like the landscape
  timecode (`HH:MM:SS` ink + `:FF` accent).
- **Center (absolutely centered on the screen):** storage + remaining minutes ("521 GB · 47 min").
- **Right:** camera battery — icon + percent (reuse the landscape battery presentation).

## 2. Feed aspect — pinch between 16:9 and 9:16

- Pinch on the feed snaps between exactly two states (animated):
  - **16:9 fit** — full-width strip, the whole image visible (today's behavior).
  - **9:16 fill** — the feed fills the whole area from the safe-area top (the top bar overlays
    it) down to the bottom system bar; the 16:9 image **center-crop zooms** to fill (sides
    cropped), like the Camera app. At iPhone proportions this region is ≈9:16.
- The chosen aspect persists in `OperatorPreferences` (`portraitFeedAspect`).
- Pinch-in → 16:9, pinch-out → 9:16; the gesture is a toggle with a scale threshold, not
  continuous zoom.

## 3. Controls morph with the aspect

**16:9 (strip) mode — tiles:**
- Quick-control tiles (3-column `CommandPrimaryGrid`, as today) below the feed/scopes.
- **Dynamic scopes region** between feed and tiles: present ONLY when at least one scope-type
  assist tool (waveform / parade / histogram / traffic lights) is enabled. Up to **2 scopes,
  vertically stacked**; the tile grid reflows to the remaining height. No enabled scope tools →
  no region, tiles get the space.
- The swipeable Control/Grid/Assist TabView pages are **removed** — superseded by the tiles +
  the assist rail (below). No page dots.

**9:16 (tall) mode — bars:**
- Quick controls become the **horizontal scrolling capture bar** (same component family as the
  landscape capture-settings bar: ISO · SHUTTER · IRIS · WB · …, chevron affordance), overlaid
  near the feed's bottom edge — the mockup's "Camera Settings control ›".
- Enabled scopes (≤2, stacked) **overlay the feed** as fixed anchored panels (top-left region),
  since the bottom is owned by the capture bar.

**Both modes:**
- **View-assist rail:** a collapsed "assist tools" button at the bottom-left of the feed expands
  into a **full-height, vertically scrolling tool rail overlaying the feed's left edge** (the
  mockup's green rail) with the same tool buttons/behaviors as the landscape assist bar (tap
  toggles, long-press opens options). Tap the collapsed button or outside the rail to collapse.
- **REC options button** top-right over the feed: opens the recording-format quick access
  (resolution/framerate + codec pickers — the landscape top-deck equivalents). ⚠ operator to
  confirm intent at review.
- **Bottom system bar** (replaces the current record row): lock · DISP · **record (center,
  large)** · Media · Settings, in a persistent band below the feed area, above the home
  indicator. Present in both aspects and all DISP modes (command keeps it, matching today's
  record row role).

## 4. Popups — bottom-anchored everywhere

All pickers and assist-option popups opened from portrait (tiles, capture bar, rail long-press)
present as a **bottom sheet anchored to the very bottom of the screen**, full width, overlapping
the bottom system bar and controls. Dismiss via tap-outside or the panel's X — same affordances
as landscape. (PanelHost's portrait arm becomes bottom-anchored instead of floating.)

## 5. Rotation — rung 2 now, rung 3 planned

- **Now (rung 2):** `matchedGeometryEffect` heroes across the portrait/landscape branch swap so
  rotation reads as a morph inside the system rotation animation: the **feed surface**, the
  **record button**, and the **DISP button** (one shared namespace on the monitor shell; the
  rest crossfades via a designed transition).
- **Later (rung 3):** unify the two shells into one zone-driven tree — a separate spec + plan
  after portrait polish settles. Out of scope here; tracked as follow-up.

## 6. Verification

- Every layout state screenshot-verified on the sim via the existing hooks plus new ones as
  needed (`ZC_DEMO_ORIENTATION`, `ZC_DEMO_SCOPE_SAMPLES`, a new `ZC_DEMO_FEED_ASPECT`), all four
  edges, both aspects × {no scopes, 1 scope, 2 scopes} × assist rail open/closed, popup anchoring
  from tiles and bar.
- Zone arithmetic in core (`MonitorPortraitLayout` v2) with updated unit tests.
- Rotation morphing verified with `ZC_DEMO_ORIENTATION` relaunches for end states; the live
  animation itself eyeballed on device by the operator.
- Landscape regression: byte-identical except the shared-element tags; re-run the landscape
  sweep surfaces touched.

## Out of scope

- Clean/command mode redesigns (they keep today's structure with the new bottom system bar).
- Rung-3 shell unification (follow-up spec).
- Camera-side vertical shooting.
