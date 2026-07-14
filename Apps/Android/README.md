# OpenZCine Android

Production Jetpack Compose shell — early scaffold. One placeholder monitor screen
(black feed area, "No camera" state) wired through the camera-core seam.

- **Build:** `just android-build` from the repo root (or `just android-check` for build + tests + lint).
- **Swift core:** the camera brain is the shared Swift core (`Sources/OpenZCineCore`), cross-compiled
  to `libOpenZCineAndroid.so` and bound via JNI (`bridge/SwiftCore.kt` ↔
  `Sources/OpenZCineAndroidFacade`). Run **`just android-core` before installing** — it stages the
  `.so` set into `app/src/main/jniLibs/` (gitignored build artifacts, never committed). Plain
  `android-build`/`android-check` work without it; the app then logs a warning instead of loading
  the core. CI does not cross-compile yet (follow-up: `swift-android-action`).
- **Core seam:** `core-api/` is a pure-JVM module defining `CameraSession`, `LiveFrameSource`, and
  `CameraIdentity`; the Swift core plugs in behind it. Decision record:
  `docs/investigations/android-core-feasibility.md`.
- **Transport foundations:** `app/.../transport/` owns the platform byte layer — NSD/mDNS camera
  discovery (`CameraDiscovery` over an `NsdBrowser` seam, `_ptp._tcp`, plus the fixed camera-AP
  host) and `PtpIpSocketTransport` (command + event TCP sockets, graceful half-close teardown,
  settle-then-backoff reconnect). PTP-IP protocol/session logic arrives behind the JNI facade;
  this layer is bytes only. Debug hook to try it live:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez openzcine.nsdTransport true`.
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
