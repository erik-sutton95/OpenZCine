# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Photography (stills) mode** (iOS + Android): dedicated stills chrome with a real shutter
  (hold-to-burst in continuous drives, tap-to-AF, bulb/time), built-in and app self-timers, and
  capture-bar pickers for mode (incl. U1–U3), ISO Auto, focus mode/area/subject, drive, white
  balance, size, quality (RAW + JPEG/HEIF), and picture profile (incl. downloaded cloud profiles).
  Portrait photography layout, an EV meter fed by the body's exposure indicator, and photo-mode
  scopes/false color that read the stills preview (sRGB or HLG).
- **Focus dial**: on-feed manual focus-by-wire pull in photo mode — a relative near↔infinity drum,
  toggled in the FOCUS popup, decoupled from the command tick so it tracks the finger. The release
  preserves the dialed focus (no re-AF) on iOS; the Android mirror is pending.
- **Burst series**: continuous-drive frames group into one stack that opens to a full-screen
  scrubbing pager with multi-select delete/share, spanning both cards.
- **Body-fired capture sync**: shots released on the camera body register in the app (shutter
  animation + instant playback), read via the camera's event poll rather than the PTP-IP event
  socket.
- **Instant playback** assist (iOS + Android): the last shot reviews full screen — thumb first,
  full image streaming in — with an optional focus point frozen at capture, capture info, and an
  in-place favorite star written to the card.
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

### Fixed

- **Focus peaking now tracks the focus plane.** It measured edge contrast, which scales with how
  bright an edge is as much as with how sharp it is — so a defocused specular highlight outranked
  genuinely sharp low-contrast detail, painting background bokeh while skipping the subject. It
  now measures blur radius (a two-scale gradient ratio), which is independent of contrast.
  Separately, peaking ran on a stretch that flattened the top of the range, so in-focus highlight
  detail could never register at all. Both platforms; the sensitivity steps behave the same.
- Android: the media page no longer crawls after the first long-press — selecting one item used to
  make every later tap re-hash the whole library, and stale hit-test rectangles could send a tap to
  an off-screen item.
- Android: the shutter no longer re-focuses when focus was set with the focus dial, matching iOS.
- Android: star ratings write to the card as they always did — the star's tap target was far
  smaller than the minimum and gave no press feedback, so taps missed silently.

### Changed

- Google Play **internal** uploads automate like TestFlight: merge Android-relevant paths to `main`
  builds and uploads phone + Wear AABs when `PLAY_UPLOAD_ENABLED=true` (see
  `docs/android-distribution.md`). Manual dispatch and `android-v*` tags remain.
- Android control writes: facade owns encode + native confirm; shell no longer soft-fails after a
  successful apply (see `docs/android-control-writes.md`).
- TestFlight notes are now reviewed, tester-written copy with concrete test steps. CI rejects stale
  notes, commit titles, and common implementation jargon before an iOS build can ship.

### Fixed

- Focus peaking de-logs with the active mode's tone curve, so it looks identical in photo and video
  (was hardcoded to the movie log curve).
- Media: backup (two-card) shots appear under both slots and delete every copy; context-aware
  delete copy and companion handling (RAW+JPEG pairs; a video plus its R3D/NEV master); EXIF
  auto-rotation; and a batch-delete progress bar that refreshes the grid once at the end.
- Instant playback freezes the reviewed shot's focus box at capture time, so it no longer drifts if
  the AF point moves while the preview loads.

### Security

- All GitHub Actions in CI are pinned to full commit SHAs, and Docker-based actions to image
  digests, to prevent tag-hijack supply-chain attacks.
