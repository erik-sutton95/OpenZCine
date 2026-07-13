---
description: Produce a detailed implementation plan for a feature in plan mode
---

# Plan Feature

Enter plan mode and produce a detailed implementation plan for the feature described in this
conversation (or referenced spec file).

Use deep reasoning to work through:

- Architectural fit — how the feature maps onto the shared core (`Sources/OpenZCineCore`) vs the iOS
  shell (`ios/Runner`)
- Data model and state design
- Implementation sequence — ordered steps with dependency notes
- Risk areas and mitigations
- Testing strategy — unit tests for core logic, UI tests for shell behaviour

Output the plan as a numbered step-by-step breakdown. Do not write any code — this is a planning
pass only.
