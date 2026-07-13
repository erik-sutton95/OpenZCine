---
description: Build, diagnose errors with ultrathink, and iterate until green
allowed-tools: Bash(just:*)
---

# Fix Build

Run the iOS build. If there are errors, ultrathink about each one, propose an incremental fix, apply
it, and re-run the build. Repeat until the build is green.

!just ios-build
