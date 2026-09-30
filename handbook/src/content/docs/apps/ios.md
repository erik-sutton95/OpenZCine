---
title: iOS app
description: SwiftUI iPhone and iPad shell with an Apple Watch companion. Physical device for camera Wi-Fi and USB-C. TestFlight is the public beta.
---

The production iOS app is a universal iPhone and iPad SwiftUI shell in
`ios/Runner/`, with an Apple Watch companion in `ios/OpenZCineWatch/`. It
consumes the portable Swift core in `Sources/OpenZCineCore/` directly. Open
`ios/Runner.xcodeproj`; the Simulator can run the demo session without a camera.
See [Setup](../../guides/setup/).

## Field Monitor interface

After connection, OpenZCine starts Nikon live view and opens the monitor when
the first readable frame arrives. The monitor is one view tree for landscape and
portrait. Rotation moves each module to its new place without rebuilding it.
iPhone works in both landscape directions: the picture and controls swap sides
so nothing hides behind the Dynamic Island.

| DISP mode | What it shows |
| --- | --- |
| **1 Live** | Picture, capture strip, View Assist toolbar, status readouts and system rail |
| **2 Clean** | The picture only, plus camera fault and thermal or card warnings, the recording tally, the record control while rolling, and the DISP key |
| **3 Command** | A camera dashboard without the picture. Live view keeps running at the smallest frame so the timecode stays live. |

Swipe the feed vertically to change DISP mode. Every monitor element is its own
switch, per DISP mode and separately for video and photo, under **Settings →
Display**. Clean view starts with the image, the rail, the focus box and the
batteries; any View Assist tool can be pinned back on per tool. Some controls
cannot be hidden from the inside: record returns while a take is rolling,
Settings returns when no enabled DISP mode carries it, and the lock key returns
whenever controls are locked.

The status deck shows timecode, REC state, codec, media, frame rate, battery,
storage, temperature and camera warnings when the camera reports them. Timecode
comes from the live-view frame header, so it is the camera's own clock.

Use the trailing record control to start or stop in-camera recording. Record
confirmation, haptics, keep-screen-awake and Bluetooth shutter or volume-button
triggers are under **Settings → Controls**. Lock the interface to prevent
accidental picker changes.

Pinch the live view to zoom anywhere in the frame; tap-to-focus follows the
zoom. Fit shows the whole 16:9 picture; in portrait, pinch switches between fit
and a center-cropped fill.

### Anamorphic Desqueeze

Desqueeze scales the picture itself, not only the guides, in live view and
playback. Presets include 1.6×, and a custom ratio runs from 1.00× to 2.00× in
0.01 steps. Photo mode has the same presets for live view, instant playback and
the still viewer. It is display only: the camera original and any export are
unchanged.

### Vertical camera mode

Turn the body on its side and the picture follows, in video and photo, with a
portrait layout built for it. **Settings → Controls → Auto-Rotate Feed** turns
the upright rotation off. The recording is never affected.

## Level

The level reads the camera's own virtual-horizon angles from the live-view
frame header. The core drops angles the camera reports as unreliable instead
of drawing a guessed level.

## Scopes and exposure assists

Tap an assist to toggle it; long-press it to open its configuration. Reorder or
hide tools in Settings.

- **Waveform, RGB parade, histogram and vectorscope** run live beside the
  picture. Waveform and parade brightness runs 0 to 200%.
- **False color** is codec-aware, **zebras** mark levels, and
  **Traffic Lights** is a RED-inspired per-channel meter that leans over or
  under from middle gray.
- In landscape and portrait fill, scope panels float and can be dragged and
  resized; positions persist. Portrait fit stacks the two most recently
  activated scopes. A third stays active but hidden until you close one or
  pinch to fill.
- In photo mode, scopes and false color read the stills preview (sRGB or HLG),
  and an EV meter follows the body's exposure indicator.

## Focus assists

- **Focus peaking** measures blur radius rather than edge contrast, so a
  defocused highlight no longer outranks sharp low-contrast detail. Sensitivity
  and color are adjustable.
- **Tap-to-focus** moves the camera's AF area. AF and subject-detection boxes
  from the camera are drawn over the feed.
- The **focus dial** is an on-feed focus-by-wire pull in video and photo. It is
  off by default; turn it on in the FOCUS popup. A release keeps the dialed
  focus.

## Framing and LUTs

Framing tools stack multiple aspect markers and masks, custom frames,
thirds/phi/diagonal grids, a crosshair and the level. **LUT preview** applies
built-in looks, downloaded RED LUTs or imported `.cube` files from 2³ to 64³.
Press and hold a downloaded or imported LUT to remove it; built-in looks stay
protected. RED LUTs are downloaded at runtime and never bundled.

## Feed processing

**Settings → Link → Processing** offers a Feed Upscaler (Off, Fast, Quality,
AI) and temporal Feed Noise Reduction. New installs start on Fast. AI infers
detail the camera never captured, so judge critical focus on Quality or Fast.
Link Health shows the rate the link is actually carrying.

## Camera control

Tap a readout to open its picker. Pickers mirror the connected body: its values,
in its order. ISO, shutter speed or angle, iris, white balance, exposure mode,
focus mode, AF area and subject detection, drive, metering, image quality,
picture control, resolution, frame rate and codec come from the camera's own
descriptors. A change counts once the camera reads it back.

- **Auto ISO** controls movie ISO auto for non-R3D codecs. R3D NE keeps its
  Low/High dual base and stays manual.
- **H.265** shows 8-bit / 10-bit buttons beside the codec row only when the
  body advertises both depths.
- **Camera clock sync** sets a body that has drifted more than five seconds to
  the phone's time on connect, never while recording.

Mode-dependent limits are listed under [ZR exposure and focus](../../devices/zr/settings/).

## Photography mode

Dedicated stills chrome with a real shutter (hold to burst in continuous
drives, tap-to-AF, bulb and time), built-in and app self-timers, and pickers for
mode (including U1 to U3 where the body has them), ISO Auto, focus, drive, white
balance, size, quality (RAW plus JPEG or HEIF) and picture profile. Shots fired
on the camera body appear in the app. **Instant playback** reviews the last shot
with an optional focus point frozen at capture and a favorite star written to
the card. Continuous-drive frames group into one burst stack.

## Media and delivery

Open **Media** from the home screen or the monitor to browse the camera's cards
while clips cache progressively.

- Grid or list, thumbnail size, and filters derived from the tab you are on
  (container, resolution or JPEG/HEIF/NEF and L/M/S size, date, card slot).
- Play, scrub, jump 15 seconds, mute, zoom and pan, with scopes, markers and the
  selected LUT during review. A clean-view button hides everything but the
  picture.
- **Slow-motion conform preview** plays a high-frame-rate clip at the edit rate
  (for example `60 → 24 fps · 40%`). The clip is never modified.
- **Share** and **Save to Photos** export MOV or MP4 and can bake the selected
  LUT. They work while the camera is connected.
- **Frame.io** upload (iOS 17.4 or newer, only in builds configured with
  credentials): sign in under **Settings → Storage**, choose or create a
  project, and upload. On camera Wi-Fi, the app can hop to the internet,
  deliver, then rejoin the camera.

## Apple Watch

The watch mirrors the live feed with its LUT, camera status and timecode, and
rolls or cuts recording. Photo mode adds a shutter and a shots-remaining
readout; the crown magnifies the preview and a drag pans it.

## USB-C and HDMI capture

USB-C tethering uses ImageCaptureCore: discovery, connection, reconnect on
plug-in and after a loose cable, and a transport-aware first-pair wizard. On
iPad, the picture can come from the camera's HDMI output through a USB video
capture device while exposure, focus, record and media stay on the camera link.

## Share This Feed

Broadcast the monitor to other phones and iPads on set, with per-watcher assists
and a control handoff. See [Share This Feed](../../guides/share-feed/).

## Device requirements

iOS and iPadOS **17.0** or newer; Frame.io needs **17.4**. watchOS **10** or
newer for the companion. Camera discovery needs **Local Network** access; the
camera is used only to scan the Wi-Fi name and key from the camera screen, and
on iPad to read a USB capture device. Photos access is requested only for Save
to Photos.

The Simulator cannot reach a camera. Protocol tests (`just test`) do not need
hardware. Wire notes for iOS: [iOS protocol notes](../../protocol/ios/).

## Releases

Public beta: [TestFlight](https://testflight.apple.com/join/xu4d6UK8). A merge to
`main` that changes native iOS code uploads a TestFlight build. Pull requests
that change `Sources/`, `Tests/`, `ios/`, `Package.swift`, `scripts/` or the
`justfile` must replace
[`ios/TestFlight/WhatToTest.en-US.txt`](https://github.com/erik-sutton95/OpenZCine/blob/main/ios/TestFlight/WhatToTest.en-US.txt)
with plain-language tester notes; CI rejects stale or developer-centric copy.
Maintainer setup: [`docs/testflight-ci.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/testflight-ci.md).
Release window: [0.2.5](../../releases/0-2-5/).

If something fails, use **Operator Setup → System → Report a Problem** or
**Settings → Share Diagnostics** ([Troubleshooting](../../guides/troubleshooting/)).
