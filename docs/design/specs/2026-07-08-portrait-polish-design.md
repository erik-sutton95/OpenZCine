# Portrait monitor polish — design

**Date:** 2026-07-08 · **Branch:** `ui/general-improvements` (base ac55d63, unified MonitorShell)
**Source:** operator device-screenshot punch list (10 items), portrait DISP live, fit mode.
**Authority:** user directed full autonomous execution ("fully implement fixes for all these
points"); the one interactive decision taken before they left is recorded in R7/R8.

All work is portrait-only unless stated. Landscape rendering must remain byte-identical —
every task A/Bs landscape screenshots against pre-change references (the chain-D discipline).

## Requirements

### R1 — System buttons: landscape styling parity

Portrait lock / media / settings currently render via `portraitSlotIcon`
(`ios/Runner/MonitorUnified.swift:751`) as 73.6×43.7 liquid-glass pills with bare SF Symbols.
Landscape renders media/settings as circular `AssetCircleButton`s (63.25pt, `Circle()`,
branded `IconMedia`/`IconSettings` assets — `MonitorUnified.swift:652-676`,
`MonitorExperience.swift:950`) and lock as a 40×40 rounded-rect glass button with accent
stroke when locked (`MonitorUnified.swift:626-650`).

**Change:** portrait `portraitBody` (`MonitorUnified.swift:709`) reuses the exact landscape
button views: `AssetCircleButton` for media + settings, the landscape lock button for lock.
DISP (`PortraitDisplayButton`) and record are already landscape-identical — untouched.
Delete `portraitSlotIcon` and the three portrait wrappers it serves once nothing references
them. If 63.25pt circles crowd the row, spacing may adjust; button size/shape may not.

### R2 — Top bar: fully inline

`InfoBarContent` (`MonitorUnified.swift:174-224`) lays timecode + storage inline but the
battery is `BatteryIndicator` — a 3-row VStack (glyph / "100%" / camera glyph,
`MonitorExperience.swift:1039-1066`) scaled 0.7, reused verbatim from the landscape rail.

**Change:** add an inline battery presentation — single HStack row: battery glyph (with
charging state), percent text, camera glyph — vertically centered in the 44pt bar, trailing
edge. Implement as a second presentation of the existing indicator (e.g.
`BatteryIndicator(style: .inline)` or a small sibling view reusing the same symbol/percent/
charging logic — no logic duplication). Landscape rail keeps the VStack presentation
untouched. Bar row: timecode leading, storage line centered, battery trailing — one shared
baseline/center line.

### R3 — Kill the seam between top-bar band and feed

Zone math says the bar overlays the feed's first 44pt (`MonitorPortraitLayout.swift:65,80,119`:
`topBar.y == feed.y == max(0, safeArea.top)`), yet on device the feed starts *below* the bar
with a black gap. Pixel math on the operator screenshot puts the bar at physical
`safeArea.top` but the feed ~59pt lower — a coordinate-space / double-inset mismatch (the
known chromeInsets-vs-real-safe-area bug class; see `MonitorZoneLayout` portrait adapter's
safe-area source vs what `MonitorShell`'s GeometryReader actually hands the offsets).

**Change:** REPRODUCE FIRST on the simulator (ZC_DEMO_AUTOSTART, portrait, fit) and dump the
actual mounted frames before editing. Then unify the coordinate space so bar and feed share
one origin as designed: the bar overlays the feed's top edge, zero gap, in both fit and fill
and all three DISP modes. Acceptance: screenshot shows feed pixels directly under the
translucent bar; no black band between bar bottom and feed top.

### R4 — Bottom band behind the system cluster

No dedicated background exists behind the portrait system row — buttons float on the
full-screen `Color.black` (`MonitorUnified.swift:1143-1144, 709-718`), and on device the
record button reads as poking above whatever band is visible (same suspected coordinate
mismatch as R3 — fix R3 first, re-screenshot, then finish R4).

**Change:** draw an explicit opaque band (same surface color as the top-bar band family)
behind the system cluster, full width, from above the record button's complete circle
(including its stroke) down through the physical bottom edge (home-indicator area). Lock,
DISP, record, media, settings must sit entirely on the band. If the 88pt `systemBarHeight`
(`MonitorPortraitLayout.swift:38`) can't contain the record button + clearance, grow the
band upward visually rather than resizing the button.

### R5 — Lock: landscape styling + read-only tiles

Portrait lock already toggles `interfaceLocked` and locking already *functionally* blocks
taps app-wide (`showPicker`/`showAssist`/etc. early-return, `NativeAppRoot.swift:4784`).
Missing: (a) landscape button styling — covered by R1; (b) any visual read-only affordance —
landscape dims its strip via `.opacity(interfaceLocked ? 0.4 : 1)` (`MonitorUnified.swift:1045`).

**Change:** apply the same 0.4-opacity locked treatment to every portrait interactive
region: capture tiles grid (`CommandPrimaryGrid`), fill-mode capture strip, assist
toolbar/rail, and scope-toggle surfaces. The top bar, feed, DISP, record, media, settings
and the lock button itself stay full-opacity (matches landscape: record/system controls stay
live). Same animation/timing as landscape.

### R6 — Fit mode: horizontal assist toolbar between feed/scopes and tiles

Today portrait uses a floating collapsible vertical rail in both modes
(`MonitorUnified.swift:1245-1266`). New fit-mode layout, top to bottom:

1. top bar (overlaying feed) · 2. feed (16:9) · 3. scopes zone (0–2 stacked scopes, existing)
4. **assist toolbar — the landscape horizontal `MonitorAssistStrip(axis: .horizontal,
collapsible: false)` presentation, full width** · 5. tile grid · 6. system band.

The toolbar sits directly under the scopes zone and moves down/up as scopes are added/
removed ("push it down dynamically" — it's simply the next zone below a variable-height
scopes zone). Zone math: add an `assistToolbar` zone to the fit branch of
`MonitorPortraitLayout` (height = the landscape strip's height), shrink the grid region
accordingly; golden tests updated. Visible in `.live` only (mirrors landscape
`chrome.assistToolbarVisible` gating). **Fill mode keeps the floating vertical rail
unchanged.** The vertical rail disappears from fit mode entirely.

### R7 — 2-scope cap in fit: enforce, gray out, toast

Scope tools = `[.waveform, .parade, .histogram, .trafficLights]` (today duplicated at
`MonitorUnified.swift:875` and `MonitorPortraitModules.swift:17` — consolidate into ONE core
constant, e.g. `MonitorAssistTool.scopeTools`). Today a 3rd scope toggle silently succeeds
in preferences but never renders (`prefix(2)` in canonical order).

**Change (fit mode only):**
- Enforcement moves to the toggle layer: with 2 scopes displayed, activating a 3rd is
  refused (preference unchanged, button does not go active).
- The refused state is visible: scope buttons that cannot activate render grayed
  (~0.35 opacity) while remaining tappable.
- Tapping a grayed scope shows a small self-dissolving toast: glass capsule, single line
  ("2 scopes max in fit view — close one or pinch to fill"), bottom-anchored above the
  assist toolbar, fades in, auto-dissolves after ~2.5s, no buttons, tap-through not
  required. New tiny reusable `MonitorToast` view; one at a time (new message replaces).
- Non-scope assist tools are never grayed or capped.
- Deactivating a scope un-grays the others immediately.

### R8 — Fill mode: unlimited scopes, landscape behavior + the fit↔fill rule

**Change:** in portrait fill, drop the `PortraitScopesStack` overlay and stop suppressing
floating scopes: mount the landscape `FeedAssistOverlayModule` floating `MovablePanel`
scopes (`MonitorOverlays.swift:16-99`) — draggable, resizable, positions persisted, no
count cap, identical to landscape. Panel positions clamp into the portrait feed region.

**Selection/ordering rule (user-approved):** activation is recency-ordered. Preferences gain
an ordered record of scope activation (append on enable, remove on disable; persisted).
- Fill: all active scopes float.
- Fit: the **2 most recently activated** scopes render in the stacked zone; older ones stay
  active-but-hidden ("remembered") and reappear on pinch back to fill. Pinching destroys no
  state.
- Fit-mode gray-out (R7) keys on "2 scopes *displayed*", i.e. active count ≥ 2.
- The R7 toast copy points at the escape hatch ("…or pinch to fill").

### R9 — Fill mode: capture strip fits without scrolling

Cell size is intrinsic (fonts 9/19/20pt, paddings — `MonitorExperience.swift:686-727`;
spacing 8, panel insets 12 — `MonitorUnified.swift:258,260,321`). Portrait fill always
scrolls today (`scroller`, `MonitorUnified.swift:293-342`).

**Change:** scale the portrait-fill strip's cell typography, padding, and spacing by ~0.8
(fonts → ~7/15/16pt) so the full set fits the screen width with no horizontal scrolling on
the target device class. Hook: the existing `fitsWidth: false` branch already uniquely
identifies portrait fill — thread a scale factor there; landscape (`fitsWidth: true`) is
untouched. Keep the ScrollView as overflow insurance; acceptance is no-scroll at 402pt width
(iPhone 17 Pro). Tap targets stay ≥44pt via the existing `minTapTarget` machinery.

### R10 — Fill crop must be dead center

Root cause found: double centering. The oversized 16:9 content gets an explicit centering
`.offset(x: feedContentOffsetX)` (`MonitorUnified.swift:1153`) *and* the outer
`.frame(feed.width)` centers it again — offsets add, so the visible crop lands on the
right edge. Same duplicated bug for the assist overlay at `:1163-1174`.

**Change:** remove the manual horizontal centering offset in both places; keep exactly one
centering mechanism (outer frame default-center + `.clipped()`), offsetting only by
`feed.x/feed.y`. Acceptance: fill-mode crop shows the horizontal middle of the frame
(verify with an asymmetric demo frame), AF box/overlays land on the same features as in
fit mode.

## Cross-cutting

- **Order:** R3 before R4 (shared coordinate-space suspicion). R7/R8 share the scope-order
  plumbing (one task). R1+R5 share the cluster (one task).
- **Landscape inertness:** every task screenshots landscape live+clean before/after; pixel
  parity required (clock/telemetry drift excluded).
- **Core changes** (`MonitorPortraitLayout` assistToolbar zone, scope-tool constant,
  activation-order preference) get unit tests; golden zone tests updated deliberately, not
  regenerated blindly.
- **Verification recipe:** iPhone 17 Pro sim UDID 21926DCF-8092-4790-BE19-69F172349192,
  fresh derivedData + binary-mtime check, `simctl uninstall` first (portraitFeedAspect
  persists), `ZC_DEMO_AUTOSTART=1`, `ZC_DEMO_DISP` takes `live|clean|command` strings,
  `ZC_DEMO_FEED_ASPECT=fill` for fill cells, `ZC_DEMO_LOCK=1` for R5 cells.
- **Gate:** `just native-check` per task (known-good fallback if the env ABI crash recurs:
  `just ios-build` + `swift-format lint --strict --recursive`).

## Alternatives rejected

- R7 "replace oldest scope on 3rd toggle": implicit destruction, worse than an explicit
  refusal + toast.
- R8 "drop extra scopes on pinch to fit": destroys state the user built in fill.
- R8 "block pinch while >2 scopes": punishes the primary gesture.
- R9 auto-shrink-to-measure (GeometryReader fitting): more machinery than a fixed 0.8 step;
  revisit only if 0.8 doesn't fit the smallest supported width.

## Deviations

Honest record of where implementation departed from this spec's brief. None were regressions —
each is noted in its task report and re-verified in the E8 chain sweep.

- **E1:** added a no-arg `OperatorPreferences.init()` convenience initializer (forwards to
  `.defaults`), not listed in the brief's interfaces. Required because the brief's own
  `ScopeActivationOrderTests.swift` snippet calls `OperatorPreferences()` with zero arguments,
  which doesn't compile against the existing 13-parameter memberwise initializer.
- **E4 — root cause differed from the spec's hypothesis:** R3 guessed a coordinate-space /
  double-inset mismatch between the zone math's safe-area source and what `MonitorShell`'s
  `GeometryReader` actually handed the offsets. Instrumentation (colored-border overlay, stripped
  before commit) proved the zone frames were already correct — the actual bug was a **doubled
  `feed.y`** applied both on the feed content's inner `.offset` (meant only for fill's horizontal
  re-centering) and again on the outer `.offset(x: feed.x, y: feed.y)` that places the clip box.
  The stray inner `y` slid the image down inside its own clip box, blanking the vacated top strip
  to black — the seam. Fixed by zeroing the inner offset's `y` component; no core/zone-math change
  was needed. (The *horizontal* half of the same double-offset pattern is R10, fixed separately by
  E7.)
- **E5:** reused the existing `ZC_DEMO_ASSIST_ON` hook to seed scopes for the cap/toast
  screenshots rather than adding a new `ZC_DEMO_SCOPES` hook (the brief allowed either). Added
  `ZC_DEMO_SCOPE_TOAST=1` (not in the brief's interface list) as a testing affordance to fire the
  toast headlessly, since the toast is otherwise only reachable via a live tap gesture.
- **E6:** fixed a demo-hook ordering bug found while building the fit↔fill persistence proof —
  `ZC_DEMO_FEED_ASPECT` now applies *before* `ZC_DEMO_ASSIST_ON` inside the `AUTOSTART` task, so
  seeding 3+ scopes under `fill` isn't refused by the fit-only 2-scope cap (which previously saw
  the still-default `.fit16x9` aspect during seeding). Demo/screenshot-only change, no production
  behavior affected.
- **E7:** none beyond the pre-flagged state change from E4 (E4 had already zeroed the inner
  offset's `y` component before E7 landed, so E7 located and removed the remaining `x` component —
  the R10 double-centering fix — by symbol rather than the plan's stale line numbers).
- **E2, E3:** no deviations from the brief.
