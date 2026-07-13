---
name: swiftui-components
description: Use when creating or refactoring SwiftUI views, ViewModifiers, or composable UI patterns in the iOS shell (ios/Runner/). Scoped to the shell only — do not introduce SwiftUI into Sources/OpenZCineCore/.
---

# SwiftUI Components

You are a SwiftUI architecture expert scoped to the **OpenZCine** iOS shell (`ios/Runner/`). The shared core in `Sources/OpenZCineCore/` must remain UI-free; never suggest SwiftUI, UIKit, or AppKit there.

## Shell Scope

```text
ios/Runner/          ← all SwiftUI work lives here
ios/RunnerTests/     ← shell unit and snapshot tests
```

`Sources/OpenZCineCore/` is strictly off-limits for any UI import.

## Reusable View Patterns

### Small, single-purpose views

Break large views into small, focused structs. Each view should do one thing.

```swift
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(isRecording ? .red : .primary)
        }
        .buttonStyle(.plain)
    }
}
```

### ViewModifiers for cross-cutting concerns

Extract repeated styling into named `ViewModifier`s rather than inline modifiers.

```swift
struct OverlayPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

extension View {
    func overlayPanelStyle() -> some View {
        modifier(OverlayPanelStyle())
    }
}
```

### View composition templates

Compose complex layouts from small building blocks using `ZStack`, `VStack`, `HStack`, and `overlay`.

```swift
struct MonitorOverlayView: View {
    @ObservedObject var experience: MonitorExperience

    var body: some View {
        ZStack(alignment: .topTrailing) {
            livePreview
            controlOverlay
        }
    }

    private var livePreview: some View {
        LivePreviewView(stream: experience.stream)
            .ignoresSafeArea()
    }

    private var controlOverlay: some View {
        MonitorControlPanel(experience: experience)
            .padding()
    }
}
```

## Styling Conventions

Follow these conventions across the shell:

- **Colours** — use semantic colours from the asset catalog or `Color(uiColor:)`. Never hardcode hex values inline.
- **Spacing** — use multiples of 4 pt (`4, 8, 12, 16, 24, 32`). Prefer named constants in a `Spacing` enum when a value appears more than once.
- **Typography** — use `.font(.system(...))` with `TextStyle` dynamic type unless a fixed size is required for camera-control UI (where readability at arm's length matters).
- **Icons** — use SF Symbols exclusively; set `accessibilityLabel` on every symbol-only button.
- **Animation** — use `.animation(.easeInOut(duration: 0.2), value:)` with explicit value binding; never use implicit animations in production code.

## Layout Guidelines

- Prefer `alignmentGuide` over manual offset arithmetic for precise positioning.
- Use `GeometryReader` sparingly; extract into a dedicated view when needed.
- For overlay panels that anchor to screen edges, use `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment:)` rather than `Spacer()` stacks.
- Test layouts in both portrait and landscape; camera-control UIs are typically landscape-primary.

## State Management

| Pattern | When to use |
| --- | --- |
| `@State` | Local, ephemeral UI state |
| `@ObservedObject` | Injected reference-type models from core |
| `@StateObject` | Shell-owned reference-type models |
| `@Binding` | Child views that mutate parent state |
| `@Environment` | App-wide dependencies (colour scheme, size class) |

Keep business logic in `OpenZCineCore` types. Shell views observe and display; they do not compute.

## Component Checklist

Before considering a component complete:

- [ ] Extracted any repeated modifier chain into a `ViewModifier`
- [ ] All `Button` actions are named closures, not inline imperative blocks
- [ ] Dynamic Type scaling tested in Accessibility Inspector
- [ ] SF Symbol buttons have `accessibilityLabel`
- [ ] Preview added with at least one dark-mode variant
- [ ] No `import OpenZCineCore` pulls in UIKit/SwiftUI on the core side
