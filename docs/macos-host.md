# Mac camera module

On the Mac, OpenZCine runs as the Nikon Z camera module of the OpenCine desktop app (the dock). The
dock, its shared webcam driver and the module host live in the OpenCine repository; see the
OpenCine desktop design (`docs/superpowers/specs/2026-11-05-opencine-desktop-design.md` there).
This is a local Mac build under qualification, not a published release.

## What the module is

- The same `Runner` target built for Mac Catalyst, with the Mac bundle identifier
  `com.opencapture.openzcine.module` and the sandboxed `Runner/Runner-Mac.entitlements`.
- `macos/module.json` is the manifest the dock reads beside the bundle: module ID `nikon-z`, input
  name `OpenCine Nikon Z` and the bundle name.
- When the dock starts it, `DesktopModuleHost.current` (OpenCine `OpenCineVirtualCamera`) owns the
  module's webcam slot, its status to the dock and the window placement under the dock's tabs. A
  direct launch has no host and behaves as a plain Catalyst app.
- Mac-only code sits behind `#if targetEnvironment(macCatalyst)`. The iOS app is unchanged.

## Picture and control

Choose the camera connection for control independently from the picture source. For HDMI, connect
a UVC capture device, select HDMI as the picture source, then choose that device and a 1080p30 or
1080p60 mode under Operator Setup, Link. The Mac never substitutes its built-in camera or a virtual
webcam for the chosen device. Wireless Nikon control uses the network selected in macOS; the Mac
does not join a camera access point itself and says which network to choose in System Settings.

HDMI frames take the same path as on iPad: the capture renderer's bitmaps feed the monitor, scopes,
LUT and relay. The webcam output receives the clean picture with the selected LUT and no monitor
overlays, and a replaced capture source's late callbacks are dropped.

## Build

```sh
MACOS_DERIVED_DATA_PATH=<external build volume>/DerivedData just macos-build
```

The build signs with the team's Apple Development identity. Keep derived data on an external build
volume. Installing into the dock's modules folder uses OpenCine's `Desktop/scripts/install-local.sh`
with the built `Runner.app` and `macos/module.json`.

## Not yet verified

The HDMI capture chain on hardware, sustained frame pacing, receiving apps and long-running memory
use are proven only by a recorded hardware pass. Developer ID signing, notarization and the module
catalog are later steps. A compile is not proof of a working webcam input: only frames received by
another app are.
