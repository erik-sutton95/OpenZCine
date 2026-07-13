---
description: Extract subviews from a large SwiftUI view body in ios/Runner
argument-hint: <ViewName or file path>
---

# Refactor View

Refactor a SwiftUI view in the iOS shell (`ios/Runner`). Do not touch `Sources/OpenZCineCore`.

- Identify any `View` whose `body` exceeds approximately 50 lines
- Extract logical sections into private subviews or helper `View` types within the same file (or a
  new file in `ios/Runner/` if it improves clarity)
- Preserve all existing behaviour and visual output — this is a structural refactor only
- After refactoring, confirm the build still passes by running `just ios-build`
