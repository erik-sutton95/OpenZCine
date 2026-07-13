# Monitor shell unification (rung 3) — design

Branch: `ui/general-improvements` · Authored autonomously 2026-07-07 (user directive: full
plan + implementation while away). Supersedes the rung-3 stub planned in portrait-v2 Task 9.

## Goal

One monitor view tree for both orientations. Rotation stops being a branch swap (two trees,
`matchedGeometryEffect` band-aids on three heroes) and becomes a geometry change under stable
view identity — every module glides to its new frame inside the system rotation animation,
which is the full native morph rung 2 approximated.

## Why now / evidence

The duplication census (chrome inventory, 2026-07-07) shows the two shells already share
almost all leaf logic — `RecordButton`+alert, DISP button, `CaptureSettingButton`,
`AssistToolButtonRow`, `BatteryIndicator`, scope minis are verbatim twins — and diverge only
in containers (axis, scroll direction, pill vs bar) and in two geometry systems
(`MonitorLiveViewModuleLayout` frames vs `MonitorPortraitLayout` zones). Unifying is mostly
container work, not logic work.

## Architecture

### 1. Core: `MonitorZoneMap` — an ADAPTER, not a re-derivation

A single core entry point:

```swift
public struct MonitorZoneMap: Equatable, Sendable { /* named module frames + style hints */ }
public enum MonitorZoneLayout {
    public static func map(
        viewportWidth: Double, viewportHeight: Double,
        safeArea: MonitorEdgeInsets, mode: DispMode,
        isPortrait: Bool, aspect: PortraitFeedAspect, scopeCount: Int,
        horizontalDirection: MonitorHorizontalLayoutDirection,
        bottomBarHeight: Double
    ) -> MonitorZoneMap
}
```

Internally it DELEGATES to the two existing, tested policies —
`MonitorLiveViewModuleLayout.fit(...)` when landscape, `MonitorPortraitLayout.zones(...)` when
portrait — and normalizes their outputs into one vocabulary. Zero new geometry is invented;
the 530-test suite keeps protecting the real math. The map adds per-zone **style hints** the
shell needs to mount one component both ways:

| Zone | Frame source (landscape / portrait) | Hints |
| --- | --- | --- |
| `feed` | feed frame / zones.feed | `crop: fit\|fill` (portrait aspect) |
| `infoBar` | topInfoDeck / zones.topBar | `style: pill\|bar`, `compact` |
| `captureStrip` | bottomCaptureSettings / zones.controls (fill) or nil (fit: tiles own it) | `axis: horizontal` both |
| `assistStrip` | bottomAssistTools / feed-left rail region | `axis: horizontal\|vertical`, `collapsible: Bool` |
| `systemCluster` | lockButton+rightRailControls / zones.systemBar | `axis: vertical\|horizontal` (incl. lock, record, DISP, media, settings slot frames) |
| `batteryCluster` | batteryRail / infoBar trailing slot | `style: rail\|inline` |
| `scopes` | nil (floating) / zones.scopes or fill overlay region | `style: floating\|stacked` |
| `controlsGrid` | CommandMonitor region / zones.controls | command + portrait-fit tiles |
| `recOptions` | nil / top-right over feed | portrait-only zone (nil in landscape) |

**Golden parity tests**: for fixture viewports (landscape 874×402 standard+mirrored, portrait
390×844 fit/fill × scopeCount 0-2, all three DISP modes), the map's frames must equal the
legacy policies' outputs exactly. This is the contract that makes the shell swap safe.

### 2. Container unification — one component per twin pair

Before the shell swap, each divergent twin pair merges into one axis/style-parameterized
component (screenshot parity gates in BOTH orientations per merge):

- `MonitorInfoBar(style: pill|bar)` ← TopInfoDeckModule + PortraitTopBar. The pill keeps its
  readout cells (resolution/codec/media + picker-frame publishing); the bar style renders the
  portrait arrangement. One component, one set of anchor registrations.
- `MonitorCaptureStrip` ← BottomCaptureSettingsModule + PortraitCaptureBar (both are
  `CaptureSettingButton` rows; unify the container: content-hugging in wide zones, scrolling
  when the zone is narrower than content — which subsumes both today's behaviors).
- `MonitorAssistStrip(axis:, collapsible:)` ← BottomAssistToolsModule + PortraitAssistRail
  (both are `AssistToolButtonRow` sequences; axis + optional collapse pill).
- `MonitorSystemCluster(axis:)` ← LockButtonModule + RightRailControlsModule +
  PortraitSystemBar (same five controls; the cluster takes per-slot frames from the zone map
  in landscape and equal-width flow in portrait).
- Battery: `BatteryIndicator` is already one component — the cluster hint decides rail vs
  inline placement.
- Scopes: one `MonitorScopes(style: floating|stacked)` host — floating mounts the existing
  `MovablePanel` set, stacked mounts the `PortraitScopesStack` arrangement, same plot views
  underneath.

### 3. The unified shell

`MonitorShell(context:)` replaces BOTH branches of `LiveViewShell`: it computes the
`MonitorZoneMap` once per layout pass and mounts each module exactly once at its zone frame
(nil zone → unmounted). Per-DISP-mode visibility comes from the map (zones go nil/zero the
same way the legacy branches gated views). PanelHost keeps its orientation-specific anchoring
(bottom sheets in portrait, bar-anchored in landscape) — that behavior is already gated and
correct.

- **Transition flag**: a short-lived `ZC_UNIFIED_SHELL` env/debug toggle mounts the new shell
  side-by-side with the legacy branches during implementation, so every state can be
  screenshot-diffed old-vs-new. The flag and BOTH legacy shells (`LiveViewChromeLayer`
  branch structure as mounted from LiveViewShell, `PortraitMonitorShell`) are DELETED in the
  final cleanup task once parity is proven.
- **Rotation**: with stable identity, `.animation(.easeInOut(duration:0.3), value: isPortrait)`
  on the shell animates every module's frame through rotation. The three
  `matchedGeometryEffect` hero tags and their namespace plumbing become redundant and are
  removed in cleanup.

### 4. Explicitly unchanged

Pickers' internals, scope plots/samplers, record confirmation flow, demo hooks, DISP cycling
semantics, clean/command mode meanings, the anchor-frame registration/reset discipline
(registrations move INTO the unified components but keep identical semantics), landscape
pixel output (parity-gated), portrait v2 pixel output (parity-gated).

## Verification

- Golden parity unit tests (core) — map vs legacy policies, exhaustive fixture matrix.
- Screenshot A/B: legacy vs unified shell for the full state matrix (2 orientations ×
  {live fit 0/1/2 scopes, live fill 0/2, clean, command} × pickers open) — pixel-compare the
  pairs (allow only timecode/FPS text differences).
- Rotation morph: end states headless; live animation is an operator checklist item.
- `just native-check` per task; final whole-branch review before merge.

## Out of scope

- Any visual redesign (this is a structural refactor with pixel parity as the acceptance).
- iPad layouts, vertical shooting.
- Removing the two legacy CORE policies (`MonitorLiveViewModuleLayout`,
  `MonitorPortraitLayout`) — they remain as the map's delegates; only the duplicated SHELL
  trees die.

## Deviations (actuals, recorded at close of the D1–D7 chain)

The plan above was followed structurally; these are the points where implementation diverged from
the letter of the plan, gathered during the per-task reviews.
None weakened parity — each is either a smaller-than-planned surface (no legacy behavior existed to
carry over) or a fix applied after the A/B matrix caught a real regression.

- **`recOptions` zone is always `nil`, in both orientations** (D1). The plan implied a
  portrait-only region; no legacy policy produced this geometry, so the adapter doesn't invent it.
  The shell places the portrait rec-options button itself, un-mapped.
- **`MonitorSystemSlotFrames` had a temporary duplication window (D4→D6).** D4 needed per-slot
  system-bar frames before the shell was wired to the real zone map, so it copied D1's slot math
  into two `fileprivate static systemSlots(...)` helpers (one per legacy shell file) as a
  documented, flagged-for-deletion stopgap. D6 deleted both helpers once `MonitorShell` was
  wired to `MonitorZoneLayout.map(...)` directly — `MonitorSystemCluster` now only ever reads
  `map.systemSlots`, one source of truth.
- **`MonitorAssistStrip` is axis-driven, not `collapsible`-driven** (D3, reaffirmed D5). The
  component's stored `collapsible` parameter documents call-site intent but the body branches on
  `axis` alone, because in both shells `collapsible` always co-varies with `axis` (horizontal ⇒
  false, vertical ⇒ true) — there's no case where they diverge. See the `zone.collapsible`
  paragraph below for the same question one layer down, in the core zone map.
- **Clean-mode unmount-vs-offset for bottom bars and the focus-recenter button** (D5). Legacy
  slid these off-screen with `.opacity`/`.transition` while keeping them mounted; the unified
  shell unmounts them outright in clean mode (`if !isClean { ... }`). Static end states are
  pixel-equivalent (both hidden), verified in the A/B matrix; only the in-flight transition curve
  differs, which is outside the pixel-parity acceptance criterion.
- **`ChromeEntry` cold-launch stagger not reproduced** (D4, accepted through D5/D6). Legacy
  independently staggered the lock button and the DISP/record/media/settings group by ~70ms
  (`ChromeEntry(delay: 0.15)` vs `0.22)`) on first launch. `MonitorSystemCluster` mounts as one
  view with a single `ChromeEntry(delay: 0.15)` (the earlier of the two), so the group loses that
  stagger. End-state geometry is unaffected; this is a cold-launch cosmetic only, not restored
  (YAGNI — no seam was added for it).
- **Full-screen-panel and recording-tally mount-level bug, found and fixed twice.** D6fix found
  the recording tally (`RecordingBorderModule`) mounted one call-frame too early — inside
  `MonitorShell`'s own `GeometryReader`, which is still safe-area-inset, instead of past
  `LiveViewShell`'s `.ignoresSafeArea(.container, edges: .all)` — so it stopped at the safe-area
  frame instead of reaching the bezel. D7's full sweep found the **same class of bug** still
  present for the full-screen panel overlay (Operator Setup / Media / Tool Library): it was still
  a `MonitorShell` computed property, mounted at the same wrong (safe-area-inset) level D6fix had
  already moved the tally away from. D7 extracted it to a standalone `MonitorFullScreenPanelOverlay`
  view (`ios/Runner/MonitorUnified.swift`) constructed directly in `LiveViewShell.body`, past
  `.ignoresSafeArea` — the fix also surfaced that reading a view's `@Environment`-backed content off
  an already-constructed sibling instance (`shell.someComputedView`) does not pick up
  `.environment(...)` applied afterward; the content must be a real `View` type SwiftUI constructs
  in place. Screenshot-verified: the panel now reaches the right bezel in landscape (previously a
  visible ~150pt black gap band short of the edge).
- **`controlsGrid` zero-height guard lives in the shell, not the core map** (D5). The adapter
  emits a non-`nil` `controlsGrid` for every fit-aspect pass, including portrait clean mode where
  the underlying region collapses to zero height — matching what the legacy policy returns.
  `MonitorShell` guards `grid.frame.height > 0` before mounting `CommandPrimaryGrid`, mirroring the
  legacy shell's own `zones.controls.height > 0` check, rather than teaching the core adapter to
  suppress zero-height zones (would be new behavior, not a passthrough).
- **`MonitorZone.collapsible` is unconsumed by any shell** (flagged D5, decided D7). No shell code
  reads it — `MonitorAssistStrip` branches on `axis` (see above), and the only real collapse-pill
  behavior (the portrait vertical rail) isn't a mapped zone at all; the shell places it directly.
  Kept as documented-dead metadata rather than dropped: it's exercised by the golden parity tests
  as part of the map's real output contract (the landscape assist zone genuinely is
  `collapsible: true` at the legacy-policy level, a true fact about that zone, just not one any
  shell currently needs), and dropping the field would touch every `MonitorZone` construction site
  in `MonitorZoneLayout.swift` plus every parity-test assertion for no behavioral gain. A doc
  comment on `MonitorZone.collapsible` now states this explicitly.
