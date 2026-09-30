---
title: Setup and build
description: Install tooling, open the iOS project, run the demo session without a camera, build Android, and run the quality gate.
---

`just` is the single entry point. From a clone:

```bash
just setup    # macOS / Homebrew: meta-check tools
just check    # hygiene, spelling, markdown, links, secrets, Swift lint and tests
```

Run `just` with no arguments to list recipes. The shared protocol core is tested
without a camera (`just test` / `swift test`). Discovery, pairing and live view
need a **physical** phone or tablet and a supported Nikon Z body; the Nikon ZR is
the primary target ([device references](../../devices/)).

## iOS

Open `ios/Runner.xcodeproj` in Xcode, select a physical iPhone or iPad, and set
your Team under Signing. The Simulator cannot reach a camera, but it can run the
whole monitor without one.

### Run without a camera

Edit the `Runner` scheme and add the environment variable
`ZC_DEMO_AUTOSTART=1`. The app boots straight into a demo live-view session with
synthetic frames, camera values and AF boxes, so the monitor UI, assists and
pickers can be exercised end to end. Camera-protocol changes in
`Sources/OpenZCineCore/` are covered by package tests that also run without
hardware.

Native gate:

```bash
just native-check   # demo isolation, Swift lint and tests, iOS tests, iOS and watchOS builds
```

The Apple Watch companion builds as part of that gate (`just watch-build`).
More: [iOS app](../../apps/ios/).

## Android

Needs Android Studio or Gradle with a JDK (CI uses Temurin 21), plus the Swift SDK for
Android that CI uses (Swift **6.3.3**, NDK 27, API level 29). From the repo root:

```bash
just android-build          # build the Android app and the staged Swift runtime
just android-check          # shader check, build, unit tests, device-test compile and lint
just android-release-check  # verify the signed phone and Wear release pair
```

With a phone attached, `just android-install` builds, installs and launches the
debug build (`just android-install <serial>` picks one of several
devices). The phone app and the Wear OS companion live under `Apps/Android/`; the
shared Swift core reaches Kotlin through `Sources/OpenZCineAndroidFacade/`.
Details: [`Apps/Android/README.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/Apps/Android/README.md)
and [Android app](../../apps/android/).

CI builds Android on Ubuntu with the same toolchain pin and runs
`assembleDebug`, the device-test compile, `test`, `lint` and the release
artifact checks for both the phone app and the Wear bundle.

## This handbook

```bash
cd handbook
npm ci
npm run dev    # http://localhost:4321/
```

Production build, with the base path opencapture.org serves it under:

```bash
HANDBOOK_BASE=/openzcine/docs npm run build
```

CI builds the handbook whenever `handbook/` changes, and a merge to `main` that
touches `handbook/` redeploys
[opencapture.org/openzcine/docs](https://opencapture.org/openzcine/docs/).
See [Keeping docs current](../../contribute/documentation/).

## Frame.io (optional)

Frame.io upload is disabled in builds that are not configured; the app shows
that the feature is unavailable instead of failing. To enable it in your own
builds, register an Adobe OAuth Native App credential and copy its values into a
gitignored local config. Full steps:
[`docs/frameio-setup.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/frameio-setup.md).
No keys are committed. The feature needs iOS 17.4 or newer.

## Hygiene

Secrets, camera Wi-Fi keys, packet captures, vendor material and
non-redistributable LUTs stay out of git. `just hygiene` and `just secrets`
(gitleaks) run inside `just check` and CI.
[`docs/commit-hygiene.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/commit-hygiene.md)
is the gate. GitHub workflow (branches, Conventional Commits, tester notes,
issues vs discussions) lives in
[`CONTRIBUTING.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/CONTRIBUTING.md).
