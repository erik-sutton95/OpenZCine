# Assist-bar interaction model + popup unification — design

- **Status:** Draft (awaiting review)
- **Date:** 2026-06-26
- **Author:** Erik Sutton (with Claude Code)
- **Scope:** iOS shell (`ios/Runner`) + a small portable helper in `Sources/OpenZCineCore`

## Context

This is **Phase 1 of a larger LUT roadmap**. The original request — "add a LUT button to
the view-assist tools bar" — grew into a real LUT subsystem (RED official LUTs via a ToC-gated
download, generated open-source log→Rec.709 conversions, custom `.cube` import, real Core Image
application). That is too large for one spec, so it is decomposed into phases:

1. **Assist-bar interaction model + popup unification** ← _this document_
2. LUT engine: `.cube` parser + library in core, `CIColorCube` application in live view, a LUT
   button + basic picker, one generated N‑Log→709.
3. Custom `.cube` import.
4. Full generated open conversions (N‑Log→709, RWG/Log3G10→709) + picker organization.
5. RED official acquisition (WebView + RED's real T&C) + contrast/roll-off organization.

Phase 1 is deliberately **LUT-free**. It improves the interaction and presentation of the
*existing* assist tools so the later LUT button drops into a consistent, well-behaved bar. It is
independent and shippable on its own.

## Goals

1. **Uniform interaction across every button in the bottom assist bar:**
   - **Single tap → toggle the tool on/off.** Nothing else.
   - **Long press → open the tool's options**, but only for tools that have options
     (`MonitorAssistTool.hasConfiguration == true`).
2. **Unify the assist options popups with the exposure/picker popups** so they share the same
   behaviour, animation, and styling (anchored slide-up reveal + fade-in-place dismiss), instead
   of the current bottom-left scale/opacity pop.

## Non-goals (Phase 1)

- No LUT tool, LUT engine, `.cube` parsing, Core Image work, file import, or RED download.
- No change to the centred / full-screen panels (Media, Settings, Tool Library / `assistLibrary`).
- No change to the secondary assist surfaces (the numbered `AssistOrderStrip`, the command-mode
  tiles, the Tool Library editor). They keep single-tap-to-toggle. Phase 1 only changes the
  **primary bottom assist bar** interaction and the **per-tool options panels'** presentation.

## Current behaviour (baseline)

- **The bar** (`toolScroll`, [MonitorExperience.swift:1057](../../../ios/Runner/MonitorExperience.swift)):
  each tool is a `Button` whose action is `model.toggleAssist(tool)` **and**, if
  `tool.hasConfiguration`, also `model.showAssist(tool)` — so a single tap on a configurable tool
  both toggles *and* opens its panel (two actions conflated).
- **Options panel presentation** (`PanelHost`,
  [MonitorPanels.swift:353](../../../ios/Runner/MonitorPanels.swift)): the `.assist(tool)` case is
  placed `.bottomLeading` at a fixed width and animates with the shared
  `.opacity.combined(with: .scale(scale: 0.98))` transition
  ([MonitorExperience.swift:90](../../../ios/Runner/MonitorExperience.swift)) — a pop, not a slide.
- **The exposure pickers** (`bottomPickerBody`,
  [MonitorPanels.swift:390](../../../ios/Runner/MonitorPanels.swift)) instead slide up anchored to
  their bar: `model.captureBarFrame` (measured at
  [MonitorExperience.swift:864](../../../ios/Runner/MonitorExperience.swift)) +
  `pickerRevealed`/`schedulePickerReveal()`
  ([NativeAppRoot.swift:1546](../../../ios/Runner/NativeAppRoot.swift)) +
  `managesOwnAppearance` ([NativeAppRoot.swift:93](../../../ios/Runner/NativeAppRoot.swift)) to
  suppress the shared transition, dismissing by fading in place
  ([NativeAppRoot.swift:1566](../../../ios/Runner/NativeAppRoot.swift)).
- **The double-gate wrinkle:** Level and Desqueeze overlays render only when the tool is in
  `visibleAssistTools` **and** a *separate* `enabled` flag in `AssistConfiguration` is true
  ([MonitorOverlays.swift:55](../../../ios/Runner/MonitorOverlays.swift)). Today the panel's own
  "Enable" row keeps them in sync; a naïve "tap = toggle membership" would leave a tap on Level /
  Desqueeze visually inert.

## Design

### 1. Interaction model on the bar

Replace the `Button` in `toolScroll` with a styled, non-button view carrying two gestures:

- `.onTapGesture` → `model.toggleAssist(tool)`.
- `.onLongPressGesture(minimumDuration: 0.4)` → `model.presentAssistOptions(tool)`, which is a
  no-op when `!tool.hasConfiguration`.

Notes / constraints for implementation:

- The bar is a horizontal `ScrollView`; the gestures must not block scrolling. Verify the scroll
  drag still wins on horizontal movement. If `.onTapGesture` + `.onLongPressGesture` precedence is
  unreliable, fall back to an explicit `LongPressGesture().exclusively(before: TapGesture())` or a
  press-tracking `ButtonStyle`.
- Long-press on a **non-configurable** tool (Peaking, False Color, Zebra, Waveform, Parade,
  Histogram) does nothing — consistent with today (those never opened a panel from the bar).
- **Haptics:** a `.selection` tick on toggle and on panel open, gated by
  `preferences.hapticsEnabled`. The app already emits a selection tick when `activePanel` changes
  ([MonitorExperience.swift:37](../../../ios/Runner/MonitorExperience.swift)); add an equivalent
  `.sensoryFeedback` keyed to `visibleAssistTools` for the toggle.

### 2. On/off reconciliation (portable, testable)

Introduce a small **pure helper in `Sources/OpenZCineCore`** that owns the on/off semantics so a
tap reliably shows/hides every overlay, including the double-gated tools, and so every toggle
surface stays in sync:

```swift
// Sources/OpenZCineCore/AssistToolActivation.swift  (new)
public enum AssistToolActivation {
    /// Flips a tool's on/off state, mirroring the legacy per-tool `enabled` flags
    /// (Level, Desqueeze) to bar visibility so a single tap reliably shows/hides the overlay.
    public static func toggle(
        _ tool: MonitorAssistTool,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    )

    public static func set(
        _ tool: MonitorAssistTool,
        visible: Bool,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    )
}
```

`NativeAppModel.toggleAssist` / `setAssist`
([NativeAppRoot.swift:1628](../../../ios/Runner/NativeAppRoot.swift)) delegate to this helper. The
Level/Desqueeze panels' "Enable" rows continue to reflect the same state (now redundant with the
bar tap, but harmless and kept for Phase 1). The overlay gating in `MonitorOverlays` is unchanged.

### 3. Popup unification — generalize the picker reveal to all bar popups

Promote the picker-specific slide-reveal into a **shared panel reveal** that also drives the
assist options panels:

- **Rename for generality** (mechanical, single-meaning): `pickerRevealed → panelRevealed`,
  `schedulePickerReveal() → schedulePanelReveal()`, `pickerRevealCurve → panelRevealCurve`. Update
  all call sites (`showPicker`, `dismissActivePanel`, the reset at
  [NativeAppRoot.swift:1015](../../../ios/Runner/NativeAppRoot.swift), and the panel bodies).
- **`managesOwnAppearance`** returns `true` for `.picker` **and** `.assist`, so assist panels get
  the `.asymmetric(insertion: .identity, removal: .opacity)` transition and drive their own slide.
- **Measure the assist bar:** add `assistBarFrame: CGRect` to `NativeAppModel`, set from a
  `GeometryReader` background on the assist toolbar exactly as `captureBarFrame` is set on the
  capture bar ([MonitorExperience.swift:864](../../../ios/Runner/MonitorExperience.swift)).
- **Present:** `showAssist(tool)` mirrors `showPicker` — reset `panelRevealed = false`, set
  `activePanel = .assist(tool)`, call `schedulePanelReveal()`. A new
  `presentAssistOptions(tool)` is the long-press entry point: if nothing is open it presents fresh;
  if a panel is already open it **blends** to the new tool via the existing `switchPicker`-style
  cross-fade (generalized), matching how tapping an adjacent exposure setting blends the picker.
- **Anchor + slide:** in `PanelHost`, render `.assist` via a new `bottomAssistBody(tool)` modelled
  on `bottomPickerBody` but mirrored to the **bottom-leading** edge (the assist bar is the left
  bar; the exposure picker is the right bar), keeping the panel's natural width (330, or 472 for
  Guides), sliding up from below using `panelRevealed`, with `panelRevealCurve`.
- **Dismiss:** unchanged `dismissActivePanel()` clears immediately; the outgoing assist panel now
  fades in place (via the removal transition) — same as the picker. Extend `handleBackdropTap`
  ([NativeAppRoot.swift:1586](../../../ios/Runner/NativeAppRoot.swift)) so a tap outside an open
  assist panel dismisses it (and, for full parity, a press on a *different* tool blends to it).

Net effect: **tap toggles the overlay; hold slides the tool's options drawer up — visually and
behaviourally identical to the ISO / shutter / resolution drawers.**

## Affected files

| File | Change |
| --- | --- |
| `Sources/OpenZCineCore/AssistToolActivation.swift` | **New.** Pure on/off reconciliation helper. |
| `ios/Runner/MonitorExperience.swift` | Bar gestures (tap/long-press); measure `assistBarFrame`; toggle haptic. |
| `ios/Runner/MonitorPanels.swift` | `PanelHost.assist` → anchored slide-up `bottomAssistBody`. |
| `ios/Runner/NativeAppRoot.swift` | Generalize reveal (renames, `managesOwnAppearance`, `showAssist`, `presentAssistOptions`, `assistBarFrame`, `handleBackdropTap`); `toggleAssist`/`setAssist` delegate to core helper. |
| `Tests/OpenZCineCoreTests/AssistToolActivationTests.swift` | **New.** Swift Testing coverage. |

## Testing

- **Core (Swift Testing, `Tests/OpenZCineCoreTests/`)** — mirror
  [OperatorPreferencesTests.swift](../../../Tests/OpenZCineCoreTests/OperatorPreferencesTests.swift):
  - Toggling a plain tool (e.g. `.peaking`) flips its `visibleAssistTools` membership.
  - Toggling `.level` / `.desqueeze` on sets both membership **and** the config `enabled` flag;
    toggling off clears both (the reconciliation invariant).
  - `set(_,visible:)` is idempotent and matches `toggle` parity.
- **Shell** — the SwiftUI gestures, slide animation, anchoring, and dismiss are verified in the
  simulator (the `ios/RunnerTests` target is an XCTest stub; no model harness exists yet, so Phase
  1 keeps shell verification manual rather than standing one up). Manual checklist:
  - Tap each tool → overlay toggles, no panel.
  - Long-press a configurable tool → options slide up anchored to the bar; long-press a
    non-configurable tool → nothing.
  - Tap Level / Desqueeze → overlay actually appears/disappears.
  - Assist panel motion matches the exposure picker (slide-up in, fade-in-place out); tap-off
    dismisses.
- `just native-check` passes.

## Risks & edge cases

- **Gesture precedence** inside a horizontal `ScrollView` (tap vs long-press vs scroll) — primary
  implementation risk; fall back to an explicit composed gesture if needed.
- **Reduce Motion** — honour existing app conventions (the picker reveal is not currently
  special-cased; match it).
- **Bar hidden while a panel is open** (`assistToolbarVisible` toggled off) — dismiss gracefully.
- **Rename churn** — `pickerRevealed`/`schedulePickerReveal` are referenced in several places;
  the rename must update every call site (see list above) and stay behavior-preserving for pickers.

## Acceptance criteria

- [ ] Single tap on any assist tool toggles its overlay and opens no panel.
- [ ] Long-press opens options only for `hasConfiguration` tools; no-op otherwise.
- [ ] Tapping Level or Desqueeze reliably shows/hides their overlay.
- [ ] Assist options panels slide up anchored to the assist bar and dismiss by fading in place,
      matching the exposure picker; the old scale/opacity pop is gone.
- [ ] Toggle and panel-open emit haptics, gated by `hapticsEnabled`.
- [ ] New core tests for `AssistToolActivation` pass; `just native-check` is green.
- [ ] No regressions to exposure/resolution pickers (shared reveal still behaves identically).

## Future phases (out of scope here)

Phases 2–5 above. Decisions already locked for later: open conversions are **generated from
published transfer functions** (no proprietary assets committed); RED LUTs are acquired through
RED's real ToC-gated download (never bundled); the LUT button's long-press opens a **compact
drawer with a "Manage…" route to a full-screen LUT library**.
