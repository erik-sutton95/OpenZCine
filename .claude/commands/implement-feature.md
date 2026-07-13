---
description: Read a spec file, plan, and implement the feature incrementally
argument-hint: <spec-path>
allowed-tools: Bash(just:*)
---

# Implement Feature

Read the spec at `$ARGUMENTS`, then implement the described feature incrementally.

Steps:

1. Read `$ARGUMENTS` in full and extract the requirements
2. Identify which files need to change — note whether changes belong in the shared core (`Sources/OpenZCineCore`) or the iOS shell (`ios/Runner`)
3. Plan the implementation as a numbered task list before touching any code
4. Implement each task one at a time; commit logical units when natural
5. After each meaningful change, run `just native-check` and fix any failures before continuing
