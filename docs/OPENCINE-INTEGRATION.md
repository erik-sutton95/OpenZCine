# OpenCine integration candidate (Nikon)

Local candidate branch `opencine/integration`, based on `origin/main` 9ac41387. Not pushed, not
hardware-qualified. It combines the OpenCine work packages that apply to the shipping app.

## Contents

| Work package | Branch | Tip |
| --- | --- | --- |
| CORE-02 (Nikon adapter on OpenCineCore) + CORE-01b update | `opencine/core-02-nikon` | 6bce2301 |
| STATE-01 (Nikon session ownership) | `opencine/state-01-nikon` (on core-02) | 8de98639 |
| MEDIA-01 (CubeLUT, FrameRateSampler from OpenCineMedia) | `opencine/media-01` | `ba1e340b9435e1de9b6f14d355ca3256f4a8e299` |
| VENDOR-02 (Runner links OpenZCineCore; Nikon code in OpenCineNikon) | `opencine/vendor-02-nikon` (on integration) | see branch |
| OPTIONAL-01 (Frame.io from OpenCineFrameIO) | `opencine/frameio` (on integration) | see branch |
| MEDIA-02 step 4 (HDMI/UVC capture source from OpenCineApple) | `opencine/apple` (on integration) | see branch |
| NIKON-01 (shared monitor UI and multicam from OpenCine) | `opencine/nikon-01` (on integration) | see branch |
| SHELL-04 Nikon (Android session and JNI facade, iOS PTP transports, JPEG leases in OpenCine) | `opencine/shell-04` (on integration) | see branch |
| SHELL-02 step 9 (cameras and pairing on OpenCine's shared flow, discovery from `NikonDiscovery`) | `opencine/shell-02` (on integration) | see branch |

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
`AndroidSessionOwnerRegistry` moved to OpenCine later (SHELL-04, below).

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
glue. The JPEG `FrameDecoder` / Metal live view were app runtime then (see SHELL-04 below for the
hardware JPEG decode). Pinned to OpenCineCore's
`apple` branch until it merges to Core main.

NIKON-01: the app takes the shared monitor UI and the multicam engine from `../OpenCine` instead of
copying them. iOS: the Runner links `MonitorUI`, `MonitorPresentation` and `OpenCineMulticam`, and
`AppDelegate` sets `MonitorTheme.accentRGB` to the OpenZCine gold. Android: the app depends on
`com.opencapture.opencine:monitor-ui` and `:multicam` from the same included build (the catalog
moved to OpenCine's AGP 9.4.1, Kotlin 2.4.20, Compose BOM 2026.09.00 and compileSdk 37, because a
composite build cannot load two Android Gradle plugins), and `OpenZCineTheme` sets
`MonitorPalette.accent` and turns `MonitorIosParity` on. Multicam is new on both platforms (see
below). It re-implements the multi-Nikon-Z learnings of the engine-port branch on the shared
engine instead of merging that branch: eligibility and serial identity in OpenCineNikon
`NikonMulticamPolicy`, each member's command queue with readback in `NikonMemberControl`, group
record as an eligible-subset `RecordPlan`, the Live View loan as an `EditorLease`, the four-camera
limit as the app's `ResourceBudget`. Your cameras, pairing, the single-camera monitor, Operator
Setup and media keep OpenZCine's own UI for now: moving them onto the shared pages is SHELL-02
(cameras and pairing) and SHELL-03 (app shell) work. The engine-port branch and its UI candidate
(`opencine/ui-03-engine-port-candidate`) are not merged and are left as they were.

SHELL-04 (Android): the Nikon session moved to OpenCine. Kotlin: the session contract
(`CameraSession`, `LiveFrameSource`, `FakeCameraSession`, formerly `core-api`), the production
session over the Swift layer (`SwiftCoreCameraSession`, `SwiftCoreLiveFrameSource`), the property
and metadata wires, ISO and white-balance picker policy, the initiator identity, the
`UsbPtpTransport` seam and `NikonOpenCineSession` are the `com.opencapture.opencine:nikon` module
(package `com.opencapture.opencine.nikon`) from the same included build. Its JNI class is
`NikonNative` (44 session, media, link health, recovery and camera Wi-Fi natives); `SwiftCore`
keeps the app's own 29 (scopes, feed effects, LUTs, Frame.io, zone map, audio meter, live-view
preferences). Swift: `PTPIPClientSession`, the USB transaction transport,
`AndroidSessionOwnerRegistry`, media browse and the `NikonNative` exports are OpenCine's
`OpenCineNikonAndroid`, linked into `libOpenZCineAndroid.so` with the JNI helpers of
`OpenCineJNISupport` (over OpenCine's `OpenCineJNI` header; the app's `CJNI` target is gone). `SwiftCore.isAvailable` loads the library through
`NikonNative.load`, and `MainActivity` touches it first. `core-api` keeps only the monitor
availability, relay lease and relay encoder profile. Release keep rules for the moved classes ship
in the module (`consumer-rules.pro`). `stageSwiftCore` also fingerprints
`Sources/OpenCineNikonAndroid/**`, `Sources/OpenCineJNISupport/**` and `Sources/OpenCineJNI/**`.

SHELL-04 (iOS): the PTP/IP transport (`PTPIPTransport`, BSD sockets, behind
`#if canImport(Darwin)`) and the USB-C transport (`USBCameraDeviceBrowser`,
`USBCameraTransport`, `DeviceUSBConnector`, ImageCaptureCore, `#if os(iOS)`) moved from
`ios/Runner` into OpenCine's `OpenCineNikon` with `NativeCameraSessionError`; the Android build
compiles them out. The Runner reaches them through `OpenZCineCore` as before. Two app couplings
became hooks that `AppDelegate` sets at launch: `PTPIPTransport.connectionLog` (the liveness-probe
line goes to `logConnection`) and `USBCameraDeviceBrowser.shared.onEvent` (USB authorization,
attach and detach go to the diagnostics journal with the same event names). Their Console
subsystem is now `OpenCineNikon` (categories `camera-connection` and `camera-usb` unchanged).
`NativeCameraSession` (session orchestration and the saved-camera store) stays in the app.

SHELL-04 (JPEG live view): the hardware motion-JPEG decoder (`JPEGPixelBufferDecoder`,
VideoToolbox to `420v`) moved to OpenCine's `OpenCineApple` and lends each frame as a
`DecodedFrameLease` stamped by its `DecodedFrameFence`. `FrameDecoder` advances the fence when a
live view starts (`resetProcessors`), publishes each lease through it, applies the denoise filter
and renders to `UIImage` as before, then releases the lease. The CPU fallback, super resolution,
the denoise filter and `MetalLiveView` (still fed a `UIImage`) stay in the app. Android has no
Kotlin decoded-frame lease yet, so its JPEG path is unchanged.

SHELL-02 step 9: iOS and Android link OpenCine's `OpenCineAppKit` / `:appkit` and run their
cameras page and pair page on `CamerasModel` with OpenCineNikon's `NikonIntegration`. The app
implements `NikonConnectPort` over its own discovery loop and connect funnel (iOS
`NikonCamerasFlow.swift`: `NativeNikonPort`; Android `AppNikonConnectPort` over
`SavedCameraConnector`), so connect, pairing and save rules are unchanged; the integration types
failures, maps phases to card steps and asks before taking over a held camera. Discovery is
OpenCine's `NikonDiscovery` (iOS `PosixNikonDialer`, Android `SocketNikonDialer`): `.passive` for
the cameras page (Bonjour/NSD, USB, presence and liveness on 15741; never the PTP/IP port),
`.active` only while pairing or for an armed setup watch. The saved-camera document is stored next
to the app's records and merged on every launch and after every app write (`NikonSavedRecordsV0`).
Replaced and deleted: iOS `ConnectionProgressSheet.swift`, the saved-cameras list, rows and editor
in `StartupDesign.swift`, the app's own discovery service; Android `SavedCamerasExperience.kt`,
`ConnectionProgressPopup.kt` and the wizard's own frame in `PairingExperience.kt`.

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

- Multicam (NIKON-01, iOS and Android): new. Your cameras has a Multicam control (grid button) that
  opens an empty stage of four tiles. Add up to four bodies over USB-C, a router or this phone's
  hotspot; a camera's own access point, an HDMI setup, an unreachable setup or a fifth camera is
  refused with a reason. Every tile shows name, battery, timecode and REC/STBY; the selected
  camera's ISO, shutter, white balance and focus sit under or inside its tile, and ISO and white
  balance can be changed there (that camera only, confirmed by reading it back). One Record button
  starts or stops every eligible camera; each tile reports its own result, a mixed start says
  "2 of 3 rolling. C didn't start.", and nothing is stopped because another camera failed.
  Double-tap (or long-press, Open Live View) opens that camera's full Live View on its open link;
  Return to Multicam in the lock slot hands it back without reconnecting. Closing the stage closes
  every link and never stops a recording.
- Shared monitor UI (NIKON-01): no visible change outside multicam on iOS (simulator screenshots of
  first launch, live view, Operator Setup and media are unchanged). Android takes the shared
  monitor-ui with its iOS-look switch on; only multicam uses it so far.

- Your cameras and pairing (SHELL-02, iOS and Android): the cameras page is OpenCine's shared page.
  One card per body (iOS groups setups by serial, Android by camera name) with a chip per setup,
  Add setup, rename and forget; NEARBY lists cameras "on this network" that are not saved, feeds
  other devices share and the filtered-network notice; Multicam, Media and Settings sit in the
  header. A connect shows its steps, prompts and a typed failure on the card (Try again, Take
  over for a camera another device holds, Share diagnostics) instead of the full-screen
  progress card. The pairing wizard runs on the shared pair page (its steps in the rail, the step
  in the pane), and a connect the app starts itself (the wizard's, a camera Wi-Fi join, the
  internet-hop rejoin) shows its progress, the scanned network and key to confirm, a manual
  address entry and its failure on that page. Saved setups move to OpenCine's saved-camera
  document (iOS `OpenZCine.Cameras`, Android prefs `openzcine.cameras`/`document`); the app's own
  records stay where every older build reads them and are kept in step both ways. Wi-Fi keys,
  the pairing identity and paired-host memory are untouched. Not on the shared cards any more:
  the camera border color and icon (kept in the records), renaming one setup (names are kept and
  shown), and the Privacy/Terms links on the startup screens (still in Settings).

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

12. NIKON-01 single camera (iOS and Android): connect over Wi-Fi and USB-C, live view, ISO, WB,
    record with confirmation, media, Operator Setup. Nothing should differ from
    `opencine/integration` except the Multicam control on Your cameras.
13. NIKON-01 multicam with two, three and four Z bodies (ZR plus at least one other Z model; mix
    USB-C through a hub, a router and the phone's hotspot): add each from the stage, check name,
    battery, timecode and picture on every tile in Grid and Center stage, portrait and landscape.
    Try to add a camera-AP setup, an unplugged USB body, the same body over a second setup (it
    must be refused or dropped with "That camera is already on the stage.") and a fifth camera.
    Unplug one USB member and drop one Wi-Fi member: that tile shows Connection lost with Retry,
    the others keep streaming, Retry brings it back.
14. NIKON-01 borrow and return: open a member's Live View (double-tap, or long-press then Open
    Live View), change ISO, record and stop there, then Return to Multicam: the tile resumes
    without reconnecting, the camera never shows a new pairing or session prompt, and the other
    members kept streaming meanwhile. Leave Live View with Disconnect too: it must return to the
    stage, not close the camera.
15. NIKON-01 group record: with confirmation on and off, start all; remove the card from one body
    first: that tile says Couldn't rec, the toast says "N of M rolling. X didn't start.", the
    others keep rolling. Stop all: only rolling cameras get a stop. A body already rolling when
    added is counted, not restarted. Close the stage while recording: every camera keeps rolling.
16. NIKON-01 settings writes: change ISO and WB of the selected camera from the stage values row on
    two different members in quick succession: only the selected camera changes, its tile reads
    the camera's value back, a refused or clamped value shows "ISO not applied" / "WB not
    applied". Under thermal pressure only non-selected tiles slow down (iOS).
17. NIKON-01 Android parity: Android stage and Return to Multicam behave like iOS; the existing
    Android screens look as before (`MonitorIosParity` affects only shared monitor-ui pieces,
    which only multicam uses so far). Compare picture smoothness and phone temperature with four
    tiles for 20 min on both platforms.
18. SHELL-04 Android (no intended behavior change; the Nikon session code moved to OpenCine):
    connect over the camera access point, router Wi-Fi and USB-C (fresh pairing and a saved
    profile); live view starts and keeps running for 10 min; record start and stop; ISO, WB,
    shutter, iris and focus mode writes read back; tap focus and reset; media browse, thumbnails,
    rating, delete, transfer and share; Wi-Fi credential scan and manual entry; pull the USB cable
    and reconnect; reconnect after a Wi-Fi drop (attempt N of M, drop storm pause). Install the
    signed release build for this item, since R8 keeps the moved JNI classes only through the
    module's rules.
19. SHELL-04 iOS transports (no intended behavior change): connect over the camera access point,
    router Wi-Fi and USB-C (iPhone and iPad); first-time pairing and a saved profile; live view
    10 min; record; settings writes; media browse; pull the USB-C cable while live (the monitor
    recovers); deny then grant USB camera access in Settings; a Bug Report after these shows
    `usb.authorization.*`, `usb.camera.attached` and `usb.camera.detached` events.
20. SHELL-04 JPEG live view (iOS, no intended behavior change): the live picture and its frame
    rate over Wi-Fi and USB-C match the previous build; denoise on and off; the debug key shows
    `hw 420v` (or the native format) as the decode path; scopes and peaking still read the clean
    frame; stop and start live view and switch cameras ten times with no stale frame flashing up.

21. SHELL-02 cameras page (iOS and Android): connect each saved setup from its chip (camera Wi-Fi,
    router, hotspot, USB-C); the card shows the steps and a failure with Try again; rename a
    camera; forget one setup (an access point setup takes its Wi-Fi key with it) and a whole
    camera; Add setup of each kind (USB-C waits for the plug, router finds the camera on this
    network, hotspot waits for the camera, camera Wi-Fi joins with the stored key or scans it).
    Several bodies, and one body over USB-C and router at once, show as one card each.
22. SHELL-02 pairing on the shared pair page: every wizard path (camera Wi-Fi with the OCR scan and
    a corrected key, router including the manual address after an empty search, hotspot, USB-C,
    HDMI on iPad); confirm the PIN on the camera and the access point restart; Cancel and Back at
    each step; a failure, Try again and Share diagnostics. A NEARBY camera's Pair connects it on the
    pair page.
23. SHELL-02 held camera: with a second phone live on a body, the first phone's card and NEARBY row
    say it is in use; Take over asks first, and the second phone's session ends only after Take
    over is confirmed.
24. SHELL-02 Multicam from the cameras page header (2 bodies; on Android tap the Multiview button
    at its edges too, the whole drawn button must open it), and Watch a nearby broadcast.
25. SHELL-02 upgrade: install the current TestFlight or Play build, save three cameras (one with
    two setups, one camera Wi-Fi setup with its key, one renamed, one named setup), then install
    this build: every camera, setup, name and date is there, camera Wi-Fi reconnects with no key
    prompt and no new PIN. Install the old build again, rename and forget something there, then
    this build again: the old build's edits show and nothing else is lost.
26. SHELL-02 passive check: open the cameras page and leave it for 2 min with no connect running.
    A packet capture of the phone (iOS `rvictl -s <UDID>` plus Wireshark; Android via the router
    or a hotspot capture) shows mDNS and TCP SYNs to port 15741 only (presence and liveness), no
    TCP to 15740 and no PTP/IP bytes from the phone. A second phone's live session on the same
    body survives the whole time.
27. Multicam stage safe area (iOS): on an iPhone 16 Pro, run multicam in both landscapes; the
    Grid/Center toggle and Exit stay clear of the Dynamic Island and respond to taps, and the
    camera strip does not run under the island.
28. SHELL-02 setup names (iOS and Android): long-press a setup chip, including a camera with
    only one setup, rename it, then reopen the app. The name stays on that setup only. Clear
    the name and save: the normal setup label returns. Cancel keeps the previous name. Repeat
    the old-build/new-build installation cycle in item 25 with a setup renamed on the old
    build, then with its name cleared there. Both edits survive repeated new-build launches;
    other routes, camera names, pairing identity and Wi-Fi keys stay intact.
29. SHELL-02 legal links (iOS and Android): Privacy and Terms open the existing policy pages
    from Cameras and Pair, including first-run pairing and pairing a nearby camera. Returning
    to the app leaves the selected pairing step intact.

### Multiview qualification checks (SHELL-01, untested on physical devices)

On iPhone/iPad and Android, fill the four slots using the existing qualified USB-C,
router and hotspot paths. A fifth camera must be refused. Try a second saved path
to the same body, a camera access point, an unreachable setup and, on iPad, HDMI:
their existing refusal messages must remain. Enter movie mode and record only
after confirming the group plan; leave Multicam while a body records and confirm
it keeps recording. Passive discovery must remain passive throughout.

The app's `ResourceBudget(qualifiedEntries: 4)` now supplies the tile limit. The
integration's typed saved-path qualification and resource admission produce one
admission result. Saved-path qualification before connect does not invent a
camera mode or serial: reported body identity and recording eligibility still
apply after connect. USB-C/router/hotspot combinations retain the existing
qualification policy; this change qualifies no new hardware combination.

### Device performance baselines (SHELL-04)

Record each number before (on `opencine/integration` before SHELL-04) and after, same phone,
same body, same settings, room temperature, battery above 50 %. iOS and Android.

1. Latency, glass to glass: film a running stopwatch with the camera and photograph the stopwatch
   and the monitor together; median of 10 readings, one feed, Wi-Fi and USB-C.
2. Memory: app memory after 1 min and after 30 min of live view with a LUT and a waveform on
   (Xcode memory gauge; Android `dumpsys meminfo com.opencapture.openzcine`).
3. Thermal: phone thermal state (iOS) or `dumpsys thermalservice` status (Android) and the
   camera's temperature warning after 20 min of live view while recording.
4. Two feeds: multicam with 2 bodies for 20 min: frame rate per tile (link health panel),
   memory and thermal as above, any feed stall or reconnect.
5. Four feeds: the same with 4 bodies.

## Before this can ship

The OpenCine platform repository must be published first (the sibling path becomes SwiftPM url +
version and Maven coordinates). The steps are in `OpenCine/atlas/docs/PUBLISH.md`.
