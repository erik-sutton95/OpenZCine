# OpenZCine Android

Production Jetpack Compose shell. The monitor screen is a 1:1 port of the iOS shell's
chrome, laid out by the shared core's zone map (`SwiftCore.monitorZoneMap` →
`MonitorZoneLayout.map`) in both orientations — no layout math lives in Kotlin. It covers
the live feed, top info deck, capture readout strip, the assist toolbar (wired to the
feed-effects engine + scope panels, toggles persisted), lock/battery band, the
record/DISP/media/settings controls with DISP 1→2→3 cycling (3 = the command dashboard),
and the portrait fit layout (sensor rotation; the activity survives it). Deferred:
pickers/panels, the portrait fill aspect, command tile interaction. Readouts are fake demo
values until the session facade arrives. Without the staged Swift core the app falls back
to the placeholder monitor ("No camera").

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
- **Liquid-glass chrome:** monitor chrome glass is a custom GPU treatment (`GlassChrome.kt`) —
  one shared blurred backdrop texture per feed frame, sampled by every pill (AGSL edge refraction
  on API 33+, plain pre-blurred fill on 31–32, the hand-rolled flat fill below). A frame-budget
  counter auto-degrades one tier under sustained overruns. Debug override:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.glass.tier blur`
  (`full`/`blur`/`flat`; lowers only).
- **Scopes v1:** waveform, RGB parade, histogram, and vectorscope render at ~10 Hz from the
  live feed. All axis/curve math lives in the shared core behind the facade
  (`Sources/OpenZCineAndroidFacade/ScopeFrameWire.swift` ↔ `bridge/ScopeWire.kt`): the 3-anchor
  display axis (log-black floor → 5% crush line, fixed per-curve mid grey, clip warning → 95%
  line) and the tone-mapped vectorscope come back as flat payloads; Kotlin only reduces the
  JPEG (1/2ⁿ decode to ≤160 px wide) and draws (`ScopeView.kt`). The assist toolbar owns the
  scope toggle; the debug intent still seeds it for tests:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true --es zc.scopes wave|parade|histo|vector`.
- **Feed effects (view assists):** `FeedEffectsRenderer` bakes LUT preview, false colour,
  focus peaking, and zebras into the live feed in one AGSL pass. All colour math is baked in
  the shared Swift core (`Sources/OpenZCineAndroidFacade/FeedEffectsWire.swift` — cubes from
  `MonitorLUT`/`FalseColorMap`, thresholds from `ExposureSignalMapping`); Kotlin only uploads
  textures/uniforms and interpolates. Requires **API 33 (AGSL)** and the staged Swift core —
  below that the plain feed still renders (minSdk 29) and a warning is logged. The assist
  toolbar (`AssistToolbar.kt`) is the operator switch — LUT/PEAK/FALSE/ZEBRA plus the four
  scope pills, toggles persisted in SharedPreferences. The debug intent still seeds an exact
  session state for tests (intent beats persistence):
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true
  --es zc.assist lut,peaking,zebra --es zc.lut log3g10` (`zc.assist` also takes `falsecolor`,
  with `--es zc.fc.scale stops|ire`; false colour replaces the LUT, like iOS).
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
