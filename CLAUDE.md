# OpenZCine Claude Code guide

## Canonical project guidance

```text
@import AGENTS.md
@import docs/ARCHITECTURE.md
@import docs/PRD.md
```

`AGENTS.md` is the single source of truth for architecture, coding standards, repository hygiene,
verification, UI screenshot requirements, and subagent coordination. Keep shared guidance there
instead of duplicating it in this client-specific file.

**UI / chrome / glass tweaks:** always `just android-install` (connected phone) and/or build-run
on the booted iOS simulator or connected iPhone after the change — compile-only is not done. See
`AGENTS.md` → "Deploy + screenshot-verify every UI change".

**Landscape-first:** the app is primarily used in landscape. Always open pickers, drums, and
chrome in **landscape** when verifying on Android; portrait-only checks are not enough.

## Claude Code workspace

- Team commands, agents, hooks, skills, and settings live under `.claude/` and are tracked.
- Personal settings, logs, worktrees, and preserved-edit scratch files are ignored.
- XcodeBuildMCP is an interactive helper for builds, simulator control, screenshots, and logs. It
  never replaces the canonical `just check` or `just native-check` verification gates.
- `.claude/settings.json` creates feature-task worktrees from the current branch. Agent changes must
  be verified in their isolated worktree, merged locally into the feature branch, and cleaned up
  afterward, as described in `AGENTS.md`.
- **Opening or updating a PR always includes moving its Kaneo task to `in-review` in the same
  step** (and to `done` only after merge + green default-branch CI). Never leave the board behind
  the PR state — full contract in `AGENTS.md` → "Project management (Kaneo)".
