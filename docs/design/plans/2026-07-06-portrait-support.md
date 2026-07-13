# App-Wide Portrait Support Implementation Plan

**Goal:** Every screen works in portrait: monitor gets the approved feed → scopes → paged-controls → record stack; startup, media, settings, and RED download reflow; landscape stays pixel-identical.

**Architecture:** Portrait zone geometry is computed in the UI-free core (`MonitorPortraitLayout`, unit-tested) exactly like the existing `MonitorFeedLayout`/`StartupContentLayout` policies. The shell branches once per screen on `height > width` from its own `GeometryReader` — no new UIKit orientation plumbing (the existing `MonitorDeviceOrientationReader` already returns portrait cases and `MonitorHorizontalLayoutDirection.resolve` already treats portrait as `.standard`).

**Tech Stack:** Swift 6.0, SwiftUI (`@Observable`, `NavigationStack`-era idioms), Swift Testing.

## Global Constraints

- Spec: `docs/design/specs/2026-07-06-disp3-and-portrait-design.md` (workstream B). Zone budget (iPhone 390×844pt): info bar ~44, feed 219 (width·9/16), scopes ~150, pages ~230, record ~120.
- Branch: `ui/general-improvements`. Never commit to `main`.
- Verify with `just native-check` (fallback if the local test runner ABI-crashes: `just ios-build` + `just check`; CI covers tests).
- **Screenshot-verify EVERY UI change in BOTH orientations (MANDATORY).** Landscape shots need `sips -r -90` to read; portrait shots don't. Inspect all four edges: nothing clipped, nothing flush against the home indicator, no `…` truncation. Before trusting any screenshot, confirm the Runner binary mtime is newer than your last edit (stale-binary trap — repo memory).
- Landscape must remain pixel-identical — portrait code paths are additive branches.
- **pbxproj gotcha (repo memory):** every NEW `.swift` file — core *or* shell — must be added to `ios/Runner.xcodeproj/project.pbxproj` (follow the pattern of an existing file entry) or the app target won't compile it. New files in this plan: `Sources/OpenZCineCore/MonitorPortraitLayout.swift`, `ios/Runner/MonitorPortrait.swift`.
- Out of scope: vertical 9:16 shooting, upside-down portrait, iPad multitasking (`UIRequiresFullScreen` stays true).
- **Spec deviation (deliberate):** the spec says orientation is "exposed once via SwiftUI environment"; this plan instead applies the same `height > width` rule per screen from each screen's existing `GeometryReader` — one uniform rule, zero new plumbing. Introduce an environment key only if a screen turns up that has no geometry of its own.

---

### Task 1: Unlock portrait + startup screen verification

**Files:**
- Modify: `ios/Runner/Info.plist:95-109`

**Interfaces:**
- Produces: the app rotates. `StartupContentLayout.fit()` (MonitorLayoutPolicy.swift:941) already returns `.compactPortrait`/single-column for portrait viewports — this task proves it on screen.

- [ ] **Step 1: Edit Info.plist.** Add `<string>UIInterfaceOrientationPortrait</string>` as the FIRST entry of both `UISupportedInterfaceOrientations` and `UISupportedInterfaceOrientations~ipad`, and replace the stale comment ("Landscape-only until portrait monitor UI is implemented…") with: `Portrait + landscape. UIRequiresFullScreen opts out of iPad multitasking (App Store error 90474).`

- [ ] **Step 2: Build and run.** `just ios-build`, launch in the simulator, rotate to portrait (`Cmd+←` in Simulator, or `xcrun simctl` UI). The startup/link screen should render single-column via the existing `compactPortrait` profile.

- [ ] **Step 3: Screenshot-verify startup in BOTH orientations.** `xcrun simctl io booted screenshot /tmp/claude/startup-portrait.png` (no rotation needed) and the landscape shot (rotate with `sips -r -90`). Check all four edges. Fix any margin/clip issues inside `StartupLayoutMargins`/`StartupContentLayout` parameters only if the screenshots show real defects.

- [ ] **Step 4: Screenshot the monitor in portrait to document the baseline.** It will look wrong (landscape chrome on a tall viewport) — that's expected until Task 3; the feed itself already letterboxes correctly (`MonitorFeedLayout.frame` portrait branch, MonitorLayoutPolicy.swift:267-271). Nothing should crash.

- [ ] **Step 5: Commit.**

```bash
git add ios/Runner/Info.plist
git commit -m "feat(ios): unlock portrait orientation"
```

---

### Task 2: Core — `MonitorPortraitLayout` zone policy (TDD)

**Files:**
- Create: `Sources/OpenZCineCore/MonitorPortraitLayout.swift` (register in project.pbxproj — Global Constraints)
- Test: `Tests/OpenZCineCoreTests/MonitorPortraitLayoutTests.swift` (new)

**Interfaces:**
- Consumes: `MonitorLayoutRegion`, `MonitorFeedFrame`, `MonitorEdgeInsets`, `MonitorFeedLayout.aspectRatio`, `DispMode` (CameraDisplayState.swift).
- Produces:

```swift
public struct MonitorPortraitZones: Equatable, Sendable {
    public let infoBar: MonitorLayoutRegion
    public let feed: MonitorFeedFrame
    public let scopes: MonitorLayoutRegion   // height 0 in .clean
    public let pages: MonitorLayoutRegion    // height 0 in .clean; full lower area in .command
    public let record: MonitorLayoutRegion
}
public enum MonitorPortraitLayout {
    public static let infoBarHeight = 44.0
    public static let recordRowHeight = 120.0
    public static let minScopesHeight = 110.0
    public static let preferredScopesHeight = 150.0
    public static func zones(
        viewportWidth: Double, viewportHeight: Double,
        safeArea: MonitorEdgeInsets, mode: DispMode
    ) -> MonitorPortraitZones
}
```

- [ ] **Step 1: Write the failing tests** (new file, `import Testing` + `@testable import OpenZCineCore`):

```swift
@Test func liveZonesStackWithoutOverlapOn390x844() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .live)
    #expect(z.infoBar.y >= 59)
    #expect(z.feed.width == 390)
    #expect(abs(z.feed.height - 390 * 9 / 16) < 0.5)
    #expect(z.feed.y >= z.infoBar.maxY)
    #expect(z.scopes.y >= z.feed.y + z.feed.height)
    #expect(z.scopes.height >= MonitorPortraitLayout.minScopesHeight)
    #expect(z.pages.y >= z.scopes.maxY)
    #expect(z.record.y >= z.pages.maxY)
    #expect(z.record.maxY <= 844 - 34)
}

@Test func cleanModeCollapsesScopesAndPages() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .clean)
    #expect(z.scopes.height == 0)
    #expect(z.pages.height == 0)
    #expect(z.record.maxY <= 844 - 34)
}

@Test func commandModeGivesLowerAreaToPages() {
    let sa = MonitorEdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 390, viewportHeight: 844, safeArea: sa, mode: .command)
    #expect(z.scopes.height == 0)
    #expect(z.pages.y >= z.feed.y + z.feed.height)
    #expect(z.pages.height > 300)
    #expect(z.record.maxY <= 844 - 34)
}

@Test func shortViewportNeverProducesNegativeRegions() {
    let sa = MonitorEdgeInsets(top: 40, leading: 0, bottom: 20, trailing: 0)
    let z = MonitorPortraitLayout.zones(
        viewportWidth: 320, viewportHeight: 480, safeArea: sa, mode: .live)
    for r in [z.infoBar, z.scopes, z.pages, z.record] { #expect(r.height >= 0) }
}
```

- [ ] **Step 2: Run `just test` to verify FAIL** (type not defined).

- [ ] **Step 3: Implement** — pure arithmetic, top-down allocation: infoBar at `safeArea.top`, feed strip below it (full width, 16:9), record row pinned above `safeArea.bottom`; remaining middle goes to scopes (clamped `minScopesHeight...preferredScopesHeight` in `.live`) with pages taking the rest; `.clean` zero-heights scopes+pages; `.command` zero-heights scopes and gives pages the whole middle. Clamp every height with `max(0, …)` (`MonitorLayoutRegion.init` already floors at 0). Doc-comment the public API.

- [ ] **Step 4: Run `just test` to verify PASS.**

- [ ] **Step 5: Register the new file in project.pbxproj, run `just ios-build` to prove the app target sees it, then commit.**

```bash
git add Sources/OpenZCineCore/MonitorPortraitLayout.swift Tests/OpenZCineCoreTests/MonitorPortraitLayoutTests.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(core): portrait monitor zone layout policy"
```

---

### Task 3: Shell — portrait monitor shell (skeleton: feed + info bar + record)

**Files:**
- Create: `ios/Runner/MonitorPortrait.swift` (register in project.pbxproj)
- Modify: `ios/Runner/MonitorExperience.swift:48-165` (`LiveViewShell`), `:180-206` (`LiveViewLayoutContext`)

**Interfaces:**
- Consumes: `MonitorPortraitLayout.zones`, `LiveFeedModule(safeArea:viewportWidth:canvasOffsetX:)`, `FeedAssistOverlayModule`, `RecordButton` (MonitorExperience.swift:1754), `model.displayMode`.
- Produces: `PortraitMonitorShell(context:)` view; `LiveViewLayoutContext.isPortrait: Bool` and `.viewportHeight: Double`.

- [ ] **Step 1: Extend the context.** In `LiveViewLayoutContext` add stored `let isPortrait: Bool` and `let viewportHeight: Double`, set in `init`: `isPortrait = proxy.size.height > proxy.size.width`, `viewportHeight = Double(proxy.size.height)`. Also change `private struct LiveViewLayoutContext` (MonitorExperience.swift:180) to `struct LiveViewLayoutContext` — the new `MonitorPortrait.swift` consumes it.

- [ ] **Step 2: Branch the shell.** In `LiveViewShell.body`, wrap the existing ZStack content: when `context.isPortrait`, render `PortraitMonitorShell(context: context).environment(model)` instead of the landscape chrome/rails/command layers — but keep the shared pieces (full-screen-panel overlay at :135-153, `RecordingBorderModule` overlay, `.animation` modifiers) common to both branches. The live feed + assist overlay modules render in BOTH branches (they already read the portrait feed frame from `MonitorFeedLayout`); in portrait they are offset into the feed zone.

- [ ] **Step 3: Write the skeleton** (`ios/Runner/MonitorPortrait.swift`):

```swift
import SwiftUI

/// Portrait monitor: info bar → 16:9 feed strip → scopes frame → paged controls → record row.
/// Zone geometry comes from `MonitorPortraitLayout` (core, unit-tested); this view only mounts
/// modules into those zones.
struct PortraitMonitorShell: View {
    @Environment(NativeAppModel.self) private var model
    let context: LiveViewLayoutContext

    var body: some View {
        let zones = MonitorPortraitLayout.zones(
            viewportWidth: context.viewportWidth,
            viewportHeight: context.viewportHeight,
            safeArea: context.feedSafeArea,
            mode: model.displayMode
        )
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PortraitInfoBar()
                .frame(width: zones.infoBar.width, height: zones.infoBar.height)
                .offset(x: zones.infoBar.x, y: zones.infoBar.y)
            if model.displayMode != .command {
                LiveFeedModule(
                    safeArea: context.feedSafeArea,
                    viewportWidth: context.viewportWidth,
                    canvasOffsetX: context.canvasOffsetX
                )
                .frame(width: zones.feed.width, height: zones.feed.height)
                .offset(x: zones.feed.x, y: zones.feed.y)
                FeedAssistOverlayModule(
                    safeArea: context.feedSafeArea,
                    viewportWidth: context.viewportWidth,
                    canvasOffsetX: context.canvasOffsetX
                )
                .frame(width: zones.feed.width, height: zones.feed.height)
                .offset(x: zones.feed.x, y: zones.feed.y)
            }
            PortraitRecordRow()
                .frame(width: zones.record.width, height: zones.record.height)
                .offset(x: zones.record.x, y: zones.record.y)
        }
    }
}

/// Slim single-line status: timecode · clip/media · camera battery.
struct PortraitInfoBar: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        let tc = model.cameraState.timecode
        HStack {
            Text(String(format: "%02d:%02d:%02d:%02d", tc.hour, tc.minute, tc.second, tc.frame))
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
            Spacer()
            Text(model.cameraState.media)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiveDesign.muted)
            Text("\(model.cameraState.cameraBatteryPercent)%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
        }
        .padding(.horizontal, 16)
    }
}

/// Record button centered in the thumb zone.
struct PortraitRecordRow: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        HStack { Spacer(); RecordButton(); Spacer() }
    }
}
```

  Before building: verify the referenced initializers (`LiveFeedModule`/`FeedAssistOverlayModule` signatures at MonitorExperience.swift:68-78, `RecordButton` at :1754, timecode text at MonitorPanels.swift:100) and the exact `media`/battery property names on `CameraDisplayState` — adjust the skeleton to the real signatures (they are close by; do not invent new model API). If `LiveFeedModule` positions itself from the safe area rather than filling its container, drop the `.frame/.offset` wrappers and let it self-place — the portrait feed frame from `MonitorFeedLayout.frame` is already correct.

- [ ] **Step 4: Register the file in project.pbxproj. Build + screenshot-verify** portrait monitor (demo mode): info bar top, feed strip below, record centered low, home indicator clear. Verify landscape monitor is UNCHANGED (screenshot + compare against Task 1's baseline). Iterate until both are clean.

- [ ] **Step 5: Run `just native-check`, commit.**

```bash
git add ios/Runner/MonitorPortrait.swift ios/Runner/MonitorExperience.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): portrait monitor shell — feed strip, info bar, record row"
```

---

### Task 4: Shell — scopes frame in the portrait middle zone

**Files:**
- Modify: `ios/Runner/MonitorPortrait.swift`

**Interfaces:**
- Consumes: `WaveformScopePlot` / `HistogramScopePlot` (MonitorOverlays.swift:1361/:1468) and whatever sample source feeds them in landscape (`LiveWaveformScopePanel`, MonitorOverlays.swift:110 — read it first).
- Produces: `PortraitScopesFrame` mounted into `zones.scopes` when `zones.scopes.height > 0`.

- [ ] **Step 1: Discovery.** Read `MonitorOverlays.swift:90-260` and `:1340-1520` to learn the plot init signatures and where scope samples come from (the landscape scope panel's data path). The portrait frame must reuse the same sampler — no new sampling code.

- [ ] **Step 2: Implement `PortraitScopesFrame`.** Skeleton (fill `scopeContent` by copying the plot construction — including its sample source — exactly from `LiveWaveformScopePanel`, MonitorOverlays.swift:110; do NOT write a new sampler):

```swift
/// Scopes frame between the feed and the control pages. Tap cycles the scope.
struct PortraitScopesFrame: View {
    @Environment(NativeAppModel.self) private var model
    @State private var scopeIndex = 0

    var body: some View {
        RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            .fill(LiveDesign.surface)
            .overlay(scopeContent.padding(8))
            .contentShape(Rectangle())
            .onTapGesture { scopeIndex = (scopeIndex + 1) % 2 }
    }

    @ViewBuilder private var scopeContent: some View {
        // scopeIndex 0 = WaveformScopePlot, 1 = HistogramScopePlot — constructed
        // verbatim from LiveWaveformScopePanel's plot embedding (same sample source).
    }
}
```

  Persist the chosen scope in `@State` only; move it to `OperatorPreferences` only if a persisted scope-choice pattern already exists (`grep -n "scope" Sources/OpenZCineCore/OperatorPreferences.swift`). Mount in `PortraitMonitorShell` under the feed when `zones.scopes.height > 0`.

- [ ] **Step 3: Build + screenshot-verify** portrait: scopes frame sits between feed and lower area, plot renders (demo feed drives it), tap swaps scope. All edges clean.

- [ ] **Step 4: Run `just native-check`, commit.**

```bash
git add ios/Runner/MonitorPortrait.swift
git commit -m "feat(ios): portrait scopes frame with tap-to-swap"
```

---

### Task 5: Shell — paged controls (Control / Grid / Assist) + DISP behavior

**Files:**
- Modify: `ios/Runner/MonitorPortrait.swift`, `ios/Runner/MonitorPanels.swift:113-134` (`CommandPrimaryGrid` column count)

**Interfaces:**
- Consumes: `CommandPrimaryGrid` (MonitorPanels.swift:113), `AssistToolButtonRow` (MonitorExperience.swift:1542), guide/grid toggle rows (locate via `grep -n "Guide\|Grid" ios/Runner/MonitorControls.swift ios/Runner/MonitorPanels.swift`), `model.showPicker`, `model.displayMode` cycling (`cycleDisplayMode`, NativeAppRoot.swift:4141).
- Produces: `PortraitControlPages` (a `TabView(.page)` with three pages), `CommandPrimaryGrid(columns:)` parameter.

- [ ] **Step 1: Parametrize the grid.** In `CommandPrimaryGrid`, change `private let columns = 3` to `var columns: Int = 3` (landscape call sites unchanged — default keeps them at 3).

- [ ] **Step 2: Implement `PortraitControlPages`.** Skeleton (the Grid page's rows come from step 1's grep — reuse those toggle views, never re-implement them; `AssistToolButtonRow`'s real init may need arguments, adjust from its definition at MonitorExperience.swift:1542):

```swift
/// Swipeable Control / Grid / Assist pages below the scopes frame.
struct PortraitControlPages: View {
    @Environment(NativeAppModel.self) private var model
    let pageHeight: CGFloat

    var body: some View {
        TabView {
            CommandPrimaryGrid(availableHeight: pageHeight, columns: 2)
                .padding(.horizontal, 12)
            ScrollView {
                // Framing guide / grid / crosshair / level toggle rows (step 1 grep),
                // stacked vertically — the same views the landscape panels mount.
            }
            .padding(.horizontal, 12)
            AssistToolButtonRow()
                .padding(.horizontal, 12)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
    }
}
```

  Mount into `zones.pages` when height > 0. Add a DISP button to `PortraitRecordRow` (reuse the landscape DISP button component — `grep -n "\"DISP\"" ios/Runner/MonitorExperience.swift`, :1203) so mode cycling works in portrait.

- [ ] **Step 3: DISP mode sweep.** In portrait, cycle live → clean → command: live shows all zones; clean collapses scopes+pages (zone policy already returns zero heights — verify the views actually unmount, not squish); command hides the feed (match the landscape power-saving behavior: `model.displayMode == .command` skips `LiveFeedModule` — already handled in Task 3's shell) and the pages zone shows the Control grid full-height.

- [ ] **Step 4: Build + screenshot-verify each of the three DISP modes in portrait** (three screenshots, all four edges each) + one landscape regression shot. Verify pickers opened from portrait tiles render fully on-screen — if `PanelHost` anchors assume landscape chrome insets, position the panel against the portrait viewport (fix in the `PanelHost` call site inside the portrait branch only).

- [ ] **Step 5: Run `just native-check`, commit.**

```bash
git add ios/Runner/MonitorPortrait.swift ios/Runner/MonitorPanels.swift ios/Runner/MonitorExperience.swift
git commit -m "feat(ios): portrait paged controls and DISP mode behavior"
```

---

### Task 6: Media browser portrait reflow

**Files:**
- Modify: `ios/Runner/MediaBrowser.swift:150-170` (root layout), sidebar section (read `sidebar` definition first — :155 region)

**Interfaces:**
- Consumes: existing `sidebar` content views, `mainHeader`, `gridContent`.
- Produces: portrait branch — horizontal category strip above the grid.

- [ ] **Step 1: Implement.** Wrap `MediaBrowserView.body`'s content in a `GeometryReader`; `let portrait = proxy.size.height > proxy.size.width`. Portrait: `VStack(spacing: 8) { categoryStrip; mainHeader; gridContent }` where `categoryStrip` is a horizontal `ScrollView` of the SAME tab/filter buttons the sidebar renders (extract the button row from `sidebar` into a shared subview rather than duplicating it). Landscape: existing `HStack` untouched. Adjust the portrait paddings: `.padding(.leading, max(CGFloat(safeArea.leading) + 6, 16))` (the landscape 64pt floor exists to clear the side rail, which portrait doesn't have).

- [ ] **Step 2: Build + screenshot-verify** portrait browse (grid reflows via its adaptive columns), portrait player and photo viewer (already center-based — verify only), landscape regression shot.

- [ ] **Step 3: Run `just native-check`, commit.**

```bash
git add ios/Runner/MediaBrowser.swift
git commit -m "feat(ios): media browser portrait layout with category strip"
```

---

### Task 7: Settings panel portrait reflow

**Files:**
- Modify: `ios/Runner/MonitorPanels.swift:2605-2636` (`OperatorSettingsPanel.body`), `settingsRail` definition (read first)

- [ ] **Step 1: Implement.** Same pattern as Task 6: `GeometryReader`; portrait → `VStack { settingsTop; horizontal tab strip; settingsContent }` where the tab strip is the rail's tab buttons in a horizontal `ScrollView`; landscape keeps the existing `HStack(settingsRail, settingsContent)`. Keep the `CloseButton` overlay position valid in both (top-leading already works in portrait).

- [ ] **Step 2: Build + screenshot-verify** portrait settings across at least two tabs (longest tab strip state) + landscape regression.

- [ ] **Step 3: Run `just native-check`, commit.**

```bash
git add ios/Runner/MonitorPanels.swift
git commit -m "feat(ios): settings panel portrait layout with horizontal tab strip"
```

---

### Task 8: Remaining surfaces sweep + docs

**Files:**
- Verify (modify only if a screenshot shows a defect): `ios/Runner/RedDownloadView.swift`, camera-join popup, Tool Library / any `coversFullScreen` panel (`grep -n "coversFullScreen" ios/Runner/*.swift` for the list)
- Modify: `docs/ARCHITECTURE.md` (orientation section), `docs/design/specs/2026-07-06-disp3-and-portrait-design.md` (mark shipped deviations, if any)

- [ ] **Step 1: Screenshot sweep.** Every full-screen surface in portrait AND landscape: startup wizard steps, saved-cameras, join popup (use `ZC_DEMO_JOIN_POPUP` hook), RED download (`ZC_DEMO_OPEN_RED`), media, settings, monitor ×3 DISP modes. Fix what clips; re-shoot until clean. Keep the final screenshots for the PR description.

- [ ] **Step 2: Docs.** Add a short "Orientation" note to `docs/ARCHITECTURE.md`: portrait unlocked, zone policy in `MonitorPortraitLayout` (core), per-screen `height > width` branches in the shell.

- [ ] **Step 3: Full verification.** `just native-check` (fallback per Global Constraints) and `just check`. Expected: green.

- [ ] **Step 4: Commit.**

```bash
git add -A docs ios
git commit -m "feat(ios): portrait sweep fixes and orientation docs"
```
