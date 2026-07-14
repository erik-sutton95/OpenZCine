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
  open/pair/identify sequence, core-decoded property reads, live view, and graceful `CloseSession`
  teardown all run inside the `.so` — the facade owns the session sockets (decision record: the
  feasibility doc's "Where sockets go"). Live view is a Swift-side frame pump
  (`sessionStartLiveView` / `sessionStopLiveView`, latest-wins backpressure, absolute-schedule
  poll pacing) bridged into the `LiveFrameSource` seam by `bridge/SwiftCoreLiveFrameSource`;
  `MonitorScreen` streams a connected Swift-core session's frames automatically (gated on a
  STARTED lifecycle), and ending collection — disconnect or backgrounding — always sends
  `EndLiveView` (the heat-audit rule). Drive the real shell against a
  camera or fake server:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host <ipv4>`
  (connect phases: logcat tag `SwiftCoreCameraSession`; frame pacing: tag `ZCLiveFeed`). For a
  fake-ZR server on the development Mac (scripted twin, incl. a synthesized live-view stream:
  `Tests/OpenZCineAndroidFacadeTests/FakeZRServer.swift`), run
  `ZC_FAKE_ZR_PORT=15740 swift test --filter servesFakeZRForDevice` at the repo root, forward the
  port with `adb reverse tcp:15740 tcp:15740`, and use host `127.0.0.1`.
- **Media browse + progressive playback:** the monitor's media button opens
  `media/MediaBrowseScreen`, an iOS-look dark clip grid (thumbnails, size/codec badges,
  listing/empty/error states) listed through the facade's bounded
  `sessionListMedia`/`sessionThumbnail` (`GetObjectHandles`/`GetObjectInfo`/`GetThumb`). MOV/MP4/M4V
  proxies open `MediaPlaybackScreen`; stills and R3D masters are explicitly view-only. The Swift
  core selects standard `GetPartialObject` or Nikon's 64-bit `GetObjectSize`/`GetPartialObjectEx`
  path and pumps ordered 4 MiB chunks over JNI. Kotlin persists them below `noBackupFilesDir` in a
  resumable `.part` cache while Media3 reads the growing file; completion publishes the final file
  atomically. Opening Media stops and excludes live view until the browser closes, so both pumps
  never contend for the serialized camera command channel. The Nikon large-object operations still
  require real-ZR verification. For an on-device fake-ZR playback run, set
  `ZC_FAKE_ZR_MEDIA=/absolute/path/to/a/playable.mp4` alongside `ZC_FAKE_ZR_PORT=15740` when running
  `swift test --filter servesFakeZRForMediaBrowse`, then `adb reverse tcp:15740 tcp:15740`, launch
  with `--es zc.session.host 127.0.0.1`, and open `C0008.MOV`. The file is local-only and must stay
  under an ignored path; `ZC_FAKE_ZR_CLIPS=0` still serves the empty-card state.
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
