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
- **Focus dial**: on-feed manual focus-by-wire pull in **photo and video** mode (iOS + Android) — a
  relative near↔infinity drum, toggled in the FOCUS popup, decoupled from the command tick so it
  tracks the finger. Off by default; an operator's explicit choice is preserved. The release
  preserves the dialed focus (no re-AF).
- **Burst series**: continuous-drive frames group into one stack that opens to a full-screen
  scrubbing pager with multi-select delete/share, spanning both cards.
- **Body-fired capture sync**: shots released on the camera body register in the app (shutter
  animation + instant playback), read via the camera's event poll rather than the PTP-IP event
  socket.
- **Instant playback** assist (iOS + Android): the last shot reviews full screen — thumb first,
  full image streaming in — with an optional focus point frozen at capture, capture info, and an
  in-place favorite star written to the card.
- **Keep a view-assist tool visible in clean view.** Every tool now carries a per-tool clean-view
  pin in Settings ▸ Display, so an operator who wants (say) the histogram or the delivery guides on
  the otherwise bare DISP 2 image can keep exactly that one. Off for every tool by default. Both
  platforms.
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

- **Media filters match the tab you are on.** The filter popup offered the same chips everywhere,
  so the Photos tab advertised MOV, MP4, and HD/4K/5.4K/6K — none of which a still can ever be, and
  nothing that describes one. Chips are now derived from the listing in front of the operator:
  Photos offers **JPEG / HEIF / NEF** and an **L / M / S** size row, Videos keeps its containers and
  resolution buckets, and DATE gained **7 days** and **30 days** beside Today. A chip only appears
  when it matches something in the tab *and* excludes something, so no row ever advertises a value
  that would return an empty grid or filter nothing at all; stills whose dimensions the camera never
  reported get no size row rather than a dead one. Switching tabs clears any chip the new tab cannot
  offer, so a MOV filter carried onto Photos no longer empties the grid with nothing to explain it.
  Both platforms.

- **Nikon HEIF stills (`.HIF`) show up in the media browser.** The shared classifier knew `.heif`
  and `.heic` but not the extension a Z body actually writes, so every HEIF on the card was treated
  as an unsupported object and never listed at all. Both platforms.

- **A dropped camera no longer needs an app restart, and a stalled first connect no longer needs
  a cancel.** A failed connection attempt now disposes exactly as thoroughly as tapping Cancel —
  the single-flight latch is released with the attempt it belonged to, so an immediate retry is
  never silently swallowed while an abandoned attempt unwinds. Every machine-driven connection
  phase has a truthful bounded timeout (phases that wait on a person stay unbounded), and the
  failed connection card gained **Try again**. When an established session drops — USB cable
  knocked loose, camera powered off and on, wedged command channel — the operator now stays in
  live view on the last frame (clearly marked as held, not live) while a bounded, cancellable
  reconnect runs, then gets **Retry connection** / **Operator menu**. The retry rule lives in the
  shared core, so both shells retry, back off, and give up identically. Both platforms.

- **A change made on the camera reaches the app promptly, in every mode.** Field testing found the
  first fix incomplete in two ways. The Nikon event queue that carries `DevicePropChanged` was only
  polled in photography chrome — it had inherited the chrome test from the body-fired-stills
  consumer, which applies that test itself — so cinema mode had no fast path at all and fell back
  to a round-robin that revisits any one property roughly every 20 s. Over USB, where there is no
  event socket, nothing else could have covered it. Separately the read itself was gated to that
  same background cadence, so a change the app had already *heard about* still waited out a poll
  interval sized for idle work; a pending announcement now shortens the stride until it drains,
  bounded so a continuously-announcing body cannot turn the loop into a per-frame round trip.
  Both platforms.

- **A pulled USB-C cable ends the session it belongs to.** Only the device-level removal callback
  was wired to teardown, and on a cable pull it did not fire, so the event stream stayed open and
  nothing raised recovery — Wi-Fi worked only because a dead socket fails on its own. Two further
  faults made it wedge rather than merely go quiet: closing the transport never resumed the
  in-flight transaction, so the shutdown that reconnect waits on queued behind a completion that
  never came; and the stall counter measured wall clock spent in the attempt rather than time
  spent streaming, so against a dead link every attempt reset the streak and escalation was never
  reached. iOS; the Android host already had all three legs.

- **The H.265 picker no longer collapses 8-bit and 10-bit.** A body advertising both wore one
  "H.265" row backed by whichever value came first, so leaving H.265 and returning to it silently
  landed on 8-bit. The depth is now chosen with **8-bit / 10-bit buttons flanking the codec row**,
  the same idiom as white balance's −10 / +10, and only for codecs the connected body actually
  advertises at more than one depth — a single-variant codec keeps a plain row and no buttons. The
  exact advertised value is what gets written, and the lit depth comes from the camera's own
  readback, so it survives closing and reopening the picker. Both platforms.
- **Pickers mirror the connected body instead of a fixed list of Nikon Z values.** Exposure mode,
  drive, focus mode/area/subject, metering, flash, image quality, NEF compression and picture
  control now come from the camera's own descriptors — its values, in its order. A body without
  user modes is no longer offered U1/U2/U3, drive reads in the body's release order (Single, CL,
  CH, CH+), and reconnecting or swapping cameras rebuilds every list from the new body.
- **Focus-area and subject-detection names match the camera's.** 3D tracking and subject tracking
  are AF-area modes and are now named as such, so neither reads as the separate subject-detection
  control beside it.
- **Clean view (DISP 2) is genuinely clean.** Scopes, traffic lights, the status deck, the side
  rails, feed overlays and pop-ups all stayed up, because every surface decided for itself what
  clean meant. One shared rule now answers that question for both shells. Clean shows the image
  and nothing else — apart from four deliberate exceptions: camera fault and thermal/card warnings,
  the recording tally, the record control while a take is rolling, and the DISP key itself (the way
  back out). Any tool can be pinned back on per tool. Both platforms.
- **Command view (DISP 3) no longer freezes the timecode.** It hid the image and ended live view to
  keep the camera cool — but timecode only exists in the live-view frame header, so the dashboard's
  hero clock stopped at whatever the last frame before the switch carried, which looks plausible
  and is wrong while the camera is rolling. Command now keeps the stream at the smallest frame the
  body offers and reads only its header, skipping decode, display and analysis. Wi-Fi and USB.
  Both platforms.
- **Focus peaking now tracks the focus plane.** It measured edge contrast, which scales with how
  bright an edge is as much as with how sharp it is — so a defocused specular highlight outranked
  genuinely sharp low-contrast detail, painting background bokeh while skipping the subject. It
  now measures blur radius (a two-scale gradient ratio), which is independent of contrast.
  Separately, peaking ran on a stretch that flattened the top of the range, so in-focus highlight
  detail could never register at all. Measured against a real focus sweep from the camera, a fully
  defocused frame now paints nothing at all.
- **Peaking behaves the same on iPhone and on Android, and the same in photo mode as in video.**
  The two platforms were running detectors that only resembled each other, each with its own
  thresholds, so "Med" did not mean the same thing on a phone as on an iPhone. There is now one
  detector definition that both render. And because the photography feed is a display-referred
  preview rather than log, the same scene used to read as sharper in photo mode than in video —
  a sensitivity step silently meant something stricter in one mode than the other. Both platforms
  now correct for the feed's encoding. One difference remains: Android does not yet smooth the
  finished overlay the way iOS does, so at the same setting it reads slightly grainier.
- Android: the media page no longer crawls after the first long-press — selecting one item used to
  make every later tap re-hash the whole library, and stale hit-test rectangles could send a tap to
  an off-screen item.
- Android: the shutter no longer re-focuses when focus was set with the focus dial, matching iOS.
- Android: star ratings write to the card as they always did — the star's tap target was far
  smaller than the minimum and gave no press feedback, so taps missed silently.
- Android USB-C: a camera error or unplug during a tethered session could crash the app instead of
  ending the session. The camera-event reader could re-arm a transfer the system still owned; it now
  hands each one back before starting the next, and an unrecoverable event channel closes the USB
  session cleanly.
- **The focus dial no longer stalls or blocks tap-to-focus.** A refused focus drive retried by
  count, and each attempt could spend seconds polling the camera for readiness — so one drag could
  own the single camera command channel long enough that the body answered every AF-area change
  "busy", leaving both the dial and tap-to-focus dead until a shutter release. Refusals are now
  budgeted by wall clock, a tap or recenter pre-empts an in-flight drive, and an AF-area change
  retries a busy body instead of dropping the tap. Both platforms.
- Starting tap-to-focus no longer hitches the live view: the AF-confirmation poll ran inside the
  frame loop and stalled it for about half a second.

- Media: backup (two-card) shots appear under both slots and delete every copy; context-aware
  delete copy and companion handling (RAW+JPEG pairs; a video plus its R3D/NEV master); EXIF
  auto-rotation; and a batch-delete progress bar that refreshes the grid once at the end.
- Instant playback freezes the reviewed shot's focus box at capture time, so it no longer drifts if
  the AF point moves while the preview loads.

### Changed

- The **Focus dial** is available in video mode as well as photo mode, and is now **off by default**
  on a new install. An operator who already switched it on (or off) keeps that choice.

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
