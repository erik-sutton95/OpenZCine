# Live-View Top Bar & Popover System Design

**Date:** 2026-06-22
**Status:** Approved (verbal); implementing
**Related specs:** `2026-06-20-production-native-architecture-design.md`,
`2026-06-20-responsive-native-layout-system-design.md`

## Goal

Rebuild the live-view top status bar to match the Penpot wireframe: a single fused glass
pill centered over the feed, where REC and CODEC open reusable "popdown" menus and MEDIA
toggles between capacity and remaining-duration readouts. Establish a reusable directional
glass-popover container and a library of composable content blocks so the many future
monitor menus (WB, FOCUS, DESQUEEZE, GRID, GUIDES, …) share one consistent "liquid glass"
style and interaction.

## Scope

**In scope (this change):**

- `GlassPopover` directional container (drops from top / rises from bottom), real SwiftUI
  material blur, hairline border, dismiss scrim, spring entry/exit, anchor-based positioning.
- Composable block library: `PopoverHeader`, `PopoverTabBar`, `DrumrollWheel`,
  `PopoverToggle`, `PopoverGrid`.
- Two top-bar popdowns: `ResolutionMenu` (REC cell), `CodecMenu` (CODEC cell).
- `TopStatusBar` redesign: fused pill, centered over feed, per-cell tap/anchor targets,
  chevron affordance on interactive cells, MEDIA capacity ↔ duration toggle.
- Compact display formatting for resolution and media in `OpenZCineCore`.

**Out of scope (later, on the same foundation):**

- WB, FOCUS, DESQUEEZE, GRID, GUIDES menus (named as consumers to prove the library
  generalizes; not implemented now).
- Real MTP writes behind menus (`applyPickerValue` stays stubbed).
- Bottom value-strip refactor (keeps existing `PickerPanel`).
- Android shell.

## Architecture

Composition over inheritance. Four layers, each single-purpose:

1. **`GlassPopover<Content>`** — owns style + direction + anchoring + dismissal. Knows
   nothing about cameras, wheels, or tabs.
2. **Composable blocks** — leaf views (`DrumrollWheel`, `PopoverTabBar`, …) that slot inside
   any popover.
3. **Menu content views** — one per menu (`CodecMenu`, `ResolutionMenu`, …). Compose blocks
   into a `GlassPopover`.
4. **Top bar** — fused pill with independent cell anchors; opens popdowns.

```
NativeAppModel
 ├─ activePopover: PopoverKind?        // which menu is open
 └─ popoverAnchor: Anchor<CGRect>?     // source-button rect

MonitorExperience (ZStack)
 ├─ TopStatusBar      (fused pill; per-cell buttons capture anchor + open popover)
 ├─ SideRails, bottom bars
 └─ if activePopover:
      GlassPopover(direction: .down, anchor: popoverAnchor) {
         CodecMenu() / ResolutionMenu() / …
      }
```

## GlassPopover container

- `RoundedRectangle(cornerRadius: 22, style: .continuous)`.
- Background: `.ultraThinMaterial` tinted with `LiveDesign.glass` (real blur, warm tint).
- Border: `LiveDesign.hairline` (cream `0.14` opacity), `lineWidth: 1`.
- Shadow: `.black.opacity(0.40)`, radius 24, y 16 (matches existing `GlassPanel`).
- Inner top sheen: thin clear → white(`0.10`) gradient along the top edge.
- `enum PopoverDirection { case down, up }`. `down` slides from `.top`, `up` from `.bottom`.
- Anchoring via `Anchor<CGRect>` captured from the source button (`.anchorPreference`).
  `.down`: popover top-center aligns to source bottom-center; `.up`: popover bottom-center
  aligns to source top-center. 8pt gap. Lateral clamp keeps it inside the feed frame.
- Dismiss: full-screen clear scrim captures taps (same pattern as existing `PanelHost`).
  Close button, tap-outside, and value selection all set `activePopover = nil`.
- Animation: `.move(edge:)` + `.opacity`, under the existing `.spring(response: 0.34,
  dampingFraction: 0.86)`.

## Composable blocks

| Block | Purpose |
|-------|---------|
| `PopoverHeader(title, subtitle?, onClose)` | Title row + `CloseButton`. Used by every menu. |
| `PopoverTabBar(tabs, selection, onSelect)` | Segmented control (reuses existing styling). |
| `DrumrollWheel(options, selection, onSelect)` | Real iOS `Picker` (`.wheel`), ~5 visible rows, accent-selected, fade + center hairlines. |
| `PopoverToggle(label, isOn, onToggle)` | Label + switch. |
| `PopoverGrid(columns, items, onSelect)` | Button grid (GUIDES-style). |

`Slider` and action-button rows come from SwiftUI / existing components (no wrapper).

## Top bar (A+)

Fused single `GlassPanel`, centered over the feed frame (top-middle), not a hardcoded x.
Each cell is an independent `Button` capturing its own anchor:

- **REC cell** → opens `.down` `ResolutionMenu`.
- **CODEC cell** → opens `.down` `CodecMenu`.
- **MEDIA cell** → tap cycles capacity ↔ duration (no popover).
- **Timecode, FPS** → static.

Interactive cells show a `▾` chevron and accent tint when active. `StatusReadout` gains an
`isInteractive` flag (default false → renders as today).

## Compact text formatting

Per the wireframe, display values stay compact: `6K · 24p`, not `6048 × 3402`; short codec
names; media as `521 GB · 47%` or `47 Min`.

- `MonitorTextFormat.resolutionLabel(pixelWidth:height:frameRate:)` — `(6048, 3402, 23.976)`
  → `"6K · 24p"`. Derives resolution class from pixel width, rounds frame rate to the nearest
  integer with a `p` suffix.
- `MediaStatus` struct — `gigabytesFree`, `percentFree`, `minutesRemaining`; derives
  `capacityLabel` (`"521 GB · 47%"`) and `durationLabel` (`"47 Min"`). Added to
  `CameraDisplayState`; top bar MEDIA cell toggles between the two.

## Testing

- **Unit (Swift `swift test`):** `MonitorTextFormat` resolution label cases (6K/4K/8K,
  fractional frame rates); `MediaStatus` label derivation.
- **Build (`just native-check`):** iOS build + swift-format lint confirm the SwiftUI layer
  compiles and is formatted. SwiftUI view bodies are not unit-tested.

## Files

- `Sources/OpenZCineCore/MonitorTextFormat.swift` — new (compact formatters).
- `Sources/OpenZCineCore/CameraDisplayState.swift` — add `MediaStatus` + field.
- `Tests/OpenZCineCoreTests/MonitorTextFormatTests.swift` — new.
- `ios/Runner/GlassPopover.swift` — new (container + direction + anchor plumbing).
- `ios/Runner/PopoverBlocks.swift` — new (block library).
- `ios/Runner/PopoverMenus.swift` — new (`CodecMenu`, `ResolutionMenu`).
- `ios/Runner/MonitorExperience.swift` — `TopStatusBar` redesign + popover host.
- `ios/Runner/MonitorControls.swift` — `StatusReadout.isInteractive`.
- `ios/Runner/NativeAppRoot.swift` — `PopoverKind`, `activePopover`, `popoverAnchor`, apply methods.
