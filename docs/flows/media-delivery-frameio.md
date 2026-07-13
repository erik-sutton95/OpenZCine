# Flow: Media delivery — Share & Frame.io

Export cached (or on-camera) clips via the system share sheet or upload to Frame.io. Progress
survives navigation through `MediaDeliveryCoordinator`; on the camera AP, Frame.io work hops off
the camera Wi‑Fi and rejoins when done. Every box below has a node card with implementation
detail; edit anything, Claude picks it up from the diff.

```mermaid
flowchart TD
  FRAME-01["FRAME-01\nSettings sign-in\n(prerequisite)"] -.->|unlocks| DELIVERY-02

  DELIVERY-01["DELIVERY-01\nTrigger Share popup\n(grid or player)"] --> DELIVERY-02["DELIVERY-02\nPick destination\n(Share / Frame.io)"]

  DELIVERY-02 -->|Share| DELIVERY-03["DELIVERY-03\nShare options\n(LUT, format, metadata)"]
  DELIVERY-02 -->|Frame.io| FRAME-02["FRAME-02\nFrame.io options\n(project + export toggles)"]

  FRAME-02 -->|on camera AP\n(whole option gated)| FRAME-03["FRAME-03\nConsent: hop\nto internet"]
  FRAME-03 -->|Hop| FRAME-04["FRAME-04\nPost-hop resume\n(popup reopens)"]
  FRAME-04 --> FRAME-02
  FRAME-03 -->|Cancel| DELIVERY-FAILED-01["DELIVERY-FAILED-01\nDismiss popup\n(rejoin if hopped)"]

  DELIVERY-03 --> DELIVERY-05["DELIVERY-05\nBegin delivery\n(runner task)"]
  FRAME-02 --> DELIVERY-05

  DELIVERY-05 --> DELIVERY-06["DELIVERY-06\nCache from camera\n(sequential PTP)"]
  DELIVERY-06 -->|nothing cached| DELIVERY-FAILED-01
  DELIVERY-06 -->|Share| DELIVERY-07["DELIVERY-07\nPrepare exports\n(LUT bake / copy)"]
  DELIVERY-06 -->|Frame.io + on AP| FRAME-05["FRAME-05\nInternet hop\n(wait for path)"]
  DELIVERY-06 -->|Frame.io + online| FRAME-06

  FRAME-05 -->|online| FRAME-06["FRAME-06\nUpload batch\n(per clip)"]
  FRAME-05 -->|timeout| FRAME-FAILED-01["FRAME-FAILED-01\nHop failed\n(rejoin + error)"]

  DELIVERY-07 -->|systemShare| DELIVERY-08["DELIVERY-08\nShare sheet\n(UIActivityViewController)"]
  DELIVERY-07 -->|saveToPhotos| DELIVERY-09["DELIVERY-09\nSave to Photos\n(PHPhotoLibrary)"]
  DELIVERY-07 -->|export failed| DELIVERY-FAILED-01
  DELIVERY-08 --> DELIVERY-10["DELIVERY-10\nShare complete toast"]
  DELIVERY-09 --> DELIVERY-10

  FRAME-06 --> FRAME-07["FRAME-07\nPer-clip pipeline\n(prepare → API → S3 → poll)"]
  FRAME-07 -->|hopped| FRAME-08["FRAME-08\nRejoin camera\n(endInternetHop)"]
  FRAME-07 --> FRAME-09["FRAME-09\nUpload summary toast"]
  FRAME-07 -->|failures| FRAME-FAILED-01
  FRAME-08 --> FRAME-09

  DELIVERY-05 -->|Cancel| DELIVERY-FAILED-01
  DELIVERY-FAILED-01 -->|retry| DELIVERY-01
```

## Node cards

### FRAME-01 — Settings sign-in (prerequisite)

- **Status:** shipped
- **Screen:** Settings → Storage → Frame.io row: **Sign in** / **Log out** / **Not set up in this
  build** / **Sign in over internet** (when on the camera AP).
- **Code:** `MonitorPanels.swift` (`storageRows`, `signInFrameioOverInternet`),
  `Frameio/FrameioAuthCoordinator.swift`, `Frameio/FrameioClient.swift` (`FrameioTokenStore`),
  core `FrameioOAuth.swift`.
- **Detail:** Adobe IMS OAuth 2.0 (PKCE) via `ASWebAuthenticationSession` (iOS 17.4+). Token +
  refresh stored in Keychain (`OpenZCine.frameio` / `oauth-token`); auto-refreshed 60s before
  expiry. Requires `Frameio.local.xcconfig` → `Info.plist` (`FrameioClientID`, `FrameioRedirectURI`).
  On the camera AP the row shows **Sign in over internet** → a confirm alert → consented internet
  hop (`beginInternetHop` re-hosts the Storage panel as a standalone cover so it survives the
  monitor collapse) → `waitForInternetPath(30s)` → `connectFrameio()` (Adobe sign-in) →
  `endInternetHop()` rejoins the camera via the full join pipeline, sign-in outcome notwithstanding.
  Log out clears token **and** persisted project destination.
- 📝 Notes:

### DELIVERY-01 — Trigger Share popup

- **Status:** shipped
- **Screen:** Media grid: enter selection mode → **Share** (paperplane). Media player: transport
  bar **Share** button (disabled until clip is cached locally).
- **Code:** `MediaBrowser.swift` (`MediaBrowserView`, `MediaPlayerView`), `MediaDeliveryPopup.swift`
  (`MediaDeliveryRequest`, `MediaDeliveryPresentation`, `MediaDeliveryPopupOverlay`).
- **Detail:** Popup anchors below the grid Share button or above the player share button (420pt
  glass panel, dimmed backdrop). Player pauses playback while the popup is open.
- 📝 Notes:

### DELIVERY-02 — Pick destination

- **Status:** shipped
- **Screen:** Step 1 — **DESTINATION**: **Share** (AirDrop, Files, …) or **Frame.io** (upload to
  project). Clip count summary; on-camera clips note they'll be cached first.
- **Code:** `MediaDeliveryPopup.swift` (`DeliveryStep.destination`, `MediaDeliveryDestination`).
- **Detail:** Frame.io row uses `IconFrameio` asset; greyed when not configured, not signed in, or
  no deliverable clips. Subtitle switches to “Sign in from Settings → Storage first.” when
  configured but disconnected. `preferredDestination` skips this step (post-hop resume).
- 📝 Notes:

### DELIVERY-03 — Share options

- **Status:** shipped
- **Screen:** Step 2 — **EXPORT**: filename preview (single clip), **Bake LUT**, **Format**
  (MOV/MP4 segmented), **Include metadata**. Footer: segmented **Share** / **Save to Photos** +
  action button.
- **Code:** `MediaDeliveryPopup.swift`, `MediaDelivery.swift` (`MediaDeliveryConfiguration`,
  `MediaExportFormat`).
- **Detail:** LUT toggle disabled when no LUT selected (`currentLUTCube()` nil). Format picker only
  for native share (Frame.io uses filename extension from bake setting). Metadata writes JSON sidecar
  beside export when enabled.
- 📝 Notes:

### FRAME-02 — Frame.io options

- **Status:** shipped
- **Screen:** Off the camera AP — **PROJECT** picker (menu + **Create new project**) and **EXPORT**
  toggles (Bake LUT, Include metadata, Re-upload already uploaded) with a footer **Upload** button.
  **On the camera AP the whole option is gated** (`frameioHopGateActive`): the step shows only a
  **FRAME.IO** section with explanatory copy + a single full-width **Hop to internet** button — the
  project picker, export config, and Upload footer are all hidden until the phone leaves the AP.
- **Code:** `MediaDeliveryPopup.swift` (`optionsSection`, `frameioHopGate`, `frameioHopGateActive`,
  `frameioProjectPicker`, `exportSection`, `loadFrameioProjects`, `createFrameioProject`),
  `Frameio/FrameioModel.swift` (`FrameioDestination`, `loadFrameioProjectListing`).
- **Detail:** Project list from first account/workspace via V4 API. Selection persisted in
  UserDefaults (`frameio.destination.v1`). Changed 2026-07-05: the whole Frame.io option now sits
  behind one hop button on the AP (was an inline **Choose project over internet** button buried
  among the project/export controls). Once the settle loop sees the phone off-AP, the gate clears
  and the normal picker + export + Upload footer render.
- 📝 Notes:

### FRAME-03 — Consent: hop to internet

- **Status:** shipped
- **Screen:** Alert **Leave camera Wi‑Fi?** — Cancel / **Hop**. While hopping: “Switching networks…”
  spinner replaces the hop button in the gate.
- **Code:** `MediaDeliveryPopup.swift` (`startFrameioHop`, `showFrameioHopConfirm`, `frameioHopGate`),
  `NativeAppRoot.swift` (`beginInternetHop`, `pendingHopShareResumeClips`).
- **Detail:** Stashes `pendingHopShareResumeClips` before hop. If hop started from monitor media
  panel, browser re-hosts standalone (`isStandaloneMediaLibraryPresented`) so context survives
  session teardown. 30s wait for satisfied internet path; failure surfaces inline error.
- 📝 Notes:

### FRAME-04 — Post-hop resume

- **Status:** shipped
- **Screen:** Grid reopens with Share popup on Frame.io options, or single cached clip reopens in
  player with popup already on Frame.io step.
- **Code:** `MediaBrowser.swift` (`onAppear` + `pendingHopShareResumeClips`,
  `resumeShareDestination`, `MediaDeliveryRequest.preferredDestination`).
- **Detail:** Continuation, not a restart — operator lands where the hop interrupted them. Popup
  settle loop (1s poll) auto-loads projects once online + signed in.
- 📝 Notes:

### DELIVERY-05 — Begin delivery

- **Status:** shipped
- **Screen:** Popup dismisses; progress pill appears on clip/player (local overlay) or app root
  (global pill when navigating away).
- **Code:** `MediaDeliveryOverlay.swift` (`MediaDeliveryCoordinator.begin`,
  `MediaDeliveryRunner.execute`), wired from `MediaBrowser.swift` (`startDelivery`).
- **Detail:** Detached `Task` with delivery token guards stale progress callbacks. Cancel clears
  overlay and invokes optional cancel handler. In-popup setup hop hands off to runner (`popupStartedHop
  = false`) so `closePopup` does not rejoin mid-upload.
- 📝 Notes:

### DELIVERY-06 — Cache from camera

- **Status:** shipped
- **Screen:** Overlay: “Caching from camera…” with per-clip fraction; batch line when multi-clip.
- **Code:** `MediaDeliveryRunner` (pre-pass), `NativeAppModel.cacheClipFromCamera`,
  `mediaDownloadProgress` mirror loop (200ms).
- **Detail:** Sequential PTP download for clips not yet local — operator explicitly selected them.
  Clips that fail to cache (disconnected, no handle) are counted but excluded from export/upload;
  partial runs report uncached count in outcome. Skipped entirely when all clips already cached.
- 📝 Notes:

### DELIVERY-07 — Prepare exports

- **Status:** shipped
- **Screen:** Overlay: “Preparing…” / “Preparing to share” with percent bar.
- **Code:** `MediaDelivery.swift` (`deliverClipsForShare`, `prepareClipForDelivery`),
  `MediaLUTExport.swift` (`MediaLUT.export`).
- **Detail:** Per-clip LUT bake via Metal/AVFoundation export to `Documents/exports`, or raw cached
  file when bake off. Sets `exportStatus` (.exported / .failed). Combined batch progress:
  `(clipIndex-1 + fraction) / total`.
- 📝 Notes:

### DELIVERY-08 — Share sheet

- **Status:** shipped
- **Screen:** System share sheet (`UIActivityViewController`) with typed video items + optional
  metadata text.
- **Code:** `MediaDeliveryOverlay.swift` (`ShareableFileItem`, `MultiShareSheet`,
  `MediaShareStaging`, `MediaDeliveryShareSheetModifier`).
- **Detail:** Validates files (exists, readable, non-zero). Stable `Documents/exports` URLs shared
  in place; transient files copied to cache staging folder deleted on dismiss. Uses
  `NSItemProvider.registerFileRepresentation` to avoid sandbox URL probe noise.
- 📝 Notes:

### DELIVERY-09 — Save to Photos

- **Status:** shipped
- **Screen:** No sheet — direct save; toast “Saved N clip(s) to Photos”.
- **Code:** `MediaDeliveryOverlay.swift` (`MediaPhotosSaver`).
- **Detail:** `PHPhotoLibrary.requestAuthorization(for: .addOnly)`; saves `.mp4`/`.mov` sequentially.
  Partial failure throws with saved/failed counts.
- 📝 Notes:

### DELIVERY-10 — Share complete toast

- **Status:** shipped
- **Screen:** 2.5s capsule toast at bottom (local overlay in browser/player; global when elsewhere).
- **Code:** `MediaDeliveryCoordinator.handleOutcome`, `showCompletionToast`.
- **Detail:** Success messages for Photos save; failure toasts for empty export or save errors.
  Partial batch notes prepended to share metadata text, not a separate toast.
- 📝 Notes:

### FRAME-05 — Internet hop (upload)

- **Status:** shipped
- **Screen:** Overlay: “Switching networks…” (`isSwitchingNetworks`).
- **Code:** `MediaDeliveryRunner` (Frame.io branch), `NativeAppRoot.beginInternetHop`,
  `waitForInternetPath`.
- **Detail:** Same hop machinery as RED LUT download: leave camera AP via `NEHotspotConfiguration`
  removal, disconnect PTP session, clear stale SSID cache. 30s poll (500ms) for off-AP +
  `NWPathMonitor` satisfied path. Failure calls `endInternetHop()` and returns error toast.
- 📝 Notes:

### FRAME-06 — Upload batch

- **Status:** shipped
- **Screen:** Overlay: “Uploading to Frame.io” with percent + “Clip N of M”.
- **Code:** `MediaDelivery.swift` (`uploadClipsToFrameio`), `Frameio/FrameioModel.swift`.
- **Detail:** Sequential per clip. Skips `.uploaded` unless `forceFrameioReupload`. Uncached clips
  fail fast. Summary parts: “N uploaded, M skipped, K failed, … not cached”. OAuth/project resolution
  happens inside each clip upload when needed.
- 📝 Notes:

### FRAME-07 — Per-clip upload pipeline

- **Status:** shipped
- **Detail:** Upload state machine per clip (`FrameioStatus` in `MediaLibrary.swift`):
  `notUploaded` → `uploading` → `uploaded` (stores `frameioFileID`) or `failed`. Guarded by
  `frameioUploadInFlight` set (no duplicate concurrent uploads).
  1. **Connect** — `connectFrameio()` if no Keychain token (→ FRAME-O1).
  2. **Resolve destination** — saved `FrameioDestination` or auto-pick first project + persist.
  3. **Prepare source** — optional LUT bake (45% of progress bar) or cached/exported file.
  4. **Create File** — `POST …/folders/{id}/files/local_upload` → pre-signed S3 part URLs.
  5. **PUT chunks** — sequential S3 upload with `Content-Type` from response.
  6. **Poll status** — `GET …/files/{id}/status` until `upload_complete` (45 attempts × 2s).
  7. **Metadata sidecar** — optional `.meta.json` written next to source (local only, not uploaded).
- **Code:** `Frameio/FrameioClient.swift` (`FrameioService.upload`), `Frameio/FrameioModel.swift`
  (`uploadClipToFrameio`), core `FrameioModels.swift`.
- 📝 Notes:

### FRAME-O1 — Adobe IMS sign-in during upload

- **Status:** shipped
- **Detail:** Invoked from `uploadClipToFrameio` / `loadFrameioProjectListing` when Keychain has no
  token — presents `ASWebAuthenticationSession`, exchanges code via PKCE, stores `StoredFrameioToken`.
  Not used from the delivery popup directly (Settings sign-in is the expected path); still works if
  token expired and refresh fails.
- **Code:** `FrameioAuthCoordinator.swift`, core `FrameioOAuth.swift`, `FrameioTokenStore`.
- 📝 Notes:

### FRAME-08 — Rejoin camera

- **Status:** shipped
- **Screen:** White connection-progress card (same join pipeline as first pair).
- **Code:** `NativeAppRoot.endInternetHop` → `runCameraWiFiJoin(.specificSSID, .hotspotConfigurationOnly)`.
- **Detail:** `defer` in runner calls `endInternetHop()` when hop was started (popup or runner).
  Full rejoin with discovery → auto-reconnect; narrated in `ConnectionProgressSheet`.
- 📝 Notes:

### FRAME-09 — Upload summary toast

- **Status:** shipped
- **Screen:** Capsule toast, e.g. “2 uploaded, 1 skipped” or failure summary with failed count.
- **Code:** `MediaDeliveryCoordinator` → `.frameio(summary:)` / `.failed(message:)`.
- **Detail:** Auto-dismiss after 2.5s. Clip badges in grid reflect persisted `frameioStatus`.
- 📝 Notes:

### DELIVERY-FAILED-01 — Delivery failed / cancelled

- **Status:** shipped
- **Detail:** Cancel from overlay clears task + token. Failures: empty selection after cache,
  export errors, share staging validation, Photos permission denied. Toast or inline banner in
  popup (pre-begin validation). Popup close after setup hop (no delivery) calls `endInternetHop()`.
- 📝 Notes:

### FRAME-FAILED-01 — Hop / upload failure

- **Status:** shipped
- **Detail:** Internet hop timeout, Frame.io HTTP/decode errors, S3 PUT failure, upload poll
  timeout (`FrameioError.uploadIncomplete`). Per-clip `.failed` status persisted; batch continues
  to next clip. `frameioUploadError` surfaced once per failed clip then cleared.
- 📝 Notes:
