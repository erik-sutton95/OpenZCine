# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Playback and live **desqueeze**: scales the picture (not only guides), with 1.6× and custom
  1.00–2.00× (0.01 steps) on iOS and Android.
- **Auto ISO** for non-R3D movie codecs (N-RAW / ProRes / H.26x): Auto On/Off controls movie ISO
  auto (not P/A/S/M). Live working ISO while Auto is on (e.g. A51200); manual / Auto Off only in
  exposure mode **M**. R3D NE keeps Low/High dual-base and stays manual in every exposure mode.
- USB-C tethered transport (iOS, via ImageCaptureCore): USB camera discovery, connection,
  auto-reconnect on plug-in, and a transport-aware first-pair wizard with real USB-C setup steps.
  Wi-Fi (PTP-IP) and USB-C now share one session layer behind a transaction-level
  `CameraTransport` boundary. Hardware verification on the ZR is pending.
- Third-party license notices (`THIRD-PARTY-NOTICES.md`) and an app privacy policy page
  (`site/privacy/`).
- Contributor guide for running the app without camera hardware (demo session).
- TestFlight CI: automated upload on merge to `main`, centralized iOS versioning, and maintainer setup
  docs (`docs/testflight-ci.md`).
- Repository foundation: governance docs, tooling (`just`, meta-checks), native CI, and agent
  configuration.

### Changed

- Google Play **internal** uploads automate like TestFlight: merge Android-relevant paths to `main`
  builds and uploads phone + Wear AABs when `PLAY_UPLOAD_ENABLED=true` (see
  `docs/android-distribution.md`). Manual dispatch and `android-v*` tags remain.
- Android control writes: facade owns encode + native confirm; shell no longer soft-fails after a
  successful apply (see `docs/android-control-writes.md`).
- TestFlight notes are now reviewed, tester-written copy with concrete test steps. CI rejects stale
  notes, commit titles, and common implementation jargon before an iOS build can ship.

### Security

- All GitHub Actions in CI are pinned to full commit SHAs, and Docker-based actions to image
  digests, to prevent tag-hijack supply-chain attacks.
