# OpenZCine Android

Production Jetpack Compose shell. The landscape monitor screen is a 1:1 port of the iOS
shell's chrome, laid out by the shared core's zone map (`SwiftCore.monitorZoneMap` →
`MonitorZoneLayout.map`) — no layout math lives in Kotlin. v1 covers the live feed, top
info deck, capture readout strip, lock/battery band, and the record/DISP/media/settings
rail with DISP 1↔2 cycling; assists, scopes, pickers, and portrait land later. Readouts
are fake demo values until the session facade arrives. Without the staged Swift core the
app falls back to the placeholder monitor ("No camera").

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
- **Camera session (Swift core):** `bridge/SwiftCoreCameraSession` implements the `CameraSession`
  seam over the Swift core's PTP-IP session layer
  (`Sources/OpenZCineAndroidFacade/PTPIPClientSession.swift`): Init handshake, the Nikon
  open/pair/identify sequence, core-decoded property reads, and graceful `CloseSession` teardown
  all run inside the `.so` — the facade owns the session sockets (decision record: the feasibility
  doc's "Where sockets go"). Point the debug probe at a camera or fake server:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host <ipv4>`
  (logcat tag `SwiftCoreCameraSession`). For a fake-ZR server on the development Mac (scripted
  twin: `Tests/OpenZCineAndroidFacadeTests/FakeZRServer.swift`), forward the port with
  `adb reverse tcp:15740 tcp:15740` and use host `127.0.0.1`.
- **Feed effects (view assists):** `FeedEffectsRenderer` bakes LUT preview, false colour,
  focus peaking, and zebras into the live feed in one AGSL pass. All colour math is baked in
  the shared Swift core (`Sources/OpenZCineAndroidFacade/FeedEffectsWire.swift` — cubes from
  `MonitorLUT`/`FalseColorMap`, thresholds from `ExposureSignalMapping`); Kotlin only uploads
  textures/uniforms and interpolates. Requires **API 33 (AGSL)** and the staged Swift core —
  below that the plain feed still renders (minSdk 29) and a warning is logged. Debug-only
  activation until the assist toolbar lands:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true
  --es zc.assist lut,peaking,zebra --es zc.lut log3g10` (`zc.assist` also takes `falsecolor`,
  with `--es zc.fc.scale stops|ire`; false colour replaces the LUT, like iOS).
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
