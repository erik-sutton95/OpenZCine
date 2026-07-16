# Contributing to OpenZCine

Thanks for your interest! This project aims to be a clean, welcoming example of open-source mobile
engineering. By participating you agree to our [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting set up

1. Install [`just`](https://github.com/casey/just), Xcode, and the Swift toolchain. Android
  contributors will also need Android Studio/Gradle once the Jetpack Compose shell exists.
2. Install the meta-check tools: `just setup` (macOS / Homebrew).
3. Run `just check` to confirm a green baseline.

No vendor SDK is included or required — the camera protocol comes from public sources (see
[`docs/nikon-sdk.md`](docs/nikon-sdk.md)). **Never commit anything under `vendor/` or `ref/`.**

### Running the app without a camera

You don't need a Nikon ZR to work on most of the app. Open `ios/Runner.xcodeproj`, edit the
`Runner` scheme, and add the environment variable `ZC_DEMO_AUTOSTART=1` — the simulator will boot
straight into a demo live-view session with synthetic frames, camera values, and AF boxes, so you
can exercise the monitor UI, assists, and pickers end-to-end. Camera-protocol changes
(`Sources/OpenZCineCore/`) are covered by package tests (`just test`) that run without hardware.

## Optional integrations (bring-your-own keys)

Some features depend on third-party services you register yourself. They are **disabled in builds that
aren't configured** — the app shows "Feature unavailable" rather than failing — and **no keys are ever
committed to this repo**.

- **Frame.io upload** — to enable it in your builds, register an Adobe **OAuth Native App** credential
  (Frame.io API on the project) and copy the client ID + redirect URI into a gitignored local config;
  full steps are in [`docs/frameio-setup.md`](docs/frameio-setup.md). The feature requires iOS 17.4+.

## Workflow

- Branch off `main` (e.g. `feat/live-view`, `fix/usb-reconnect`, `chore/...`).
- Make focused commits using **[Conventional Commits](https://www.conventionalcommits.org/)**:
  `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `build:`, `test:`, `refactor:`.
- Run `just check` before pushing. For native production changes to Swift/iOS code, run
  `just native-check`.
- Open a pull request into `main`. CI must pass and the PR template must be filled in.
- When native iOS changes merge to `main`, CI uploads a TestFlight build automatically (maintainers
  only — see [`docs/testflight-ci.md`](docs/testflight-ci.md)).
- Any PR that can trigger a TestFlight build must replace
  [`ios/TestFlight/WhatToTest.en-US.txt`](ios/TestFlight/WhatToTest.en-US.txt) with concise copy for
  non-developer camera operators. Describe visible outcomes, exclude implementation details, and
  give concrete steps under **Please test**. CI rejects stale or developer-centric notes.

## Code standards

- The production target is a shared Swift business/protocol core with native UI shells: SwiftUI on
  iOS and Jetpack Compose on Android. The archived Flutter/Dart prototype under
  `reference/flutter-prototype/` is reference material only.
- Composition over inheritance; prefer small pure functions and immutable data.
- Keep functions short (~20 statements) and nesting shallow (≤3 levels) — extract helpers, use early returns.
- Throw descriptive exceptions for errors; don't return `null` to signal failure.
- Explicit types on all public signatures; avoid dynamic or loosely typed boundaries.
- Use platform-native doc comments on public API members.
- Keep the shared Swift core portable: no SwiftUI, UIKit, Android, Compose, or filesystem/UI
  dependencies in protocol/business logic. Platform adapters own sockets, permissions, lifecycle,
  rendering, storage, and UI.

## Reporting bugs & requesting features

- **Bugs only** — In **Operator Setup &gt; System &gt; Report a Problem**, choose one of two public
  GitHub-issue paths:
  - **Anonymous in-app report** — A minimal report with no GitHub account. It cannot include
    attachments or receive a private reply.
  - **Signed-in GitHub issue** — Open [GitHub's issue chooser](https://github.com/erik-sutton95/OpenZCine/issues/new/choose)
    for richer optional details and attachments. A GitHub account is required.
  New bugs are automatically labeled `needs-triage`; issues are strictly for bugs. Never put
  sensitive information in either public path.
- **Feature ideas, enhancements & discussions** — Use **GitHub Discussions** (the "Discussions" tab). Start a new discussion in the **Ideas** category. A GitHub account is required, which keeps feature conversations attributable and Issues focused on actionable bugs.
- **Security vulnerabilities** — Follow [`SECURITY.md`](SECURITY.md). Do **not** open a public issue.

## Labels & triage

We use labels to organize work. Key categories include:

- **Type**: `bug`, `enhancement`, `documentation`, `question`, `chore`
- **Priority**: `P0` (critical), `P1`, `P2`
- **Community**: `good first issue`, `help wanted`
- **Triage**: `needs-triage`, `needs-info`
- **Area**: `area:core`, `area:protocol`, `area:ios`, `area:live-view`, `area:monitoring`, `area:control`, `area:media`, `area:ui`, `area:watch`, `area:docs`, etc.

A full list with descriptions lives in [`.github/labels.yml`](.github/labels.yml).

Maintainers triage new issues (usually applying area + priority labels). Feel free to suggest labels when you open an issue.

See the full set of labels in the repository's **Labels** page (under Issues).
