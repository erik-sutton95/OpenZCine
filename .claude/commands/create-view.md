---
description: Scaffold a SwiftUI view + ViewModel + Preview + test stub in ios/Runner
argument-hint: <ViewName>
---

# Create View

Scaffold a new SwiftUI view in the iOS shell (`ios/Runner`). Do not create files in
`Sources/OpenZCineCore` — the shell only.

For the view named `$ARGUMENTS`, create the following files under `ios/Runner/`:

- `$ARGUMENTSView.swift` — a SwiftUI `View` struct that receives a `$ARGUMENTSViewModel` as a
  parameter and renders placeholder UI
- `$ARGUMENTSViewModel.swift` — an `@Observable` class with sensible initial state properties and
  any async methods needed
- A `#Preview` macro block at the bottom of `$ARGUMENTSView.swift` that instantiates the view with
  a default `$ARGUMENTSViewModel`
- `$ARGUMENTSViewTests.swift` under `ios/RunnerTests/` (iOS shell view test target) — a Swift Testing
  stub with one placeholder `@Test` function

Follow existing naming and formatting conventions in `ios/Runner`. Do not bypass `just` for any
build verification — if you want to verify the scaffold compiles, use `just ios-build`.
