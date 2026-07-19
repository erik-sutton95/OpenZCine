# OpenZCine

Open-source iOS + Android app to connect to, control, and monitor (live image) Nikon Z
cinema-line cameras — primarily the **Nikon ZR**. Built openly with agentic coding tools, held to
clean, exemplary engineering standards.

> **Status:** Native iOS and Android implementation milestone. Production work targets the portable
> Swift business/protocol core, a SwiftUI iOS shell, and a Jetpack Compose Android shell. Android is
> not publicly released yet. The older Flutter prototype remains only as a protocol/live-view
> reference while useful.

## Stack & tooling

- **Swift Package Manager / Swift** — production shared business and camera-protocol core.
- **SwiftUI** — production iOS app shell.
- **Jetpack Compose / Kotlin** — production Android app shell and Android platform adapters.
- **Swift SDK for Android** — production bridge path for the shared Swift core. Keep the facade/JNI
  boundary small and verify build, packaging, and runtime behavior through the Android gates.
- **Flutter / Dart** — archived prototype reference only; not part of production tooling.
- **just** — the single entry point for all repository tasks. Run `just` to list recipes.
- **swift-format / swift test / xcodebuild** — production formatting, tests, and iOS build checks.
- **typos, editorconfig-checker, markdownlint-cli2, lychee, actionlint** — repository meta-checks.

Install local tooling with `just setup` (macOS / Homebrew).

## Where things live

- `Sources/OpenZCineCore/` — production Swift shared core.
- `Tests/OpenZCineCoreTests/` — Swift shared-core tests.
- `ios/Runner/` — production SwiftUI iOS app shell.
- `Apps/Android/` — production Jetpack Compose app, platform adapters, and Wear OS companion.
- `reference/flutter-prototype/` — archived Flutter prototype/reference source.
- `vendor/` — **gitignored.** Local-only material; nothing here is committed or required to build.
- `ref/` — **gitignored** local reference material.
- `docs/` — engineering references: `commit-hygiene.md` (what must never be committed),
  `nikon-mtp.md` (protocol sourcing and maintenance policy), `nikon-sdk.md` (no-vendor-SDK policy),
  `PROJECT-MANAGEMENT.md` (Kaneo board conventions + agent sync contract).
- `docs/design/` — design specs, implementation plans, and archived browser prototypes.
- `docs/investigations/` — resolved or pending engineering investigations and debugging records.
- `site/` — deploy-ready GitHub Pages landing page; no raw design sources.
- `.local/` — **gitignored** demo feeds, raw marketing sources, and local tooling migrations.
- `.github/` — CI workflows, issue/PR templates.

## Supported agent tools

OpenZCine supports **Claude Code** and **Codex** only:

- Shared instructions live in `AGENTS.md`; both clients follow them.
- Claude Code configuration lives under tracked `.claude/`, with personal settings ignored.
- Codex uses `AGENTS.md`; personal `.codex/` state is ignored.

Do not add Cursor, Copilot, Gemini, Windsurf, Aider, Cline, Roo, Kilo, Continue, or OpenCode-specific
instructions. Put guidance needed by both supported clients here or in the relevant project docs.

For `docs/flows/` work, read its `README.md` first, pull the live ExcaliDash scene before editing,
use `pushMerged` for incremental changes, and verify afterward. `just flows-push` is reserved for an
intentional whole-scene replacement because it resets the live layout.

## Hard rules

- **Never commit `vendor/`, `ref/`, `captures/`, or `.local/`.** They contain proprietary,
  private, or raw working material. They are gitignored; if a `git add` ever tries to include them,
  fix `.gitignore` — do not force-add.
- **Mind commit hygiene.** This is a public repo; never commit secrets, credentials, PII, or
  non-redistributable assets. Follow `docs/commit-hygiene.md` before every commit.
- **Work on a branch and open a PR.** Do not commit directly to `main`.
- **Conventional Commits** for every commit (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `build:`, `test:`).

## Verification

Before claiming any change is complete, run:

```sh
just check
```

For production Swift/iOS or Swift Android-facade changes, also run:

```sh
just native-check
```

## Project management (Kaneo)

Work is tracked on the OpenZCine Kaneo board (project `OPE`). Keep it in sync as part of normal
work — this is a standing contract, not a request-driven step:

- **Start** a deliverable → set its task to **in-progress**.
- **Open/update its PR** → move it to **in-review** through review, even after local Verification.
- **Finish** it → set it to **done** only after merge and successful default-branch CI.
- **Abandon** it → move it to **archived** explicitly; never infer cancellation from a closed PR.
- **New scope** → create a task (backlog ideas go to **planned** with the `investigation` label);
  add real deliverables to `docs/ROADMAP.md`.
- Roadmap = scope source of truth; Kaneo = live status mirror. Move them together.

Board identity, statuses, the GitHub issue sync behavior, and which MCP tools work on this
self-hosted instance are in `docs/PROJECT-MANAGEMENT.md`. Read it before touching the board.

## Coding principles

- **Composition over inheritance.** Prefer small, pure functions and immutable data over stateful
  classes. Use records / small classes for structured data.
- **Short, single-purpose functions.** If a function grows past ~20 statements or 3 levels of nesting,
  extract helpers and use early returns.
- **Throw, don't return null, for errors.** Raise descriptive exceptions rather than signalling failure
  with `null`.
- **Type everything public.** All public Swift/Kotlin function signatures carry explicit types. Avoid
  dynamic or loosely typed boundaries.
- **Doc comments on the public API.** Use platform-native doc comments on exported members.
- **Keep shared Swift portable.** The shared core must not depend on SwiftUI, UIKit, Android APIs, or
  Compose. Platform adapters own sockets, permissions, lifecycle, rendering, storage, and UI.

## Build and test commands

`just` is the single entry point for all repository tasks. Run `just` with no arguments to list
every recipe. Common commands:

```sh
just setup          # Install local tooling (macOS / Homebrew)
just check          # Run all repo-level checks (lint, format, CI meta)
just native-check   # Run Swift checks — format, build, and tests
just ios-build      # Build the iOS app shell
just watch-build    # Build the watchOS companion app
just test           # Run Swift package tests
just android-build  # Build the Android phone app and staged Swift runtime
just android-check  # Build, test, compile instrumentation tests, and lint Android
just android-release-check # Verify the signed phone/Wear release pair and runtime closure
```

**Before claiming any change is complete**, run `just native-check` for Swift/iOS or facade work,
`just android-check` for Android work, and `just check` for repo-wide changes.

Interactive Xcode/simulator helpers (builds, launching the simulator, screenshots, device logs)
are fine for iteration on the `ios/Runner` shell, but they never replace `just` — CI and official
verification always go through `just`.

## Project structure

The canonical layer names map to this repository as follows:

| Layer | This repo | Purpose |
| ----- | --------- | ------- |
| App | `ios/Runner` | SwiftUI app entry point, scene/lifecycle |
| Features | `ios/Runner` | Feature views, view models, coordinators |
| Resources | `ios/Runner` | Assets, localisation strings, Info.plist |
| Watch | `ios/OpenZCineWatch` | watchOS companion app (embedded in Runner) |
| Core | `Sources/OpenZCineCore` | Portable camera protocol and business logic |
| Android facade | `Sources/OpenZCineAndroidFacade` | Swift session/JNI boundary for Android |
| Android app | `Apps/Android/app` | Compose phone shell and Android adapters |
| Android API | `Apps/Android/core-api` | Kotlin interface shared by shell and adapters |
| Wear | `Apps/Android/wear`, `Apps/Android/wear-relay` | Wear OS UI and phone relay contract |
| Android tests | `Apps/Android/*/src/test`, `Apps/Android/*/src/androidTest` | JVM and device UI tests |

Tests for the shared core live in `Tests/OpenZCineCoreTests/`.

## Coding standards

### Shared core (`Sources/OpenZCineCore`)

The core must stay **UI-free and portable** — it must not import SwiftUI, UIKit, AppKit, or any
Android/Compose framework. Platform adapters own sockets, permissions, lifecycle, rendering,
storage, and all UI. Keep the interop boundary small.

- Swift 6.0 strict concurrency applies to all new core code.
- Prefer value types (structs, enums) over classes.
- Errors must use typed `LocalizedError` conformances — never raw strings.
- No force-unwrapping without a documented `// SAFETY:` justification comment.

### iOS shell (`ios/Runner`, `ios/OpenZCineWatch`)

The shells follow modern SwiftUI idioms exclusively:

- **`@Observable`** and **`@Bindable`** for state — `ObservableObject` / `@Published` are
  deprecated for new code.
- **`NavigationStack`** for navigation — `NavigationView` is deprecated for new code.
- **`async/await`** for all asynchronous work; no Combine for new code.
- **Typed `LocalizedError`** for user-facing error presentation.
- **Swift Testing** (`import Testing`) for all new unit tests.
- Swift 6.0 strict concurrency: annotate actors, isolate state correctly, no data races.

### Deploy + screenshot-verify every UI change (MANDATORY — no exceptions)

Any SwiftUI or Compose **visual** change (layout, chrome, glass, colors, typography, spacing) is
**not done** until it has been **installed and launched** on a connected target — not merely
compiled. A successful `assembleDebug` / `xcodebuild` without install is insufficient.

**Deploy targets (use what is plugged/booted):**

| Platform | Install / launch |
| -------- | ---------------- |
| Android phone | `just android-install <serial>` then start the activity (demo extras if useful) |
| iOS simulator | Build+run on the booted sim (XcodeBuildMCP `build_run_sim` or project `just`/`xcodebuild` flow) |
| iOS device | Build+run on the connected device when that is the review target |

**Orientation (critical):** OpenZCine is a **landscape-first camera monitor**. Always verify
visual and interaction work in **landscape** first (and as the default for Android device
screenshots). Portrait is secondary. Never sign off a UI change from portrait-only testing.

After install: capture a screenshot → inspect **all four edges** and confirm every interface
element is fully visible. The iOS app is **landscape-locked and only ~400pt tall**, so rotate its
raw simulator shot to read it.

- **Bottom:** nothing flush against or past the bottom edge. Leave clearance for the iOS home
  indicator and Android gesture/navigation insets.
- **Right/left:** content fills the intended width; no unintended empty band at an edge, and no
  element pushed off the side.
- **Truncation/overflow:** no `…` truncation, no text wrapping mid-word into a vertical sliver, no
  card taller than its container.

If ANY element clips, overflows, or truncates: fix it, **redeploy**, and re-screenshot until the
frame is clean. **Never report a UI change as complete or "matches the mockup" without this
pass.** Prefer the real device size and, when a screen has multiple states, screenshot the
tightest one. Glass / material / edge-highlight tuning counts as a UI change — always redeploy.

## Testing requirements

- **View models** must have unit tests covering their core logic.
- **Critical user flows** (camera connection, record start/stop, live-view activation) must have
  UI-level integration tests.
- **Business logic coverage**: 80% or higher line coverage for `Sources/OpenZCineCore`.
- Use **Swift Testing** (`#expect`, `#require`) for new Swift tests and the existing Kotlin/JUnit
  conventions for Android tests. XCTest is acceptable only in existing targets not yet migrated.

## Parallelize independent work

Favor speed: when a task splits into **independent** units, dispatch subagents **in
a single message** so they run concurrently — a serial pass over N independent items is needlessly
N× slower. Before any multi-step task, ask *"which parts are independent?"* and fan those out.

- **Fan out** for: codebase exploration/search across many files; independent edits (a batch of
  review findings, the same change across many call sites, separate features — one agent each);
  multi-angle review (correctness / security / tests at once); independent research questions.
  Use the active client's subagent support when parallel work materially helps.
- **Stay in the main thread** for: tight `edit → build → verify → adjust` loops (e.g. simulator
  screenshot tuning); work with shared state or sequential dependencies; trivial tasks where
  dispatch overhead exceeds the work.

Give each subagent a **self-contained prompt** — it can't see the conversation, so include the file
paths, the exact change, and how to verify — and have it return the conclusion, not a file dump.

Use the active client's built-in subagents only. Do not shell out to external model CLIs. Keep model
or effort selection inside Claude Code or Codex, and verify delegated work with the same repository
gates as local work.

## Feature-branch worktrees

When dispatching agent work that makes code changes while on a feature branch, give it an isolated
git worktree — don't let it edit the shared checkout directly.

- **Verify in the worktree** with `just native-check` (or the project's known-good fallback if a
  phase is environmentally broken) before merging anything back — never merge unverified work.
- **Merge back** with a local `git merge` into the current feature branch once verified. A GitHub PR
  is reserved for feature-branch → `main` only.
- **Clean up** the worktree and delete its branch after a successful merge.

This keeps the main feature-branch checkout free for parallel work, folded in once ready.

## General preferences

- If asked to do too much work at once, stop and state that clearly.
- A UI scaffold without wired backend behavior is not "done" — see completion metrics.

## DO NOT

Repo-hygiene rules (never touch `vendor/`/`ref/`, never commit secrets/PII, never commit to `main`,
Conventional Commits) are in [Hard rules](#hard-rules). In addition:

- **No force-unwrapping** without a `// SAFETY:` comment explaining why the unwrap is guaranteed.
- **Do not use deprecated APIs** in new code: `NavigationView`, `ObservableObject`, `@Published`,
  and Combine-based data flow are off-limits for new SwiftUI code.
- **Do not bypass `just`** for official verification — never invoke `xcodebuild` or `swift test`
  directly in place of the canonical `just native-check` / `just check`.

## Completion metrics

A task is complete when all of the following are true:

- Acceptance criteria from the task brief are checked off.
- `just native-check` passes (or `just check` for non-Swift changes).
- New or modified behaviour is covered by passing tests.
- Public APIs carry doc comments.
- Relevant docs under `docs/` are updated if behaviour changed.
