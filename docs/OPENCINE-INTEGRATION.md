# OpenCine integration candidate (Nikon)

Local candidate branch `opencine/integration`, based on `origin/main` 9ac41387. Not pushed, not
hardware-qualified. It combines the OpenCine work packages that apply to the shipping app.

## Contents

| Work package | Branch | Tip |
|---|---|---|
| CORE-02 (Nikon adapter on OpenCineCore) + CORE-01b update | `opencine/core-02-nikon` | 6bce2301 |
| STATE-01 (Nikon session ownership) | `opencine/state-01-nikon` (on core-02) | 8de98639 |
| MEDIA-01 (CubeLUT, FrameRateSampler from OpenCineMedia) | `opencine/media-01` | ba1e340b |
| VENDOR-02 (Runner links OpenZCineCore; Nikon code in OpenCineNikon) | `opencine/vendor-02-nikon` (on integration) | see branch |
| OPTIONAL-01 (Frame.io from OpenCineFrameIO) | `opencine/frameio` (on integration) | see branch |
| MEDIA-02 step 4 (HDMI/UVC capture source from OpenCineApple) | `opencine/apple` (on integration) | see branch |

Shared package: the OpenCine platform repository `../OpenCine` (every shared Swift product and
Android module), pinned in `opencine-pins.txt` (one line, `OpenCine <sha>`) and fetched in CI by
`scripts/checkout-opencine.sh`. The Runner project has one local package reference,
`../../OpenCine`, that provides the OpenCineCore, OpenCineMedia, OpenCineFrameIO and
OpenCineApple products. The root `Package.swift` takes OpenCineMedia, OpenCineNikon and
OpenCineFrameIO from the same `../OpenCine`, Android includes `../../../OpenCine/Android` once
(build name `opencine`), and the Gradle `stageSwiftCore` inputs fingerprint
`../OpenCine/Package.swift` and the `Sources/<Target>/**` the Swift Android core links.

VENDOR-02: the Runner and Watch targets link the `OpenZCineCore` product of the local package
`..` instead of compiling its sources (each implementation is compiled once). The PTP wire,
Nikon properties/profiles/media naming, discovery/connect/session policy and `NikonCameraSession`
live in the `OpenCineNikon` product of `../OpenCine` (pinned in `opencine-pins.txt`), which
`OpenZCineCore` depends on and re-exports (`Sources/OpenZCineCore/OpenCineNikon.swift`).
`stageSwiftCore` also fingerprints `../OpenCine/Sources/OpenCineNikon/**`. The Android JNI facade and its
`AndroidSessionOwnerRegistry` stay here and link the package through `OpenZCineCore`.

OPTIONAL-01: Frame.io request planning, OAuth PKCE, response models and the iOS upload client
come from the optional `OpenCineFrameIO` product of `../OpenCine`. The Runner links it
(Watch does not; `OpenZCineCore` stays free of Frame.io), and the Android facade's
`FrameioWire` uses it through the root `Package.swift`, injecting swift-crypto's SHA-256 for
PKCE (CryptoKit on Darwin). The app keeps OAuth presentation, the callback scheme and client ID
(`Frameio.xcconfig`, Android build config), the destination preference and its keychain item
(service `OpenZCine.frameio`, account `oauth-token`, asserted by `FrameioCredentialsTests`). The
Kotlin delivery controller, upload history, keystore storage and camera access point hop are
unchanged. `stageSwiftCore` also fingerprints `Sources/OpenCineFrameIO/**`.

MEDIA-02 step 4: the iPad HDMI/UVC capture source (`UVCVideoSource`, its states and the format
choice) comes from the `OpenCineApple` product of `../OpenCine` (the Runner links it; Watch and
the root `Package.swift` do not). It lends each frame as a `DecodedFrameLease` stamped with a
generation that advances when the capture device goes away or changes. The app keeps the operator
copy for each state and renders leases to `UIImage` in `UVCFrameRenderer` (an actor, off the main
actor), releasing each lease after the render. `ios/Runner/UVCVideoSource.swift` now holds only that
glue. The JPEG `FrameDecoder` / Metal live view are app runtime and unchanged. Pinned to OpenCineCore's
`apple` branch until it merges to Core main.

Not included: the engine-port UI candidate `opencine/ui-03-engine-port-candidate` (OpenCineUI on
the unmerged `feat/monitor-engine-port`). It stays separate until the engine-port decision is made.

## What changes for users

- Record confirmation runs the target the operator confirmed. Before this, the app recomputed
  the toggle, so a take started or stopped on the body while the prompt was open could be
  inverted (f3f26e98, can be cherry-picked on its own).
- ISO, white balance and record commands go through `NikonCameraSession` on OpenCineCore (iOS
  and Android). Requested and reported state are kept apart, and a value the camera parked on
  (for example Auto ISO off the ladder) is admitted. With control surrendered, record presses
  from the watch or a Bluetooth shutter are now refused (they used to be allowed).
- Android facade sessions are keyed by their connection owner (`AndroidSessionOwnerRegistry`
  replaces the single active-session slot), and the `FeedEffectsState.current` mirror is gone.
- The FPS readout (iOS) no longer rewinds on a stale or repeated frame timestamp (shared sampler).
- HDMI capture (iPad): no visible change intended. Frames are now rendered to a bitmap only when
  the monitor takes them (the newest-wins drop happens before the render, not after), off the main
  actor instead of on the capture queue, and a frame captured from a device that was unplugged or
  swapped is dropped.

## Physical device checklist

Nikon ZR plus one other Z body, Wi-Fi and USB, on iOS and Android.

1. ISO in M with H.265: the drum value lands and is not reported "not applied". Auto ISO
   parked off the ladder (51200), then Auto off. R3D NE Low/High base; R3D ISO blocked while
   recording; P/A/S leave ISO to the camera.
2. White balance: Auto, Natural auto, Sunny, Cloudy, Preset; Kelvin 5560 and fine adjust 5570;
   R3D NE hides auto presets; iOS photo-mode WB still writes.
3. Record with live view, with an HDMI picture (control pump) and without live view (iOS refuses
   with "Start live view before recording."). With confirmation on, start or stop the take on
   the body while the prompt is up, then answer: the state must not invert.
4. Record from Apple Watch, Bluetooth shutter, Wear OS and a relay viewer with control. With
   control surrendered, watch and Bluetooth presses are refused.
5. A refused record (no card, card full) puts the button back to the state the camera reports.
6. Link drop or USB replug during a write and during a recording: nothing stays pending, and
   controls work after reconnect.
7. Android: connect, record, ISO, WB, live view, media browse, thumbnails, rating, delete,
   transfer and share. Reconnect, and cancel during connect then retry. LUT, peaking and zebra
   still render on the feed; the demo shell feed still works.
8. Media: an imported `.cube` LUT renders on the live feed as before (iOS and Android), and the
   iOS FPS readout stays steady across a Wi-Fi hiccup.

9. VENDOR-02 packaging (no intended behavior change): connect over Wi-Fi (camera access point
   and router) and USB, pairing and saved-camera reconnect, passive discovery still lists the
   body without probing it, ISO/WB with an HDMI picture and with no picture, record with live
   view, media browse. iOS, Watch app and Android.

10. Frame.io (OPTIONAL-01): on an iOS build that was signed in to Frame.io before this update,
    install over it and upload a clip without signing in again. Sign out and in, list and create
    a project, upload with LUT bake. Android: sign in, upload, refresh after expiry.

11. HDMI capture (MEDIA-02 step 4, iPad with a UVC dongle): picture, format and colorimetry readout,
    hot-unplug and replug, swapping dongles, switching between HDMI and the camera's own live view,
    scopes and LUT on the HDMI picture, watch relay. Compare CPU, memory and thermal state over
    20 min at 1080p60 and 4K30 against `opencine/integration`.

## Before this can ship

The OpenCine platform repository must be published first (the sibling path becomes SwiftPM url +
version and Maven coordinates). The steps are in `OpenCine/atlas/docs/PUBLISH.md`.
