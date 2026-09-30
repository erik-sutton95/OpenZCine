---
title: Android app
description: Jetpack Compose phone shell on the shared Swift core, with a Wear OS companion. Google Play public beta and a sideload APK. arm64 only.
---

The Android app lives in `Apps/Android/`. It is a Jetpack Compose phone shell
whose monitor is a port of the iOS chrome, laid out by the shared core's zone
map in both orientations. No layout math or protocol packing lives in Kotlin.
The public beta is on
[Google Play](https://play.google.com/store/apps/details?id=com.opencapture.openzcine).
Devices without Google Play install the sideload APK from
[GitHub Releases](https://github.com/erik-sutton95/OpenZCine/releases). arm64
phones and tablets, Android 10 or newer.

If pairing or live view fails, use **Operator Setup → System → Report a
Problem** or **Settings → Share Diagnostics**
([Troubleshooting](../../guides/troubleshooting/)).

## Before pairing

The app opens on the first-pair wizard: permissions, choose path, prepare the
camera, network, then find and pair. There are separate paths:

| Path | What happens |
| --- | --- |
| **Camera Wi-Fi** | The phone joins the camera's own network. The key is entered once and remembered in Keystore-encrypted storage after a successful join. |
| **Router** | Phone and camera share a network; the app discovers the camera there. |
| **Phone hotspot** | The camera joins this phone's hotspot. The phone hosts and waits for the camera; it never scans or joins. |
| **USB-C** | Android USB Host finds the camera's PTP interface and asks for consent per device. |

On the Camera Wi-Fi step, the scanner reads the network name and key from the
camera's Connection screen with the rear camera and on-device text recognition.
The shared Swift parser validates the result and you review it before joining.
No frame, recognized text or key is logged or kept until a join succeeds. If the
scanner cannot read the screen, type the name and key; the same validation
applies.

## Permissions

| Permission | Why |
| --- | --- |
| **Nearby Wi-Fi devices** or **Location** | See and join Wi-Fi networks, and read which network the phone is on |
| **Camera** | Only for the Wi-Fi scanner, and for HDMI capture devices |
| USB device consent | Asked per camera when you connect over USB-C |

The app asks for no Bluetooth or storage permission for the camera link.
Saved USB profiles use a local reconnect key, never the raw USB serial or a
network address.

## Field Monitor interface

The monitor matches the [iOS app](../ios/#field-monitor-interface): DISP 1 Live,
2 Clean and 3 Command, per-element switches per DISP mode and per capture side,
the capture strip, the View Assist toolbar and the system rail. A portrait pinch
snaps between fit 16:9 and fill at the same thresholds as iOS. DISP 3 shows the
camera property snapshot and opens typed pickers for ISO, shutter, iris, white
balance, exposure mode, focus and supported audio settings.

Readouts are authoritative: timecode comes only from the camera frame accepted
for display, and camera values from the property snapshot. A missing or
unsupported value shows as unavailable, never as a demo value.

### Anamorphic Desqueeze

Horizontal and vertical desqueeze scale the picture in live view and playback,
with 1.6× and a custom 1.00× to 2.00× ratio in 0.01 steps. Display only.

## Level

The LEVEL overlay prefers the camera's virtual-horizon angles, in Horizon or
Gauge style. When a frame has no reliable camera level, it falls back to the
phone's tilt sensor and labels that fallback clearly.

## Scopes and assists

Waveform, parade, histogram, vectorscope, false color, zebras, Traffic Lights,
focus peaking and LUTs follow the iOS definitions. On API 33 and newer the
effects run in an AGSL renderer; API 29 to 32 use a GLES path fed by the same
shared Swift plan. Scope panels and the false-color reference drag like iOS.

Peaking uses the same detector as iOS. One difference remains: Android does not
yet smooth the finished overlay, so at the same setting it reads slightly
grainier.

Custom `.cube` LUTs are strictly parsed by the shared core and copied into
app-private storage. The RED LUT download stays off on Android until an
authorized endpoint and terms flow exist.

## How Swift reaches Android

Business logic stays in `OpenZCineCore`. Android does not duplicate protocol
logic:

1. Portable Swift core (no SwiftUI, UIKit or Android imports).
2. `OpenZCineAndroidFacade`: Swift-owned PTP-IP and USB session serialization,
   response validation, event draining, and a narrow JNI boundary.
3. The Swift SDK for Android cross-compiles the core for arm64-v8a. Toolchain
   pin: Swift **6.3.3**.
4. Kotlin `core-api` defines the typed session boundary. Kotlin never packs PTP
   commands or invents camera property values.

Control writes: the facade encodes and confirms natively; Kotlin does not
second-guess success after a successful apply. See
[`docs/android-control-writes.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/android-control-writes.md).
Build recipes: [Setup](../../guides/setup/#android). Architecture:
[Architecture](../architecture/).

## Operator surface

- **Camera control and photography mode** match iOS: pickers from the body's
  own descriptors, the focus dial (off by default), photo chrome, instant
  playback and burst stacks.
- **Media** browses every card, pages newest first across slots, plays
  progressive proxies with assists, and filters by the tab you are on.
- **Delivery**: native Share, Save to Gallery and Frame.io use only finalized
  cached files, with an optional LUT bake to MOV or MP4. The camera original is
  never changed. Frame.io remembers confirmed uploads and skips them by default.
- **Share This Feed**: broadcast or watch, as on iOS
  ([Share This Feed](../../guides/share-feed/)).
- **HDMI capture**: the picture can come from a capture device through CameraX
  while camera control stays on the normal link.
- **Bluetooth shutter**: generic volume-button remotes and headset controls
  trigger recording while the live monitor is armed.

## Wear OS

The Wear OS companion is a foreground-only wrist monitor, relayed through the
phone. It receives a display-baked preview with the phone's LUT and assists,
camera timecode, measured frame rate and monitor state, and can toggle
recording through the same guarded phone path. It has no camera, network,
Bluetooth or storage permission of its own. Resolution and JPEG quality adapt to
the watch link. A physical watch pass is still pending.

## Device requirements

Android **10** (API 29) or newer, **arm64-v8a** only. The phone and Wear bundles
share the package `com.opencapture.openzcine`. UI changes are checked in
portrait and landscape on the Android hardware floor.

## Releases

Public beta:
[Google Play](https://play.google.com/store/apps/details?id=com.opencapture.openzcine).
A merge to `main` that touches Android-relevant paths uploads signed phone and
Wear bundles to Play internal testing. Pull requests that can trigger that
upload refresh
[`Apps/Android/distribution/whatsnew/whatsnew-en-US`](https://github.com/erik-sutton95/OpenZCine/blob/main/Apps/Android/distribution/whatsnew/whatsnew-en-US)
with plain-language tester notes. Maintainer setup:
[`docs/android-distribution.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/android-distribution.md).

**Sideload APK:** for devices without the Play Store, one arm64 APK for Android
10 and newer is attached to
[GitHub Releases](https://github.com/erik-sutton95/OpenZCine/releases). Remove a
copy installed from Play or an APK mirror first. That copy is signed by Google
and cannot be updated by the APK. Release window: [0.2.5](../../releases/0-2-5/).
