---
name: update-readme-roadmap
description: >
  Update the README roadmap status table after completing implementation work.
  Run whenever a PR or feature branch lands work that touches a roadmap area
  (connectivity, live view, camera control, monitoring assists, framing tools,
  multicam & export). Also invoke before finishing a development branch or
  requesting code review, to ensure the README stays in sync with reality.
---

# Update README Roadmap

Keep `README.md` roadmap status table accurate after every meaningful implementation change.

## When to run

- After completing work on a roadmap area (new feature, bug fix, architectural improvement).
- Before finishing a development branch (as part of branch completion).
- Before requesting code review.
- When prompted by the user to update the roadmap.

## How to update

1. **Read the current roadmap table** in `README.md` (the `## Roadmap` section).
2. **Assess what changed** by reviewing the diff, implemented files, and test coverage for the
    completed work.
3. **Adjust the Status column** for each affected capability:
    - ✅ shipped — feature is implemented, tested, and working end-to-end.
    - ◑ in progress — core functionality exists but is incomplete or unverified on hardware.
    - ○ planned — not yet implemented.
4. **Add or remove rows** as capabilities are broken out, merged, or discovered.
5. **Keep the table ordered** from most-complete to least-complete within each logical group.

## Status guidelines

Use your judgment based on what's actually implemented and tested:

| Status | Meaning |
| --- | --- |
| ✅ shipped | Fully implemented with tests. Works on-device or is verified against protocol captures. |
| ◑ in progress | Core logic or UI exists; may have gaps in edge cases, hardware verification, or coverage. |
| ○ planned | Nothing implemented yet — scaffolding, types, or design docs only do not count as in progress. |

## Anti-patterns

- **Don't inflate.** A UI scaffold without wired backend behavior stays ○ planned.
- **Don't deflate.** Tested end-to-end behavior that handles the main path earns ✅ shipped.
- **Don't skip.** Even bumping one row from ○ to ◑ signals progress. Precision matters less than honesty.
- **Don't over-split.** One row per coherent capability. If two items are always implemented together, merge them.
