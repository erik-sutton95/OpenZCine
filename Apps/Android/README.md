# OpenZCine Android

Production Jetpack Compose shell. The monitor screen is a 1:1 port of the iOS shell's
chrome, laid out by the shared core's zone map (`SwiftCore.monitorZoneMap` →
`MonitorZoneLayout.map`) in both orientations — no layout math lives in Kotlin. It covers
the live feed, top info deck, capture readout strip, the assist toolbar (wired to the
feed-effects engine + scope panels, toggles persisted), lock/battery band, the
record/DISP/media/settings controls with DISP 1→2→3 cycling (3 = the command dashboard),
and the portrait fit layout (sensor rotation; the activity survives it). DISP 3 observes the
real Swift-core property snapshot, persists its primary-tile order, and opens typed control
pickers for ISO, shutter, iris, white balance, exposure mode, focus, and supported audio
settings. Resolution, codec, and VR/e-VR remain read-only until camera descriptor options or
write selectors are available. General monitor picker panels and the portrait fill aspect remain
deferred. Without the staged Swift core the app falls back to the placeholder monitor ("No
camera") and every unavailable command value is shown as an em dash rather than a demo value.

The installed app uses an adaptive launcher icon with the same monitor, exposure-graph, and camera
language as the iOS app icon. Its foreground stays inside Android's adaptive safe zone, so circular,
squircle, and themed launcher masks retain the mark rather than cropping it.

- **Build:** `just android-build` from the repo root (or `just android-check` for build + tests + lint).
- **Pairing (`app/.../pairing/`):** the app opens on the first-pair wizard, a port of the iOS
  startup flow (`ios/Runner/StartupDesign.swift`) in its design language: permissions → choose
  path → prepare → network (→ find and pair). Three hard-separated paths: **camera-AP** (the phone
  joins the camera's `NIKON_ZR_…` network via `WifiNetworkSpecifier` + `bindProcessToNetwork`,
  key entered once and remembered in a Keystore-encrypted store) and **phone-hotspot** (the
  CAMERA joins the phone's hotspot — the phone hosts, never scans or joins; NSD discovery waits
  for the camera), plus **USB-C** (Android USB Host discovers a complete PTP interface, asks for
  per-device consent, and hands raw bulk/interrupt bytes to Swift). USB saved profiles use a
  local `usb:<digest>` reconnect key only — never the raw USB serial, display name, log value, or
  network address. The camera-AP network step can scan the camera's Connection wizard with a
  temporary CameraX rear-camera preview and bundled, on-device ML Kit OCR; one ephemeral transcript
  crosses JNI to the shared Swift `CameraWiFiScreenParser`, which alone validates/corrects Nikon
  SSID/key text. The operator reviews the result before it stages the ordinary Join action; no
  frame, OCR text, or key is logged or persisted until a successful join writes the existing
  Keystore-encrypted record. A connected session hands off to the monitor. Every wizard state is
  scriptable for screenshots: `adb shell am start -n com.opencapture.openzcine/.MainActivity
  --es zc.demo.pairing permissions|choose|prepare|network|discover|connecting
  --es zc.demo.pairingPath ap|hotspot|usb --es zc.demo.usbState
  empty|needs-permission|denied|ready` (debug builds only). The USB fixture visibly says
  `DEBUG FIXTURE — NOT USB HARDWARE`, never invokes Android USB permission, and never opens a
  physical transport. **[VERIFY-ON-HW]** A supported Nikon body, data cable, Android consent,
  `OpenSession` retry, and event flow still require a dedicated physical-camera pass.
  Android has its own stable PTP-IP initiator identity, so a camera previously paired only with
  iOS asks for a one-time Android pairing confirmation; later Android reconnects retain that
  profile without replacing the iOS pairing.
- **Swift core:** the camera brain is the shared Swift core (`Sources/OpenZCineCore`), cross-compiled
  to `libOpenZCineAndroid.so` and bound via JNI (`bridge/SwiftCore.kt` ↔
  `Sources/OpenZCineAndroidFacade`). Every Gradle debug/release build stages the optimized core and
  its dynamic Swift runtime closure into Gradle-owned `app/build/generated/` output; it never reads
  ignored `src/main/jniLibs/`. The one supported ABI is **arm64-v8a** (target triple
  `aarch64-unknown-linux-android29`, matching minSdk 29). Install Swift 6.3.3 and its matching
  `swift-6.3.3-RELEASE_android` SDK bundle locally; `just android-core` stages only, while
  `just android-release-check` also verifies the release APK and AAB contain every required `.so`.
  `just android-bridge-smoke <adb-serial>` installs the generated debug APK without clearing data
  and requires the `SwiftCoreSmoke` JNI core-version line on an arm64 device. CI and the Play
  workflow provision the same pinned toolchain/SDK before running Gradle.
- **Core seam:** `core-api/` is a pure-JVM module defining `CameraSession`, `LiveFrameSource`, and
  `CameraIdentity`; the Swift core plugs in behind it. Decision record:
  `docs/investigations/android-core-feasibility.md`.
- **Transport foundations:** `app/.../transport/` owns the platform byte layer — NSD/mDNS camera
  discovery (`CameraDiscovery` over an `NsdBrowser` seam, `_ptp._tcp`, plus the fixed camera-AP
  host), `PtpIpSocketTransport` (command + event TCP sockets, graceful half-close teardown,
  settle-then-backoff reconnect), and `AndroidUsbPtpCameraSource` (USB attach/detach, per-device
  permission, Still Image/PTP endpoint selection, interface claim, and raw bulk/interrupt I/O).
  Kotlin owns no PTP framing or Nikon policy: the Swift facade receives only raw USB bytes and
  performs generic-container transactions, session strategy, and event decoding. Detach and
  cancellation close the raw transport before the UI publishes stale discovery state. Debug hook
  to try the PTP-IP path live:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez openzcine.nsdTransport true`.
- **Camera session (Swift core):** `bridge/SwiftCoreCameraSession` implements the `CameraSession`
  seam over the Swift core's PTP-IP and USB generic-container session layers
  (`Sources/OpenZCineAndroidFacade/PTPIPClientSession.swift`): Init handshake, the Nikon
  open/pair/identify sequence, core-decoded property reads, live view, and graceful `CloseSession`
  teardown all run inside the `.so` — the facade owns the session sockets (decision record: the
  feasibility doc's "Where sockets go"). Live view is a Swift-side frame pump
  (`sessionStartLiveView` / `sessionStopLiveView`, latest-wins backpressure, absolute-schedule
  poll pacing) bridged into the `LiveFrameSource` seam by `bridge/SwiftCoreLiveFrameSource`;
  `MonitorScreen` streams a connected Swift-core session's frames automatically (gated on a
  STARTED lifecycle), and ending collection — disconnect or backgrounding — always sends
  `EndLiveView` (the heat-audit rule). Each frame can also carry optional stereo dBFS + peak-hold
  data resolved by the Swift core from the Nikon live-view sound indicator; Kotlin only presents
  that typed payload and never decodes header offsets or invents meter ballistics. Drive the real
  shell against a camera or fake server:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host <ipv4>`
  (logcat tag `SwiftCoreCameraSession`). For a fake-ZR server on the development Mac (scripted
  twin: `Tests/OpenZCineAndroidFacadeTests/FakeZRServer.swift`), forward the port with
  `adb reverse tcp:15740 tcp:15740` and use host `127.0.0.1`.
- **Live focus + level metadata:** optional AF/subject boxes and virtual-horizon angles stay paired
  with the JPEG frame through the Swift/JNI `LiveFrameSource` seam, so Compose draws them against
  the exact aspect-fit, locally de-squeezed feed rect rather than the larger monitor zone. View
  Assist offers Horizon and two-axis Gauge styles. A valid camera level always wins; only when it
  is absent does the monitor fall back to a visibly and accessibly labelled phone source:
  `DEVICE GRAVITY` for Android's fused gravity sensor or `DEVICE TILT` for a normalized low-pass
  accelerometer approximation. The SM-A127F hardware floor has no `TYPE_GRAVITY` sensor, so its
  physical fallback check covers the latter. Debug-frame metadata is visibly and semantically
  marked as a fixture, never as camera telemetry. Nikon-header calibration still requires a real
  camera pass.
- **Liquid-glass chrome:** monitor chrome glass is a custom GPU treatment (`GlassChrome.kt`) —
  one shared blurred backdrop texture per feed frame, sampled by every pill (AGSL edge refraction
  on API 33+, plain pre-blurred fill on 31–32, the hand-rolled flat fill below). A frame-budget
  counter auto-degrades one tier under sustained overruns. Debug override:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.glass.tier blur`
  (`full`/`blur`/`flat`; lowers only).
- **Scopes:** waveform, RGB parade, histogram, vectorscope, and Traffic Lights render from one
  monitor-owned ~10 Hz clean-frame sampler. The shared core owns all axis/curve and Traffic
  Lights decisions behind the facade (`Sources/OpenZCineAndroidFacade/ScopeFrameWire.swift` ↔
  `bridge/ScopeWire.kt`): the 3-anchor display axis (log-black floor → 5% crush line, fixed
  per-curve mid grey, clip warning → 95% line), tone-mapped vectorscope, and RGB goal-post
  direction/fill/clip/crush values come back as flat payloads. Kotlin reduces each JPEG once
  (1/2ⁿ decode to ≤160 px wide) and draws (`ScopeView.kt`). Scope tools toggle independently;
  landscape panels are draggable with per-scope persisted placement, while portrait displays the
  two most-recent active scopes in canonical order. The histogram carries the iOS-style RGB
  crush/clip edge blocks (default on) and a 95–100 IRE clip tint from that same Swift result.
  View Assist persists iOS's five-step crush/clip compensation selector (`0`, `¼`, `½`, `¾`,
  `1` stop) and forwards its raw value to Swift; Kotlin never remeasures the Traffic Lights
  result. Debug intent selections are
  comma-separated:

  ```sh
  adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true \\
    --es zc.scopes wave,parade,lights
  ```

- **Feed effects (view assists):** `FeedEffectsRenderer` bakes LUT preview, false colour,
  focus peaking, and zebras into the live feed in one AGSL pass. All colour math is baked in
  the shared Swift core (`Sources/OpenZCineAndroidFacade/FeedEffectsWire.swift` — cubes from
  `MonitorLUT`/`FalseColorMap`, thresholds from `ExposureSignalMapping`); Kotlin only uploads
  textures/uniforms and interpolates. Requires **API 33 (AGSL)** and the staged Swift core —
  below that the plain feed still renders (minSdk 29) and a warning is logged. The assist
  toolbar (`AssistToolbar.kt`) is the operator switch — LUT/PEAK/FALSE/ZEBRA plus five
  independently selectable scope pills, toggles persisted in SharedPreferences. The debug intent
  still seeds an exact session state for tests (intent beats persistence):
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true
  --es zc.assist lut,peaking,zebra --es zc.lut log3g10` (`zc.assist` also takes `falsecolor`,
  with `--es zc.fc.scale stops|ire`; false colour replaces the LUT, like iOS).
- **Live audio meters:** the trailing `AUDIO` assist toggle persists independently from image
  assists and scopes. In landscape it opens a draggable, normalized-placement stereo dBFS panel
  with the camera's peak markers and microphone-sensitivity readback; an absent camera sound
  indicator stays explicitly `NO DATA`. The debug feed is the only synthetic source and expands
  the panel to visibly say `DEBUG FIXTURE — NOT CAMERA AUDIO`; release builds cannot enable that
  feed. This is camera-header metering, not a phone-audio or decoded-playback tap.
- **Local framing assists:** Operator Setup → View Assist persists a monitor-only rule-of-thirds
  grid, centre crosshair, 2.39:1 / 16:9 delivery-frame guide, and horizontal anamorphic
  presentation choice. `FramingAssists.kt` composes them inside the existing shared-core feed
  zone; clean output retains delivery framing and de-squeeze presentation while hiding the busier
  grid and crosshair. These controls are explicitly local — they never write Nikon's camera-owned
  `GridDisplay` property.
- **Bluetooth / hardware media remote shutter:** Operator Setup → Controls has an **off by
  default** monitor-only media-remote switch. While a connected live monitor is frontmost and the
  activity is resumed, an Android `MediaSession` active only in that state maps Play/Pause or
  headset keys to a record toggle, Record/Play to start, and Pause/Stop to stop through the existing
  `CameraSession.setRecording` seam; it disarms for Settings, Media, backgrounding, a pending
  record confirmation or command, an in-flight camera control, and teardown. Android does not
  consistently identify the physical source of a media key, so this deliberately does not claim
  to distinguish Bluetooth from other hardware
  media controls. Phone volume keys are neither consumed nor changed, and a remote trigger skips
  the phone-side Record Confirmation dialog. Unit coverage verifies allowlisting, arm/disarm,
  duplicate-event debounce, and command routing. Hardware validation still needs a paired remote
  (both Play/Pause and headset forms), a repeated press, Settings/Media/background disarm, and a
  check that the phone's own volume keys behave normally.
- **Real-session diagnostics:** connect phases use the `SwiftCoreCameraSession` logcat tag and
  frame pacing uses `ZCLiveFeed`. For a
  fake-ZR server on the development Mac (scripted twin, incl. a synthesized live-view stream:
  `Tests/OpenZCineAndroidFacadeTests/FakeZRServer.swift`), run
  `ZC_FAKE_ZR_PORT=15740 swift test --filter servesFakeZRForDevice` at the repo root, forward the
  port with `adb reverse tcp:15740 tcp:15740`, and use host `127.0.0.1`.
- **Media browse + playback + stills:** the monitor's media button opens
  `media/MediaBrowseScreen`, an iOS-look dark media library with Camera and On device sources,
  All/Videos/Photos/Favorites filters, Newest/Oldest/Name sorting, persisted favorites, grid/list
  arrangements, long-press selection, and a grid sweep gesture. The Camera source is listed through
  the facade's bounded
  `sessionListMedia`/`sessionThumbnail` (`GetObjectHandles`/`GetObjectInfo`/`GetThumb`). MOV/MP4/M4V
  proxies open `MediaPlaybackScreen`; within the current filtered result it provides previous/next
  playable-proxy navigation, persisted favorite state, complete-cache-only native sharing,
  play/pause/replay and ±15-second transport, throttled preview plus final precise seeking,
  player-local mute with Media3 movie-audio focus, and 1×–4× pinch/pan. Its View Assist switch
  applies only the already-local framing/desqueeze overlay: the Media3 Surface does not expose
  decoded pixels or an audio tap, so LUT/false-colour/peaking/zebra, scopes, and audio meters are
  explicitly not represented as playback effects. JPEG/PNG stills open `MediaStillViewer`, which shows the
  camera thumbnail first, progressively refreshes a decoded cache preview, and supports 1×–4×
  pinch zoom/pan. HEIF/TIFF is attempted only after its complete cache publishes; unsupported
  HEIF decoders and Nikon RAW (`NEF`/`NRW`/`DNG`) remain an explicitly labelled camera-thumbnail
  fallback rather than a false full-preview claim. R3D masters remain non-previewable. The shared
  Swift core authoritatively classifies every browser action and still preview strategy before it
  crosses the facade wire, then selects standard `GetPartialObject` or Nikon's 64-bit
  `GetObjectSize`/`GetPartialObjectEx` path and pumps ordered 4 MiB chunks over JNI. Kotlin
  persists them below `noBackupFilesDir` in a
  resumable `.part` cache while Media3 reads the growing file; completion publishes the final file
  atomically. The still viewer uses the same generic cache and transfer seam; closing it invalidates
  late decode results and joins the active transfer before returning to the browser. Opening Media
  stops and excludes live view until the browser closes, so both pumps
  never contend for the serialized camera command channel. The On device source reads only a
  persisted shared-core listing and identity-validates each exact completed cache artifact; it never
  scans arbitrary filesystem paths or exposes partial files. One or more selected completed entries
  can be copied into app-scoped `cacheDir/share/ready` and opened through Android's native single or
  multi-item share chooser via a narrowly scoped `FileProvider`; the no-backup camera cache and
  growing `.part` files remain provider-invisible. Frame.io delivery uses that same finalized staging
  boundary: Settings → Storage owns Adobe PKCE sign-in, Android Keystore holds token/PKCE material,
  and multi-select media delivery creates a Frame.io file, streams each HTTPS upload part, then polls
  completion. The feature is intentionally unavailable until a maintainer supplies an approved Adobe
  Native App client ID and exact redirect URI through ignored/local build configuration; it never
  fabricates an identity. A camera-AP process binding hard-blocks cloud traffic rather than silently
  releasing camera control, and native Share remains an independent fallback. See
  [`docs/frameio-setup.md`](../../docs/frameio-setup.md) for the external **[VERIFY-ON-HW]** Adobe
  registration, browser callback, and real-upload checklist. The Nikon large-object operations still
  require real-ZR verification. For an on-device fake-ZR playback run, set
  `ZC_FAKE_ZR_MEDIA=/absolute/path/to/a/playable.mp4` alongside `ZC_FAKE_ZR_PORT=15740` when running
  `swift test --filter servesFakeZRForMediaBrowse`, then `adb reverse tcp:15740 tcp:15740`, launch
  with `--es zc.session.host 127.0.0.1`, and open `C0008.MOV`. The file is local-only and must stay
  under an ignored path; `ZC_FAKE_ZR_CLIPS=0` still serves the empty-card state.
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
