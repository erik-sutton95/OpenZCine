# Portrait Monitor v2 Implementation Plan

**Goal:** Rebuild the portrait monitor's live mode to the operator's mockup — overlaid top bar, pinch-snap 16:9/9:16 feed, aspect-driven control morphing, dynamic stacked scopes, assist rail, bottom system bar, bottom-anchored popups — plus rung-2 rotation morphing.

**Architecture:** Zone geometry stays in core (`MonitorPortraitLayout` v2 gains aspect + scope-count inputs, unit-tested). The shell (`MonitorPortrait.swift`) mounts modules into zones and owns the pinch/rail/popup interactions. Landscape components are reused where the spec says "like landscape" (capture bar family, battery, timecode styling); landscape behavior changes ONLY by the rung-2 shared-element tags.

**Tech Stack:** Swift 6, SwiftUI (`@Observable`, `matchedGeometryEffect`), Swift Testing.

## Global Constraints

- Spec: `docs/design/specs/2026-07-07-portrait-monitor-v2-design.md` — binding for zone semantics, morph rules, and copy.
- Branch: `ui/general-improvements`, work in a worktree per chain; never commit to main.
- Verify: `just native-check` per task (KNOWN QUIRK: if the local test runner ABI-crashes before any test runs, fall back to `just ios-build` + `just check` and note it; core-test tasks then run `just test` in a throwaway worktree).
- Screenshot verification is MANDATORY per UI task, headless: portrait via plain launch, landscape via `SIMCTL_CHILD_ZC_DEMO_ORIENTATION=landscape` (+ `sips -r 270` to read). Demo feed: `ZC_DEMO_AUTOSTART=1`, scope traces: `ZC_DEMO_SCOPE_SAMPLES=1`. Fresh dedicated `-derivedDataPath` per build + binary-mtime check (stale-binary trap). All four edges, every state.
- Landscape must remain pixel-identical except the rung-2 `matchedGeometryEffect`/transition tags (Task 8) — every other task's landscape diff must be provably inert (default params, portrait-gated call sites, `git diff -w` where re-indenting).
- Clean/command DISP modes keep today's structure; they gain the bottom system bar in place of the old record row (spec §3).
- New files must be registered in `ios/Runner.xcodeproj/project.pbxproj` (4 locations, pattern-match an existing entry; SPM test files exempt). New files in this plan: `ios/Runner/MonitorPortraitModules.swift` (Task 3).
- No force-unwraps without `// SAFETY:`; modern SwiftUI only; match neighboring style.

---

### Task 1: Core — `MonitorPortraitLayout` v2 zones (TDD)

**Files:**
- Modify: `Sources/OpenZCineCore/MonitorPortraitLayout.swift`
- Modify: `Sources/OpenZCineCore/OperatorPreferences.swift` (persisted aspect)
- Test: `Tests/OpenZCineCoreTests/MonitorPortraitLayoutTests.swift`, `Tests/OpenZCineCoreTests/OperatorPreferencesTests.swift`

**Interfaces:**
- Produces (consumed verbatim by Tasks 3–7):

```swift
/// Which aspect the portrait feed renders at (operator pinch, persisted).
public enum PortraitFeedAspect: String, Codable, Equatable, Sendable {
    case fit16x9   // full-width strip, whole image visible
    case fill      // fills topBar→systemBar, center-crop zoom
}

public struct MonitorPortraitZones: Equatable, Sendable {
    public let topBar: MonitorLayoutRegion    // overlays the feed's top edge
    public let feed: MonitorFeedFrame
    public let scopes: MonitorLayoutRegion    // 16:9 mode only; height 0 when scopeCount == 0
    public let controls: MonitorLayoutRegion  // tiles (fit) or capture-bar strip (fill, overlays feed bottom)
    public let systemBar: MonitorLayoutRegion // lock/DISP/record/media/settings band
}

public enum MonitorPortraitLayout {
    public static let topBarHeight = 44.0
    public static let systemBarHeight = 88.0
    public static let scopeUnitHeight = 96.0      // one stacked scope's height
    public static let captureBarHeight = 64.0     // fill-mode controls strip
    public static func zones(
        viewportWidth: Double, viewportHeight: Double,
        safeArea: MonitorEdgeInsets, mode: DispMode,
        aspect: PortraitFeedAspect, scopeCount: Int
    ) -> MonitorPortraitZones
}
```

- Semantics: `topBar` sits at `safeArea.top`, width = viewport. `systemBar` pinned above
  `safeArea.bottom` (same pin rule as v1's record row — never breaches it, degenerate viewports
  overlap the feed instead). **fit16x9:** feed at y = safeArea.top (top bar overlays it), height
  = width·9/16; `scopes` below the feed with height `min(scopeCount, 2) * scopeUnitHeight` (0 →
  zero-height); `controls` = remaining space between scopes and systemBar (the tile area).
  **fill:** feed spans safeArea.top → systemBar top; `scopes` is zero-height (fill-mode scopes
  overlay the feed — shell's job); `controls` = a `captureBarHeight` strip overlaying the feed's
  bottom (controls.maxY == feed maxY). **.clean:** scopes and controls zero-height in both
  aspects. **.command:** feed ignored by callers; `controls` spans topBar→systemBar (the grid).
- `OperatorPreferences` gains `public var portraitFeedAspect: PortraitFeedAspect = .fit16x9`,
  persisted like sibling fields (find the Codable container + defaults pattern in the file and
  follow it exactly; decode-missing → default).

- [ ] **Step 1: Write the failing tests** (replace the v1 zone tests — v1's `record`/`pages`/`infoBar` fields are renamed/removed; migrate the safe-area-pin regression test):

```swift
@Test func fitAspectStacksTopBarFeedScopesControlsSystemBar() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 1)
    #expect(z.topBar.y == 59 && z.topBar.height == 44)
    #expect(z.feed.y == 59)  // top bar OVERLAYS the feed
    #expect(abs(z.feed.height - 390 * 9 / 16) < 0.5)
    #expect(z.scopes.y >= z.feed.y + z.feed.height)
    #expect(z.scopes.height == 96)
    #expect(z.controls.y >= z.scopes.maxY)
    #expect(z.systemBar.maxY <= 844 - 34)
    #expect(z.controls.maxY <= z.systemBar.y)
}

@Test func fitAspectWithoutScopesGivesControlsTheSpace() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let with = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 2)
    let without = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 0)
    #expect(without.scopes.height == 0)
    #expect(with.scopes.height == 192)
    #expect(without.controls.height - with.controls.height == 192)
}

@Test func scopeCountClampsToTwo() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 5)
    #expect(z.scopes.height == 192)
}

@Test func fillAspectFeedSpansToSystemBarWithCaptureStripInside() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live,
        aspect: .fill, scopeCount: 1)
    #expect(z.feed.y == 59)
    #expect(abs((z.feed.y + z.feed.height) - z.systemBar.y) < 0.5)
    #expect(z.scopes.height == 0)  // fill-mode scopes overlay the feed (shell concern)
    #expect(z.controls.height == 64)
    #expect(abs(z.controls.maxY - (z.feed.y + z.feed.height)) < 0.5)
}

@Test func cleanCollapsesScopesAndControlsInBothAspects() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    for aspect in [PortraitFeedAspect.fit16x9, .fill] {
        let z = MonitorPortraitLayout.zones(
            viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .clean,
            aspect: aspect, scopeCount: 2)
        #expect(z.scopes.height == 0 && z.controls.height == 0)
        #expect(z.systemBar.maxY <= 810)
    }
}

@Test func ultraShortViewportKeepsSystemBarInsideBottomSafeArea() {
    let sa = MonitorEdgeInsets(top: 40, leading: 0, bottom: 20, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 320, viewportHeight: 300, safeArea: sa, mode: .live,
        aspect: .fit16x9, scopeCount: 0)
    #expect(z.systemBar.maxY <= 300 - 20)
    for r in [z.topBar, z.scopes, z.controls, z.systemBar] { #expect(r.height >= 0) }
}
```

  Plus the preference (in `OperatorPreferencesTests.swift`, following its existing encode/decode test pattern):

```swift
@Test func portraitFeedAspectDefaultsAndRoundTrips() throws {
    var prefs = OperatorPreferences()
    #expect(prefs.portraitFeedAspect == .fit16x9)
    prefs.portraitFeedAspect = .fill
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(OperatorPreferences.self, from: data)
    #expect(decoded.portraitFeedAspect == .fill)
}
```

- [ ] **Step 2: Run `just test` — expect FAIL** (new signature/type not defined; old zone tests removed in the same edit).
- [ ] **Step 3: Implement** — pure arithmetic per the Semantics block; `max(0,…)` clamps everywhere; doc comments on all public API. `PortraitFeedAspect` lives in `MonitorPortraitLayout.swift`. Preference decode-missing → `.fit16x9` (follow the file's existing optional-decode pattern).
- [ ] **Step 4: Run `just test` — expect PASS** (528+ tests; v1 zone tests replaced).
- [ ] **Step 5: NOTE — this task intentionally breaks the shell build** (`MonitorPortrait.swift` still calls the v1 API). Commit core + tests only; Task 3 restores the shell in the same PR-visible sequence. Run `just ios-build` ONLY to confirm the breakage is limited to `MonitorPortrait.swift` call sites, then:

```bash
git add Sources/OpenZCineCore/MonitorPortraitLayout.swift Sources/OpenZCineCore/OperatorPreferences.swift Tests/OpenZCineCoreTests/
git commit -m "feat(core): portrait zone policy v2 — aspect + scope-count driven"
```

---

### Task 2: Demo hooks for aspect + scope staging

**Files:**
- Modify: `ios/Runner/NativeAppRoot.swift` (env parsing block, ~:5600-5750)

**Interfaces:**
- Produces: `ZC_DEMO_FEED_ASPECT` = "fit16x9" | "fill" (sets `model.preferences.portraitFeedAspect`). Existing `ZC_DEMO_ASSIST_ON` already toggles tools (value = rawValue like "WAVE"; verify it accepts a comma list — if not, extend it to split on "," so two scopes can be staged: `ZC_DEMO_ASSIST_ON=WAVE,HISTO`).

- [ ] **Step 1: Implement both hooks** in the same env block as `ZC_DEMO_ORIENTATION` (comment style matches neighbors):

```swift
if let raw = env["ZC_DEMO_FEED_ASPECT"],
    let aspect = PortraitFeedAspect(rawValue: raw)
{
    // Demo/screenshot affordance: stage the portrait feed aspect (fit16x9/fill).
    model.preferences.portraitFeedAspect = aspect
}
```

- [ ] **Step 2: Build (`just ios-build`), commit** (verification rides with Task 3's screenshots — the hook has no visible effect until the shell consumes the preference):

```bash
git add ios/Runner/NativeAppRoot.swift
git commit -m "feat(ios): demo hooks for portrait feed aspect and multi-tool staging"
```

---

### Task 3: Shell v2 skeleton — top bar overlay, feed-to-top, bottom system bar

**Files:**
- Create: `ios/Runner/MonitorPortraitModules.swift` (register in project.pbxproj — 4 locations)
- Modify: `ios/Runner/MonitorPortrait.swift` (shell rewrite to v2 zones)

**Interfaces:**
- Consumes: Task 1's `zones(viewportWidth:viewportHeight:safeArea:mode:aspect:scopeCount:)`; `model.preferences.portraitFeedAspect`; existing `Timecode.label`-adjacent fields (`model.cameraState.timecode` with `.hour/.minute/.second/.frame`), `model.cameraState.media`, `cameraBatteryPercent`, `BatteryIndicator` (ios/Runner/MonitorExperience.swift:1831 — check its init; if it's rail-specific, use `BatteryPill` MonitorControls.swift:98), `RecordButton` + confirmation-alert block (copy lives in `PortraitRecordRow` today — carry it over), `PortraitDisplayButton`, `model.interfaceLocked`, `model.activePanel = .media / .settings` open paths (grep `case media`/`openStandaloneSettings` for the exact portrait-safe entry points).
- Produces: `PortraitTopBar`, `PortraitSystemBar` (lock · DISP · record · Media · Settings), the v2 shell mounting them; `scopeCount` computed as `min(2, enabled scope tools)` where scope tools = `[.waveform, .parade, .histogram, .trafficLights]` intersected with `model.preferences.liveViewVisibleAssistTools` (order: the tool order in `liveViewVisibleAssistTools`' canonical ordering — first two win).

- [ ] **Step 1: Build `PortraitTopBar`** in the new file — glass scrim over the feed top (reuse `LiveDesign.glass` background):

```swift
/// Overlaid top info bar: timecode (accent frames) · centered storage/minutes · camera battery.
struct PortraitTopBar: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        let tc = model.cameraState.timecode
        ZStack {
            // Centered on the SCREEN, not leftover space (spec §1).
            Text(model.cameraState.media)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiveDesign.muted)
            HStack {
                (Text(String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second))
                    .foregroundStyle(LiveDesign.text)
                    + Text(String(format: ":%02d", tc.frame))
                    .foregroundStyle(LiveDesign.accent))
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                Spacer()
                BatteryPill(percent: model.cameraState.cameraBatteryPercent)
            }
        }
        .padding(.horizontal, 16)
        .background(LiveDesign.glass)
    }
}
```

  (Verify `BatteryPill`'s real init at MonitorControls.swift:98 and adapt the call — do not invent parameters. If it needs charging state, `model.cameraState` carries the external-power flag via the snapshot — trace `onExternalPower` usage in the landscape battery rail.)

- [ ] **Step 2: Build `PortraitSystemBar`** — the mockup's bottom band; carry the record confirmation alert over from `PortraitRecordRow` VERBATIM (it was a reviewed fix — b8f2f06), then DELETE `PortraitRecordRow`:

```swift
/// Persistent bottom band: lock · DISP · record (center) · Media · Settings.
struct PortraitSystemBar: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            lockButton.frame(maxWidth: .infinity)
            PortraitDisplayButton().frame(maxWidth: .infinity)
            recordButton.frame(maxWidth: .infinity)   // the carried-over button+alert
            mediaButton.frame(maxWidth: .infinity)
            settingsButton.frame(maxWidth: .infinity)
        }
    }
}
```

  Lock/media/settings buttons: reuse the landscape rail's icons and actions (grep the rail for `interfaceLocked` toggle, the media panel presentation, and `openStandaloneSettings`/settings panel presentation; copy the action wiring, style the buttons like `PortraitDisplayButton`'s chrome).

- [ ] **Step 3: Rewrite `PortraitMonitorShell`** to v2 zones: feed mounted at `zones.feed` (unchanged wrappers), `PortraitTopBar` at `zones.topBar` (over the feed), scopes/controls zones left EMPTY this task (Tasks 4-5 fill them; temporary `Color.clear`), `PortraitSystemBar` at `zones.systemBar`, PanelHost unchanged. Delete the TabView pages mount (`PortraitControlPages` stays in the file, unmounted, until Task 5 decides its fate).

- [ ] **Step 4: Register the new file in pbxproj; build; screenshot-verify** (fresh DD, mtime check): plain portrait launch with `ZC_DEMO_AUTOSTART=1` → feed at top with the bar floating on it (timecode accent frames visible, storage centered, battery right), empty middle, system bar with 5 controls clear of the home indicator. All four edges. Landscape shot via `ZC_DEMO_ORIENTATION=landscape` → UNCHANGED landscape monitor.

- [ ] **Step 5: `just native-check` (fallback per constraints), commit:**

```bash
git add ios/Runner/MonitorPortraitModules.swift ios/Runner/MonitorPortrait.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): portrait v2 shell — overlaid top bar, feed to top, bottom system bar"
```

---

### Task 4: Pinch aspect — gesture, center-crop fill, persistence

**Files:**
- Modify: `ios/Runner/MonitorPortrait.swift`

**Interfaces:**
- Consumes: `model.preferences.portraitFeedAspect` (persisted via the preferences store's existing didSet path — verify writes persist by relaunching), zones v2.
- Produces: pinch on the feed toggles `.fit16x9` ↔ `.fill` (threshold: `MagnificationGesture` final scale > 1.15 → `.fill`, < 0.87 → `.fit16x9`; in-between → no change), `withAnimation(.easeInOut(duration: 0.25))`. Fill rendering: the feed module's wrapper sizes the CONTENT to `width = zones.feed.height * 16/9` centered horizontally (negative x offset), `.clipped()` to the zone — the existing wrapper pattern already clips; only the inner width changes.

- [ ] **Step 1: Implement** — gesture on the feed area (`.simultaneousGesture` so tap-to-focus keeps working; verify the feed's existing tap gesture still fires afterward by code trace), aspect written through the model so `didSet` persists.
- [ ] **Step 2: Screenshot-verify both aspects** via `ZC_DEMO_FEED_ASPECT=fit16x9` / `fill` (gesture itself can't be driven headless — state the deferral; the states are what's verifiable): fill mode shows the feed cropped, filling top-bar→system-bar, no letterbox bands; fit mode identical to Task 3's shot. Relaunch WITHOUT the hook after a `fill` run → still `fill` (persistence proof).
- [ ] **Step 3: `just native-check`, commit:**

```bash
git add ios/Runner/MonitorPortrait.swift
git commit -m "feat(ios): pinch-snap portrait feed aspect with center-crop fill"
```

---

### Task 5: Controls morph — tiles (fit) vs capture bar (fill) + dynamic scopes

**Files:**
- Modify: `ios/Runner/MonitorPortrait.swift`, `ios/Runner/MonitorPortraitModules.swift`

**Interfaces:**
- Consumes: `CommandPrimaryGrid(availableHeight:columns:)`; `BottomCaptureSettingsModule` (ios/Runner/MonitorExperience.swift:1254 — read its init/geometry deps first; if it hard-couples to landscape chrome frames, build `PortraitCaptureBar` in MonitorPortraitModules.swift reusing `CaptureSettingButton` (:1295) in a horizontal `ScrollView` instead — REUSE the buttons, never reimplement them); scope plots via the existing `PortraitScopesFrame` sample path (B4); `scopeCount` from Task 3.
- Produces: `PortraitScopesStack` (1-2 stacked scope panels, each `scopeUnitHeight`, scope kinds = the first ≤2 enabled scope tools, rendered with the same plots the old frame used); fit mode mounts `PortraitScopesStack` in `zones.scopes` + tiles in `zones.controls`; fill mode mounts the capture bar in `zones.controls` (overlaying the feed bottom) + `PortraitScopesStack` overlaying the feed top-left (width ≈ 60% of viewport, same stacked heights). `PortraitControlPages` and `PortraitScopesFrame` are DELETED once their reused pieces are extracted.

- [ ] **Step 1: Build `PortraitScopesStack`** — extract the plot-hosting from `PortraitScopesFrame` (same sampler, same plot views), parameterized by the enabled scope kinds (no tap-to-swap anymore — what's enabled is what shows, first two).
- [ ] **Step 2: Fit-mode wiring** — scopes stack + `CommandPrimaryGrid(availableHeight: zones.controls.height - 8, columns: 3)`; verify tiles reflow between scopeCount 0/1/2 (three screenshots via `ZC_DEMO_ASSIST_ON=` unset / `WAVE` / `WAVE,HISTO` with `ZC_DEMO_SCOPE_SAMPLES=1`).
- [ ] **Step 3: Fill-mode wiring** — capture bar overlaid at the feed bottom (chevron scroll affordance visible), scopes stack overlaying the feed; two screenshots (0 and 2 scopes). Delete `PortraitControlPages` + `PortraitScopesFrame` and their mounts; grep both names to confirm zero references remain.

- [ ] **Step 3b: Command mode** — mounts `CommandPrimaryGrid(availableHeight: zones.controls.height, columns: 3)` in `zones.controls` regardless of aspect (zones already span topBar→systemBar in `.command`); feed stays unmounted (power-saving parity). One screenshot via `ZC_DEMO_DISP=command`.
- [ ] **Step 4: `just native-check`, commit:**

```bash
git add ios/Runner/MonitorPortrait.swift ios/Runner/MonitorPortraitModules.swift
git commit -m "feat(ios): portrait controls morph with aspect; dynamic stacked scopes"
```

---

### Task 6: Assist rail + REC options button

**Files:**
- Modify: `ios/Runner/MonitorPortrait.swift`, `ios/Runner/MonitorPortraitModules.swift`

**Interfaces:**
- Consumes: `AssistToolButtonRow`/`AssistToolButton` (ios/Runner/MonitorExperience.swift:1542/:1626 — reuse the BUTTON, arrange vertically; long-press must keep opening the tool options popup — trace how the landscape row wires long-press and reuse that closure), `model.showPicker(.resolution)` / `.codec`.
- Produces: `PortraitAssistRail` — collapsed pill button bottom-left OVER the feed; expanded = full-feed-height vertical `ScrollView` of assist tool buttons on a glass surface at the feed's left edge; collapse via the pill or tapping the feed. `PortraitRecOptionsButton` — top-right over the feed (below the top bar), opens a two-item popup (Resolution·Framerate / Codec) that calls `showPicker(.resolution)` / `showPicker(.codec)`.

- [ ] **Step 1: Build + mount the rail** (both aspects; `@State private var railExpanded`). Screenshot: collapsed pill clear of the scopes stack; expanded rail full height, scrollable, tools toggling (verify one toggle by launching with `ZC_DEMO_ASSIST_ON=WAVE` and checking the WAVE button renders active in the rail).
- [ ] **Step 2: Build + mount REC options**; screenshot with the popup open (`ZC_DEMO` can't tap — stage by code-trace + a temporary `@State initial = true` REVERTED before commit, like B7's temporary-edit pattern; note it in the report).
- [ ] **Step 3: `just native-check`, commit:**

```bash
git add ios/Runner/MonitorPortrait.swift ios/Runner/MonitorPortraitModules.swift
git commit -m "feat(ios): portrait assist rail and REC options quick access"
```

---

### Task 7: Bottom-anchored popups

**Files:**
- Modify: `ios/Runner/MonitorPanels.swift` (`bottomPickerBody`'s portrait arm :696-710 region; `AssistOptionsPopupAnchor`'s portrait arm :1797+)

**Interfaces:**
- Consumes: `PanelHost(… isPortrait: true)` (already threaded); the existing X-close and backdrop-tap dismissal (already generalized — verify `handleBackdropTap` routes to dismiss when no capture frames are registered in portrait; the stale-anchor fix already gates the frames).
- Produces: in portrait, picker AND assist-options panels anchor `alignment: .bottom`, full width minus 12pt side margins, bottom edge at the SCREEN bottom (over the system bar — spec §4), slide-up presentation reusing the panels' existing reveal mechanics.

- [ ] **Step 1: Implement** — portrait arms only (`isPortrait` is already the gate; landscape expressions untouched byte-for-byte).
- [ ] **Step 2: Screenshot** ISO picker + stabilization picker + one assist-options popup (long-press staging: `ZC_DEMO_POPOVER` exists — check its semantics at NativeAppRoot ~:5649) in BOTH aspects: panel bottom-flush, overlapping the system bar, X reachable, nothing clipped.
- [ ] **Step 3: `just native-check`, commit:**

```bash
git add ios/Runner/MonitorPanels.swift
git commit -m "feat(ios): portrait popups anchor to the screen bottom"
```

---

### Task 8: Rung-2 rotation heroes

**Files:**
- Modify: `ios/Runner/MonitorExperience.swift` (`LiveViewShell` :48-165), `ios/Runner/MonitorPortrait.swift`, the landscape record/DISP button sites (`RightRailControlsModule` :1115+)

**Interfaces:**
- Produces: one `@Namespace private var monitorRotation` on `LiveViewShell`, passed to both branches; `matchedGeometryEffect(id:in:)` tags — `"feed"` on the feed module wrapper (both branches), `"record"` on the record button (portrait system bar + landscape rail), `"disp"` on the DISP button (both) — plus `.animation(.easeInOut(duration: 0.3), value: context.isPortrait)` on the branch container and a `.transition(.opacity)` default for unmatched chrome.

- [ ] **Step 1: Implement the namespace + tags.** The landscape tags are the ONLY landscape diff in this plan — keep them modifier-only (no structural moves); `git diff -w` on MonitorExperience.swift must show only added modifiers.
- [ ] **Step 2: Verify end states** (portrait launch + `ZC_DEMO_ORIENTATION=landscape` launch — both render identically to pre-task screenshots) and the DEVICE animation is the operator's checklist item (state it in the report — the live morph can't be captured headless).
- [ ] **Step 3: `just native-check`, commit:**

```bash
git add ios/Runner/MonitorExperience.swift ios/Runner/MonitorPortrait.swift
git commit -m "feat(ios): rotation morph heroes — feed, record, DISP across orientation branches"
```

---

### Task 9: Sweep, docs, rung-3 stub

**Files:**
- Verify: full state matrix; Modify: `docs/ARCHITECTURE.md` (portrait v2 note), `docs/design/specs/2026-07-07-portrait-monitor-v2-design.md` (record shipped deviations)
- Create: `docs/design/specs/2026-07-07-monitor-shell-unification-rung3-stub.md` (½ page: goal — one zone-driven tree for both orientations; prerequisites — v2 stable, landscape chrome absorbed module-by-module; NOT scheduled)

- [ ] **Step 1: Screenshot matrix** — {fit, fill} × {0,1,2 scopes} × {rail collapsed, expanded} × {live, clean, command} portrait, + landscape live/clean/command regression, + both pickers bottom-anchored. Fix small clips found (report anything structural instead of fixing).
- [ ] **Step 2: Docs + stub; `just native-check` + `just check`** (known editorconfig failure noted).
- [ ] **Step 3: Commit:**

```bash
git add -A docs ios
git commit -m "feat(ios): portrait v2 sweep fixes, docs, rung-3 stub"
```
