# OpenCine integration candidate (Nikon)

Local candidate branch `opencine/integration`, based on `origin/main` 9ac41387. Not pushed, not
hardware-qualified. It combines the OpenCine work packages that apply to the shipping app.

## Contents

| Work package | Branch | Tip |
|---|---|---|
| CORE-02 (Nikon adapter on OpenCineCore) + CORE-01b update | `opencine/core-02-nikon` | 6bce2301 |
| STATE-01 (Nikon session ownership) | `opencine/state-01-nikon` (on core-02) | 8de98639 |
| MEDIA-01 (CubeLUT, FrameRateSampler from OpenCineMedia) | `opencine/media-01` | ba1e340b |

Shared package: `../OpenCineCore`, pinned in `opencine-pins.txt` (one line, OpenCineCore
28a0196, which contains the MEDIA-01 commit 4d001e4) and fetched in CI by
`scripts/checkout-opencine.sh`. The Runner project has one local package reference,
`../../OpenCineCore`, that provides both the OpenCineCore and OpenCineMedia products. The root
`Package.swift` links OpenCineMedia only, and the Gradle `stageSwiftCore` inputs fingerprint
`../OpenCineCore/Package.swift` and `Sources/OpenCineMedia/**`.

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

## Before this can ship

The OpenCine packages must be published first (sibling paths become SwiftPM url + version and
Maven coordinates). The steps are in `opencapture-atlas/docs/PUBLISH.md`.
