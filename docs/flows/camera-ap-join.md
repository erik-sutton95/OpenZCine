# Flow: First pair — Camera Access Point

The full journey from a fresh install to live view over the ZR's own Wi‑Fi. Every box below has
a node card with the detail; edit anything, Claude picks it up from the diff.

```mermaid
flowchart TD
  PERMISSIONS-01["PERMISSIONS-01\nPermissions step\n(Camera + Local Network)"] -->|both granted| TRANSPORT-01["TRANSPORT-01\nChoose transport"]
  TRANSPORT-01 -->|Camera's Access Point| PREPARE-01["PREPARE-01\nPrepare camera cards"]
  PREPARE-01 -->|Continue| SCAN-01["SCAN-01\nOCR scanner\n(SSID + key off camera screen)"]
  SCAN-01 -->|parsed| JOIN-01["JOIN-01\nWhite card: ready to join\n(read-only key + Connect)"]
  JOIN-01 -->|Connect| JOIN-02["JOIN-02\nJoining Wi-Fi\n(3 transparent retries)"]
  JOIN-02 -->|joined| JOIN-03["JOIN-03\nSearching for camera\n(45s discovery window)"]
  JOIN-02 -->|all retries failed| JOIN-FAILED-01["JOIN-FAILED-01\nFailure card + Close"]
  JOIN-03 -->|camera found| PAIRING-01["PAIRING-01\nAuto-connect + pairing\n(auto-accept PIN)"]
  JOIN-03 -->|timeout| JOIN-FAILED-01
  PAIRING-01 -->|pairing accepted in-app| CONFIRM-01["CONFIRM-01\nConfirm on camera\n(ZR restarts its AP)"]
  CONFIRM-01 -->|camera returns| RECONNECT-01["RECONNECT-01\nAuto-reconnect\n(armed until success)"]
  RECONNECT-01 -->|connected| LIVEVIEW-01["LIVEVIEW-01\nLive view"]
  JOIN-FAILED-01 -->|retry| JOIN-01
```

## Node cards

### PERMISSIONS-01 — Permissions step

- **Status:** shipped
- **Screen:** Wizard step 1: Camera + Local Network rows, Continue gated until BOTH granted.
- **Code:** `ios/Runner/StartupPermissions.swift`
- **Detail:** Local Network has no iOS status API — a self-published Bonjour beacon
  (`_ozcprobe._tcp`) + `NWBrowser` detect grant/deny; denial re-probes every 2s (Settings
  round-trips and the toggle-kills-the-app relaunch both self-heal). Camera reads
  `AVCaptureDevice.authorizationStatus`. Step skipped entirely when already satisfied.
- 📝 Notes:

### TRANSPORT-01 — Choose transport

- **Status:** shipped
- **Screen:** Three cards: Camera's Access Point (Simplest) / Phone's Hotspot (Best wireless) /
  USB-C (Most stable). Tap selects and advances.
- **Code:** `StartupDesign.swift` (`StartupFirstPairWizardView`), copy in `StartupWizardContent`.
- 📝 Notes:

### PREPARE-01 — Prepare camera

- **Status:** shipped
- **Screen:** Numbered instruction cards for putting the ZR on its Connection wizard screen.
- **Code:** `StartupWizardPrepareCards` / `StartupWizardContent.preparationSteps(for:)`.
- 📝 Notes:

### SCAN-01 — OCR scanner

- **Status:** shipped
- **Screen:** VisionKit DataScanner reads SSID + key off the ZR's screen; parser self-corrects
  OCR (O/0, l/1, S/5) because `NIKON_ZR_` + 5 digits and 8-hex-key are the only legal shapes.
- **Code:** `CameraWiFiScannerView.swift`, core `CameraWiFiScreenParser.swift` (+ tests).
- **Detail:** Simulator has no DataScanner → manual fallback. Scan feeds the join popup via
  `applyScannedCameraWiFi` — never a parallel join path.
- 📝 Notes:

### JOIN-01 — Ready to join (white card)

- **Status:** shipped
- **Screen:** Light card (scanner-matching): SSID title, read-only monospaced key chip
  ("Scanned from camera screen — check it matches."), Connect, Cancel. Wrong OCR ⇒ Cancel + rescan.
- **Code:** `ConnectionProgressSheet.swift` (single light card for ALL phases now).
- 📝 Notes:

### JOIN-02 — Joining Wi‑Fi

- **Status:** shipped
- **Detail:** `NEHotspotConfiguration` apply with up to 3 attempts, 2s apart (first-attempt
  association flake right after the ZR raises its AP is routine); "Don't Join" on the iOS alert
  never loops. Password persisted to keychain on first resolve; a `.system` failure clears it
  only after the FINAL attempt. Join confirmation falls back to IPv4-subnet detection when the
  wifi-info entitlement can't read the SSID.
- **Code:** `NativeAppRoot.runCameraWiFiJoin`, `WiFiJoinCoordinator.swift`.
- 📝 Notes:

### JOIN-03 — Searching for camera

- **Status:** shipped
- **Detail:** Discovery restarts with cleared results (stale pre-join entries would auto-pair a
  dead host); 45s window at 250ms polls — one discovery pass alone (1.4s Bonjour + subnet probe)
  can run past 10s, so the original 8s window failed on-device every time.
- **Code:** `runCameraWiFiJoin` post-join block; `NativeCameraDiscovery.swift`.
- 📝 Notes:

### JOIN-FAILED-01 — Failure card

- **Status:** shipped
- **Detail:** In-card message + Close (failure text pinned in `connectionFailureDetail` — the
  live `connectionMessage` gets overwritten by the discovery loop). Close returns to the wizard;
  retrying re-runs from JOIN-01 with the keychain key.
- 📝 Notes:

### PAIRING-01 — Auto-connect + pairing

- **Status:** shipped
- **Detail:** First discovery candidate chains straight into `connectToCamera` (no drop back to
  the wizard). Pairing PIN auto-accepts; strategy resolves saved-vs-first-time per host.
- 📝 Notes:

### CONFIRM-01 — Confirm on camera

- **Status:** shipped
- **Screen:** White card, phase `confirmOnCamera`: “Tap ‘Confirm’ on <camera>. It will restart
  its Wi‑Fi — we'll reconnect automatically.” Phase-anchored (message fields get stomped by the
  discovery loop).
- **Code:** core `ConnectionProgress.swift`, `transitionToSavedCameraNetworkCheck`.
- 📝 Notes:

### RECONNECT-01 — Auto-reconnect

- **Status:** shipped
- **Detail:** Paired-reconnect watcher re-applies the camera network (throttled 5s) and retries
  the PTP connect on every discovery pass until one SUCCEEDS (the ZR can hold the pre-drop
  session and time out the first Init); disarms on success or operator Cancel.
- **Code:** `applyDiscoveryResults`, `attemptPairedReconnectRejoin`.
- 📝 Notes:

### LIVEVIEW-01 — Live view

- **Status:** shipped
- **Detail:** `enterLiveView()` immediately on connect; wizard marked completed; camera saved.
- 📝 Notes:
