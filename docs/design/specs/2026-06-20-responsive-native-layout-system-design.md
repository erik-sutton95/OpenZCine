# Responsive Native Layout System Design

**Date:** 2026-06-20
**Status:** Drafted from startup layout regression review
**Related specs:** `2026-06-20-wireframe-kit-app-design.md`,
`2026-06-20-production-native-architecture-design.md`

## Goal

OpenZCine should behave like a native camera monitor on every supported iPhone and iPad
size, not like a fixed Penpot board squeezed into the screen. The UI must preserve the wireframe's
operator intent while using standard responsive layout rules: safe-area-aware containers, adaptive
breakpoints, flexible columns, predictable minimum sizes, and scroll only when content genuinely
cannot fit.

The immediate target is the iOS startup, pairing, saved-camera, and camera-ready flow. The same
layout system should then carry into live view, settings, and Android.

## Problem Statement

Recent startup work matched the Penpot composition too literally. Several views used fixed column
widths and fixed inter-column spacing derived from a landscape mockup. That made the screen look
close on one reference size but fragile on real devices with different landscape widths, Dynamic
Island/notch cutouts, bottom safe areas, and future iPad split widths.

The current scale-to-fit guardrail prevents the worst clipping, but it is not the final model. A
production app should reflow and rebalance content before it resorts to global scaling.

## Design Principles

- **Safe areas are layout inputs.** Full-bleed backgrounds may ignore safe areas; interactive chrome
  and text may not.
- **Penpot defines intent, not fixed geometry.** Use Penpot for hierarchy, spacing rhythm, visual
  weight, and state coverage. Do not require exact board widths to make a native layout valid.
- **Prefer reflow before scaling.** Columns should flex, compress spacing, wrap, or stack before the
  whole surface is scaled down.
- **Stable controls beat decorative fidelity.** Buttons, rows, tabs, and cards must keep readable
  text, hit targets, and visible affordances at all supported sizes.
- **Scroll is scoped.** A screen may scroll vertically in compact cases, but headers, status pills,
  and primary actions should not become unreachable through accidental horizontal overflow.
- **Layout rules are testable.** Breakpoint and sizing decisions should live in small pure policies
  under `OpenZCineCore` where possible, with tests covering real device classes.

## Layout Profiles

The native shells should classify each viewport into a small number of semantic profiles. Exact
thresholds can evolve with device testing, but the model should be stable.

| Profile | Typical shape | Behavior |
| --- | --- | --- |
| Compact portrait | Narrow phones, or future portrait support if orientation lock changes | Single column, vertical scroll, primary actions full width. |
| Compact landscape | Small landscape phones or large safe-area intrusion | Single column or tight two-column with reduced secondary art. |
| Regular landscape phone | Primary locked-landscape iPhone target | Two columns for startup; monitor chrome around full-bleed feed. |
| Wide landscape | Large phones, iPad full screen, external displays | Two columns with max widths and centered content; do not stretch controls endlessly. |

The app is currently locked to landscape, but the layout system should still avoid assuming one
exact landscape size.

## Startup Flow Layout

Startup surfaces share the same responsive shell:

- Full-bleed background.
- Safe-area-aware content container.
- Header row with app title on the leading side and status pill on the trailing side.
- Content region that can be either two-column or single-column.
- Optional footer links only when space allows without crowding primary actions.

In regular landscape, the intro/illustration column and action/list column should use flexible
widths:

- intro column: min readable width, preferred visual width, max cap;
- action column: min row/button width, preferred card/list width, max cap;
- spacing: a range, not a fixed constant;
- if the combined minimums do not fit, switch to compact layout rather than clipping.

The discovery scope is decorative-supporting content. It can shrink, reduce labels, or hide footer
links before any primary camera card or `Pair camera` action is compromised.

## Live View Layout

Live view has a different responsive rule than startup:

- The camera feed remains full-bleed and may extend behind safe areas.
- Touch chrome is inset by safe-area-aware monitor chrome margins.
- Rails, record controls, status bars, assist toolbar, and camera-value strip use fixed hit-target
  minimums plus adaptive overflow.
- If horizontal space is tight, lower-priority assist tools move into `More`; they do not squeeze
  primary record/status controls.
- The bottom camera-value strip can compact labels before hiding values. If it still cannot fit,
  lower-priority values move into an overflow panel.

This keeps the monitor useful on real hardware while preserving the visual language of the Penpot
boards.

## Settings And Panels

Settings, picker panels, and assist panels should use platform-native adaptive containers:

- constrained max widths on wide displays;
- vertical scroll inside the panel body only;
- sticky or always-visible close/confirm affordances where appropriate;
- row and card min heights that satisfy touch targets;
- no nested decorative card shells.

Picker panels should prioritize current value, available choices, and dismissal. Long enum lists
should scroll inside the panel rather than growing past the viewport.

## Implementation Boundary

Pure layout decisions should live in `OpenZCineCore` when they can be represented as simple policies:

- profile classification;
- safe-area-adjusted margins;
- startup column sizing;
- monitor chrome insets;
- overflow thresholds for toolbars and value strips.

SwiftUI should consume those policies and render adaptive views. Android Compose should consume the
same policy names and thresholds when Android UI work begins, either directly from the Swift core or
through mirrored tests if bridge work is not ready.

## Testing

Responsive behavior needs regression coverage at three levels:

- Core tests for profile classification, column sizing, and no-overflow invariants.
- SwiftUI build checks for the iOS target after layout changes.
- Visual device checks on representative landscape sizes before claiming a screen is polished:
  small notched phone, regular Pro phone, large Pro Max, and iPad/full-width.

The minimum automated invariant is: primary content width must be less than or equal to the safe
content width for every supported landscape profile.

## Migration Plan

1. Replace the startup screen's fixed Penpot-width HStacks with an adaptive two-column container.
2. Add pure tests for startup profile classification and column sizing across real iPhone landscape
   dimensions.
3. Apply the same responsive profile model to saved cameras and camera-ready views.
4. Refactor live-view chrome to use priority-based overflow for assist tools and camera values.
5. Revisit settings and picker panels with the same container rules.

## Non-Goals

- Pixel-perfect matching at the expense of safe-area correctness.
- Supporting every possible iPad multitasking width in the first pass.
- Building Android UI parity before the iOS responsive foundation is stable.
