# OpenZCine Android

Production Jetpack Compose shell. The monitor screen is a 1:1 port of the iOS shell's
chrome, laid out by the shared core's zone map (`SwiftCore.monitorZoneMap` →
`MonitorZoneLayout.map`) in both orientations — no layout math lives in Kotlin. It covers
the live feed, top info deck, capture readout strip, the assist toolbar (wired to the
feed-effects engine + scope panels, toggles persisted), lock/battery band, the
record/DISP/media/settings controls with DISP 1→2→3 cycling (3 = the command dashboard),
and both persisted portrait feed layouts (sensor rotation; the activity survives it). A portrait
pinch snaps between fit 16:9 and fill at the same thresholds as iOS. The selected value enters
`SwiftCore.monitorZoneMap`, while the renderer, framing/focus/level overlays, capture-strip
clearance, stacked scopes, and fill-only vertical assist rail all consume those returned zones and
the same exact visible-image crop. DISP 3 observes the real Swift-core property snapshot, persists
its primary-tile order, and opens typed control pickers for ISO, shutter, iris, white balance,
exposure mode, focus, and supported audio settings. The same typed requests now drive anchored
ISO/shutter/iris/focus/WB pickers from the live monitor capture surfaces. A locked, pending, or
unreported control never becomes selectable. Resolution, codec, and VR/e-VR remain read-only until
camera descriptor options or write selectors are available. Without the staged Swift core the app
falls back to the placeholder monitor ("No camera") and every unavailable camera value is shown as
an em dash rather than a demo value. Debug portrait verification can seed the persisted state with
`--es zc.portraitAspect fit|fill`.

Android branding is mechanically derived from the iOS asset catalog, which is the source of truth:
`ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` supplies every normal, round, and
adaptive launcher surface, while `ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png` supplies
the startup splash. The adaptive foreground scales the complete AppIcon to 66 dp inside Android's
108 dp canvas and only extends its edge pixels into the maskable area, so no launcher shape crops
the mark. The splash places the byte-exact 512 px AppLogo at the centre of a transparent 288 dp
xxxhdpi canvas. AndroidX SplashScreen delegates that resource to the platform on API 31+ and renders
the same branded fallback on the app's API 29-30 floor before restoring the fullscreen,
edge-to-edge runtime theme. Do not replace either raster with an Android-specific redraw.

- **Build:** `just android-build` from the repo root (or `just android-check` for build + tests + lint).
- **Wear OS companion (OPE-67):** `wear-relay/` is a camera-free, pure Android wire module that
  mirrors the canonical Swift `WatchRelayProtocol.swift` v1 `[kind byte] + JSON` envelope and its
  golden fixtures. `wear/` is a non-standalone, foreground-only wrist monitor: it receives a
  bounded display-baked JPEG, camera timecode, measured frame cadence, honest phone monitor state,
  and one guarded record-toggle result through the Wear Data Layer. It declares no camera, network,
  Bluetooth, or storage permission. The handheld relay (`app/.../wear/`) consumes only the existing
  `LiveFeedView` presentation callback; it never creates a `LiveFrameSource`, touches pairing/saved
  cameras, or opens a direct camera/network path. The visible phone shader also renders the relay
  snapshot, so LUT, false colour, peaking, and zebra do not disappear on the wrist. Up to three
  previews are in flight, matching watchOS; watch-receipt acknowledgements measure actual round-trip
  latency and adapt JPEG width, quality, and cadence while retaining only the freshest waiting
  frame. The Wear launcher density variants are mechanical resizes of
  `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`, and its launch screen uses
  mechanical resizes of `ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png`; there is no
  Wear-specific redraw. When the phone backgrounds or leaves the monitor, the pump is invalidated
  and an explicit disconnected snapshot is published. A resumed watch clears its frame/state cache,
  requires a fresh two-second phone heartbeat, and expires state after six seconds. Capability
  reachability proves only companion
  reachability, never a camera or foreground monitor. Record commands use a v1 request-ID path
  suffix solely for reply correlation; their payload remains canonical and reaches the same phone
  `CameraSession.setRecording` seam after monitor/lifecycle/session/pending-work gates pass. Like
  watchOS, Record remains available while the phone is in Command mode and its feed is paused. The
  animated control provides click, success, and failure haptics; timecode and side readouts auto-fit
  with round-screen corner padding. Both capability declarations are retained by dedicated raw
  `tools:keep` files (and their `values/wear.xml` declarations), and the Wear manifest sets
  `com.google.android.wearable.standalone=false`. Phone and Wear release artifacts share the
  `com.opencapture.openzcine` package and signing configuration, but the Wear bundle receives a
  collision-free version-code offset and uploads to Play's dedicated Wear track. Run
  `just android-check` for JVM wire/lifecycle coverage and `just android-release-check` for the
  phone/Wear package, signer, capability, and AAB checks.
  **[VERIFY-ON-HW]** No Wear emulator or physical watch was used here: pair a signed phone/watch
  build, open the phone monitor, confirm display-baked preview, timecode/FPS/state/record correlation
  and acknowledgement adaptation, exercise Command-mode recording, background or leave the monitor
  to confirm the wrist UI becomes unavailable, resume to confirm it waits for a fresh heartbeat,
  feel all haptic outcomes, and inspect the tightest round/square watch layout for clipping.
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
  `EndLiveView` (the heat-audit rule). DISP 3 has no frame, audio, scope, or health collector, so
  opening the command dashboard also releases the disposable live-view pump. Each frame can also
  carry optional stereo dBFS + peak-hold
  data resolved by the Swift core from the Nikon live-view sound indicator; Kotlin only presents
  that typed payload and never decodes header offsets or invents meter ballistics. Drive the real
  shell against a camera or fake server:
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host <ipv4>`
  (logcat tag `SwiftCoreCameraSession`). For a fake-ZR server on the development Mac (scripted
  twin: `Tests/OpenZCineAndroidFacadeTests/FakeZRServer.swift`), forward the port with
  `adb reverse tcp:15740 tcp:15740` and use host `127.0.0.1`.
- **Link health + preview policy:** Operator Setup → Link presents the same shared Swift
  `CameraLinkHealthScorer`/`LinkSignalBars` result as iOS, fed only by the Android session state,
  delivered native live-view frames, and observed property-refresh transport failures. The current
  facade has no RTT measurement, so it sends `null` rather than inventing a radio value; a requested
  stream that never produces its first frame ages into recovery. Stream Preset and Quality Bias are
  app-local operator intent. `AndroidLiveViewPolicyWire` resolves them with the shared thermal and
  recording caps before `PTPIPClientSession` writes only `LiveViewImageSize` and
  `LiveViewImageCompression` before a preview-pump restart; the cadence changes only Android's
  disposable `GetLiveViewImageEx` pulls. Android `PowerManager` severe/critical status reduces that
  preview request, never a camera recording format, frame rate, codec, or card write. Link-tab
  preview application reports pending, confirmed, or rejected state; a rejected request starts no
  new pump unless the last confirmed request can be restored, and health excludes replay from a
  former stream generation. Link-tab Disconnect/Reconnect returns through `SavedCamerasExperience`,
  the existing profile-scoped owner of camera-AP, hotspot, and USB cleanup. An explicit USB
  Disconnect remains on saved-camera home until the physical body detaches/replugs or the operator
  explicitly reconnects. **[VERIFY-ON-HW]** Test the size/compression selectors,
  camera warning behavior (only explicit `HOT` currently triggers the strict cap), and a thermal
  soak with a supported Nikon camera; no generic `WARNING` bit is treated as overheating.
- **Live focus + level metadata:** optional AF/subject boxes and virtual-horizon angles stay paired
  with the JPEG frame through the Swift/JNI `LiveFrameSource` seam, so Compose draws them against
  the exact fit or centre-cropped fill, locally de-squeezed feed rect rather than the larger
  monitor zone. View
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
  monitor-owned clean-frame sampler at 30 Hz (24 Hz above three active scopes), with the same
  thermal slowdown tiers as iOS. The shared core owns all axis/curve and Traffic
  Lights decisions behind the facade (`Sources/OpenZCineAndroidFacade/ScopeFrameWire.swift` ↔
  `bridge/ScopeWire.kt`): the 3-anchor display axis (log-black floor → 5% crush line, fixed
  per-curve mid grey, clip warning → 95% line), tone-mapped vectorscope, and RGB goal-post
  direction/fill/clip/crush values come back as flat payloads. The active camera codec/base ISO
  resolves the curve and current clip in Swift before both renderer and scopes consume it. Kotlin
  reduces each JPEG once (1/2ⁿ decode to ≤160 px wide) and draws (`ScopeView.kt`). Scope tools
  toggle independently; landscape panels are draggable with per-scope persisted placement, while
  portrait displays the two most-recent active scopes in canonical order. Operator Setup persists
  the iOS-equivalent waveform/parade mode, guides, brightness, footprint, vectorscope zoom, and
  histogram/Traffic Lights footprint; Kotlin does not duplicate any signal math. The histogram
  carries the iOS-style RGB crush/clip edge blocks (default on) and a 95–100 IRE clip tint from
  that same Swift result. View Assist persists iOS's five-step crush/clip compensation selector
  (`0`, `¼`, `½`, `¾`, `1` stop) and forwards its raw value to Swift; Kotlin never remeasures the
  Traffic Lights result. Debug intent selections are
  comma-separated:

  ```sh
  adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true \\
    --es zc.scopes wave,parade,lights
  ```

- **Feed effects (view assists):** `FeedEffectsRenderer` bakes LUT preview, false colour,
  focus peaking, and zebras into the live feed in one AGSL pass. All colour math is resolved by
  the shared Swift core (`Sources/OpenZCineAndroidFacade/FeedEffectsWire.swift`): camera-aware
  curve/clip mapping, LUT and false-colour cubes, Limits paint/weight overlays, peaking thresholds
  and RGB, zebra code thresholds, and stripe RGB values. Kotlin only uploads textures/uniforms,
  interpolates, and samples the clean source once. LUT and false-color activation remain
  independent exactly as on iOS: Stops/IRE false color has renderer precedence over the LUT,
  Limits overlays the active LUT, and turning false color off resumes that LUT. The false-color
  reference key is on by default and uses the same Swift palette. Requires **API 33 (AGSL)** and
  the staged Swift core — below that the plain feed still renders (minSdk 29) and a warning is
  logged. The assist toolbar (`AssistToolbar.kt`) is the operator switch — LUT/PEAK/FALSE/ZEBRA
  plus five independently selectable scope pills, toggles persisted in SharedPreferences. The
  debug intent still seeds an exact session state for tests (intent beats persistence):
  `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true
  --es zc.assist lut,peaking,zebra --es zc.lut log3g10` (`zc.assist` also takes `falsecolor`,
  with `--es zc.fc.scale stops|ire|limits`).
- **Custom LUT library:** Operator Setup → View Assist opens a one-document Android picker for
  operator-selected `.cube` files. The picker URI is used only for that read: Android bounds it to
  16 MiB, asks the shared Swift core to enforce strict UTF-8/`.cube` validation and pack the
  existing renderer texture, then atomically writes an app-private copy below
  `noBackupFilesDir/lut-library-v1/` with a generated safe name. It neither scans shared storage
  nor persists a document URI, source path, provider identifier, or original file name. The
  persisted selection is only the generated category/file identity; a missing, oversized, or
  corrupt private copy fails closed to the plain feed until the operator removes or reimports it.
  The 16 MiB limit is `CubeLUT.maximumSourceBytes`, shared with iOS and the JNI boundary.
- **RED IPP2 LUTs:** no RED LUT asset, scraper, guessed endpoint, or demo download exists in the
  Android app. The View Assist status card evaluates the real process-bound camera-AP/internet
  route through the shared `RedLUTDownloadPolicy`, but delivery remains blocked until RED
  authorizes an Android HTTPS endpoint and terms flow (including a terms revision and operator
  acknowledgement). **[VERIFY-ON-HW]** Before enabling that integration, validate authorization,
  terms acknowledgement, authenticated download, camera-AP blocking, and imported-LUT rendering
  on an arm64 Android device; do not substitute fixture assets or a guessed RED URL.
- **Live audio meters:** the trailing `AUDIO` assist toggle persists independently from image
  assists and scopes. In landscape it opens a draggable, normalized-placement stereo dBFS panel
  with the camera's peak markers and microphone-sensitivity readback; an absent camera sound
  indicator stays explicitly `NO DATA`. The debug feed is the only synthetic source and expands
  the panel to visibly say `DEBUG FIXTURE — NOT CAMERA AUDIO`; release builds cannot enable that
  feed. This is camera-header metering, not a phone-audio or decoded-playback tap.
- **Local framing assists:** Operator Setup → View Assist persists monitor-only, multi-select
  Film/Social delivery frames with optional outside masking; independent thirds, phi, and diagonal
  grids; a centre crosshair; and 1×–2× horizontal or vertical de-squeeze. `FramingAssists.kt`
  resolves the live overlay against the decoded image's exact fit/fill content rectangle. Clean
  output retains delivery framing, masking, and de-squeeze while hiding the busier grids and
  crosshair. These controls are explicitly local; they never write Nikon's camera-owned
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
  playable-proxy navigation, persisted favorite state, complete-cache-only native delivery,
  play/pause/replay and ±15-second transport, throttled preview plus final precise seeking,
  player-local mute with Media3 movie-audio focus, 1×–4× pinch/pan, tap-to-toggle transport,
  and long-press frame scrubbing. Its playback-only View Assist toolbar persists independently
  from the live monitor and applies LUT, false colour, peaking, zebra, framing/desqueeze, and
  false-colour reference overlays to Media3's `TextureView`. Waveform and vectorscope panels
  sample the decoded texture before those display effects, preserving clean-source analysis.
  Tapping a toolbar tool still toggles only playback visibility. Long-pressing a configurable tool
  opens a compact panel anchored above that toolbar, with outside-tap and Back dismissal plus
  TalkBack long-click semantics. The panels reuse the live operator's LUT, false-colour, peaking,
  zebra, scope, and framing configuration without copying persistence; audio remains tap-only
  because the iOS playback meter has no operator options.
  A passthrough Media3 PCM processor meters decoded movie audio through the shared Swift dBFS
  ballistics and continues metering when only player output is muted. JPEG/PNG stills open
  `MediaStillViewer`, which shows the
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
  growing `.part` files remain provider-invisible. The shared **Deliver** chooser keeps Android's
  native Share flow separate from **Save to Gallery**. Gallery delivery accepts only verified
  MOV/MP4/M4V videos, writes sequentially to scoped `MediaStore.Video` rows under
  `Movies/OpenZCine`, and clears `IS_PENDING` only after the exact staged byte count is copied.
  Failed or cancelled writes delete only the row created for that attempt. Batch results retain the
  current selection when any video fails or any non-video, incomplete, or unprepared item is skipped,
  so the operator can correct or retry without losing context. This API 29+ path does not request
  broad storage access and never scans, modifies, or deletes unrelated media. Frame.io delivery uses
  that same finalized staging boundary: Settings → Storage owns Adobe PKCE sign-in, Android Keystore
  holds token/PKCE material, and multi-select media delivery creates a Frame.io file, streams each
  HTTPS upload part, then polls completion. A per-run option can apply the currently selected approved
  monitor LUT to a transient H.264/AAC MP4 with Media3 Transformer; the staged original stays
  read-only and the temporary export is removed after the attempt. An optional, bounded app-private
  metadata sidecar is written only after Frame.io confirms the upload, without OAuth values, cloud
  identifiers, or upload URLs. The feature is intentionally unavailable until a maintainer supplies
  an approved Adobe Native App client ID and exact redirect URI through ignored/local build
  configuration; it never fabricates an identity. While a real saved Nikon camera-AP session is
  active, cloud delivery requires a second explicit confirmation before OpenZCine disconnects the
  session and releases its process binding. The delivery context stays mounted while Android waits
  for validated internet, and every completion, cancellation, or timeout attempts to rejoin the exact
  saved profile. The UI reports **Camera rejoined** only after a fresh protocol-connected session;
  fixtures and incomplete saved profiles cannot use the hop. Native Share remains an independent
  fallback. See
  [`docs/frameio-setup.md`](../../docs/frameio-setup.md) for the external **[VERIFY-ON-HW]** Adobe
  registration, browser callback, and real-upload checklist. The Nikon large-object operations still
  require real-ZR verification. For an on-device fake-ZR playback run, set
  `ZC_FAKE_ZR_MEDIA=/absolute/path/to/a/playable.mp4` alongside `ZC_FAKE_ZR_PORT=15740` when running
  `swift test --filter servesFakeZRForMediaBrowse`, then `adb reverse tcp:15740 tcp:15740`, launch
  with `--es zc.session.host 127.0.0.1`, and open `C0008.MOV`. The file is local-only and must stay
  under an ignored path; `ZC_FAKE_ZR_CLIPS=0` still serves the empty-card state. Debug builds can
  exercise pending-row cleanup with `--es zc.gallery.failOnce write`: the first Gallery write after
  insertion fails, its pending row is deleted, and a retry through the same screen can succeed. The
  release harness ignores this extra.
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
