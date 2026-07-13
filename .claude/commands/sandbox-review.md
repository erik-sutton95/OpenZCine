---
description: Read-only codebase architecture review
allowed-tools: Read, Glob, Grep
---

# Sandbox Review

Perform a read-only architecture review of this codebase. Do not write or modify any files.

- Explore the directory structure and key source files
- Identify the main architectural layers: shared core (`Sources/OpenZCineCore`) and iOS shell
  (`ios/Runner`)
- Note responsibilities, boundaries, and data-flow between layers
- Highlight any concerns: tight coupling, missing abstractions, or areas for improvement
- Summarise findings as a structured report
