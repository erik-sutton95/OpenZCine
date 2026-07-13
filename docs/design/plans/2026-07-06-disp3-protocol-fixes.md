# DISP 3 Protocol Fixes Implementation Plan

**Goal:** Rewire the DISP 3 command monitor's IBIS tile to the documented movie-stabilization properties with a working picker, reconcile the codec/resolution write paths with reality, and correct the internal protocol notes.

**Architecture:** All protocol changes live in `Sources/OpenZCineCore` (property enum, decoders, snapshot, write builders) with Swift Testing coverage; the iOS shell gains one small picker panel and a one-line tile mapping. Writes follow the existing safe-point queue pattern (`PendingCameraWrite`), 2-byte props via standard `SetDevicePropValue 0x1016`.

**Tech Stack:** Swift 6.0 strict concurrency, Swift Testing (`import Testing`), SwiftUI shell.

## Global Constraints

- Spec: `docs/design/specs/2026-07-06-disp3-and-portrait-design.md` (workstream A).
- Branch: `ui/general-improvements`. Never commit to `main`.
- Verify with `just native-check`. Known environmental fallback (see repo memory): if the local test runner ABI-crashes, run `just ios-build` plus `just check`, and rely on CI for the test phase — never skip the build.
- New camera writes are tagged verify-on-HW in comments until validated on the real ZR.
- Property codes must cite their libgphoto2 symbol in comments (repo provenance rule — see `docs/nikon-mtp.md`).
- No force-unwraps without `// SAFETY:`; typed errors; no deprecated SwiftUI APIs.
- **pbxproj gotcha:** any NEW `.swift` file (core or shell) must be registered in `ios/Runner.xcodeproj/project.pbxproj` or the app target won't see it. This plan adds no new production files (tests excepted) to avoid this entirely.

---

### Task 1: Core — `movieVibrationReduction 0xD1F9` property, decoder, snapshot field

**Files:**
- Modify: `Sources/OpenZCineCore/PTPOperation.swift:147-160` (property enum + provenance comment)
- Modify: `Sources/OpenZCineCore/PTPCameraProperties.swift:23-51` (poll order), `:664` (decoders), `:823-1105` (snapshot)
- Test: `Tests/OpenZCineCoreTests/CameraPropertyTests.swift`

**Interfaces:**
- Produces: `PTPPropertyCode.movieVibrationReduction` (= `0xD1F9`), `PTPCameraPropertyDecoders.movieVibrationReduction(_ raw: UInt8) -> String`, `PTPCameraPropertyDecoders.movieVibrationReductionCode(for label: String) -> UInt8?`, `PTPCameraPropertySnapshot.vibrationReduction: String?`

- [ ] **Step 1: Write the failing tests** (append to `CameraPropertyTests.swift`):

```swift
@Test func movieVibrationReductionDecodesKnownValues() {
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(0) == "OFF")
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(1) == "ON")
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(2) == "SPORT")
    #expect(PTPCameraPropertyDecoders.movieVibrationReduction(9) == "0x9")
}

@Test func movieVibrationReductionCodeRoundTrips() {
    for raw: UInt8 in [0, 1, 2] {
        let label = PTPCameraPropertyDecoders.movieVibrationReduction(raw)
        #expect(PTPCameraPropertyDecoders.movieVibrationReductionCode(for: label) == raw)
    }
    #expect(PTPCameraPropertyDecoders.movieVibrationReductionCode(for: "0x9") == nil)
}

@Test func snapshotDecodesVibrationReduction() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieVibrationReduction, data: Data([1]))
    #expect(snapshot.vibrationReduction == "ON")
}
```

- [ ] **Step 2: Run tests to verify they fail.** Run: `just test` (fallback per Global Constraints). Expected: FAIL — `movieVibrationReduction` not defined.

- [ ] **Step 3: Implement.**
  - `PTPOperation.swift`: inside the "Command-monitor audio / stabilisation" comment block (line ~147), add the line `//   movieVibrationReduction  0xD1F9  PTP_DPC_NIKON_MovieVibrationReduction  (ptp.h:2691)` and the case:

```swift
    case movieVibrationReduction = 0xD1F9
```

  - `PTPCameraProperties.swift` decoders (near `onOffLabel`, line ~664):

```swift
    /// `MovieVibrationReduction` (0xD1F9, UINT8) raw → label. Value table
    /// [ZR-only · verify-on-HW]: libgphoto2 has the code but no config.c table.
    public static func movieVibrationReduction(_ raw: UInt8) -> String {
        switch raw {
        case 0: "OFF"
        case 1: "ON"
        case 2: "SPORT"
        default: hex(UInt32(raw))
        }
    }

    /// Inverse of `movieVibrationReduction`, for encoding a picker selection.
    public static func movieVibrationReductionCode(for label: String) -> UInt8? {
        switch label {
        case "OFF": 0
        case "ON": 1
        case "SPORT": 2
        default: nil
        }
    }
```

  - `PTPCameraPropertySnapshot`: add `vibrationReduction: String? = nil` to `init` (after `inputAttenuator`), a stored `public let vibrationReduction: String?` (doc comment `/// Movie VR (lens/in-body stabilisation) label.`), the same parameter in `replacing(...)` with `vibrationReduction ?? self.vibrationReduction`, and in `applying(property:data:)`:

```swift
        case .movieVibrationReduction where bytes.count >= 1:
            return replacing(
                vibrationReduction: PTPCameraPropertyDecoders.movieVibrationReduction(bytes[0]))
```

  - Poll order (`liveMonitorPollOrder`, line ~44): insert `.movieVibrationReduction,` between `.movieAttenuator,` and `.electronicVR,`.

- [ ] **Step 4: Run tests to verify they pass.** Run: `just test`. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OpenZCineCore/PTPOperation.swift Sources/OpenZCineCore/PTPCameraProperties.swift Tests/OpenZCineCoreTests/CameraPropertyTests.swift
git commit -m "feat(core): poll and decode MovieVibrationReduction 0xD1F9"
```

---

### Task 2: Core — stabilization summary reads VR + e-VR (drop stills eFCS)

**Files:**
- Modify: `Sources/OpenZCineCore/PTPCameraProperties.swift:688-699` (decoder), `:944-949` (snapshot var), `:23-51` (poll order)
- Test: `Tests/OpenZCineCoreTests/CameraPropertyTests.swift`

**Interfaces:**
- Consumes: Task 1's `vibrationReduction` snapshot field.
- Produces: `PTPCameraPropertyDecoders.stabilizationSummary(vibrationReduction:electronicVR:)` — same `String?` shape, new first parameter. `PTPCameraPropertySnapshot.stabilizationSummary` now composes VR + e-VR.

- [ ] **Step 1: Check existing summary tests, then write the failing tests.** Run `grep -n "stabilizationSummary" Tests/OpenZCineCoreTests/CameraPropertyTests.swift` — update any existing cases to the new signature in the same edit. Add:

```swift
@Test func stabilizationSummaryComposesVRAndElectronicVR() {
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: "ON", electronicVR: "OFF") == "ON/OFF")
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: "ON", electronicVR: "ON") == "ON")
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: nil, electronicVR: "ON") == "ON")
    #expect(
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: nil, electronicVR: nil) == nil)
}

@Test func snapshotStabilizationSummaryPrefersVR() {
    let snapshot = PTPCameraPropertySnapshot()
        .applying(property: .movieVibrationReduction, data: Data([2]))
        .applying(property: .electronicVR, data: Data([0]))
    #expect(snapshot.stabilizationSummary == "SPORT/OFF")
}
```

- [ ] **Step 2: Run tests to verify they fail.** Run: `just test`. Expected: FAIL — wrong signature / wrong composition.

- [ ] **Step 3: Implement.** Rename the decoder's parameters and rewire the snapshot var (keep the existing nil/equal-collapse behavior):

```swift
    /// Command-monitor stabilisation summary: movie VR (0xD1F9) + electronic VR (0xD314).
    /// The stills-only e-front-curtain-shutter (0xD20D) is deliberately NOT part of this —
    /// it is meaningless on a video monitor.
    public static func stabilizationSummary(
        vibrationReduction: String?,
        electronicVR: String?
    ) -> String? {
        switch (vibrationReduction, electronicVR) {
        case (nil, nil): nil
        case (let vr?, nil): vr
        case (nil, let evr?): evr
        case (let vr?, let evr?) where vr == evr: vr
        case (let vr?, let evr?): "\(vr)/\(evr)"
        }
    }
```

```swift
    /// Command-monitor stabilisation summary (movie VR + electronic VR).
    public var stabilizationSummary: String? {
        PTPCameraPropertyDecoders.stabilizationSummary(
            vibrationReduction: vibrationReduction,
            electronicVR: electronicVR
        )
    }
```

  Then remove eFCS from active use: run `grep -rn "electronicFrontCurtainShutter" Sources ios Tests`. Expected remaining uses: poll order, snapshot field/init/replacing/applying, decoder comment. Delete `.electronicFrontCurtainShutter,` from `liveMonitorPollOrder` and delete the snapshot field end-to-end (init param, stored property, `replacing` param, `applying` case). Keep the `PTPPropertyCode` case with a comment: `// Stills-only; not polled — kept for provenance.` If the grep shows other live consumers, stop and reassess instead of deleting.

- [ ] **Step 4: Run tests to verify they pass.** Run: `just test`. Expected: PASS (compiler confirms no dangling eFCS references).

- [ ] **Step 5: Commit.**

```bash
git add -A Sources Tests
git commit -m "fix(core): stabilization summary = movie VR + e-VR, retire stills eFCS from the monitor"
```

---

### Task 3: Core — VR/e-VR write builders + picker option labels

**Files:**
- Modify: `Sources/OpenZCineCore/PTPCameraProperties.swift` (`PTPCameraPropertyWrite` extension ~line 186; `optionLabels(for:)` ~line 753)
- Test: `Tests/OpenZCineCoreTests/CameraPropertyTests.swift`

**Interfaces:**
- Produces: `PTPCameraPropertyWrite.vibrationReduction(label: String) -> PTPCameraPropertyWrite?`, `PTPCameraPropertyWrite.electronicVR(on: Bool) -> PTPCameraPropertyWrite`; `optionLabels(for: .movieVibrationReduction, rawValues:)` returns VR labels.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func vibrationReductionWriteEncodes() {
    let write = PTPCameraPropertyWrite.vibrationReduction(label: "SPORT")
    #expect(write?.property == .movieVibrationReduction)
    #expect(write?.data == Data([2]))
    #expect(PTPCameraPropertyWrite.vibrationReduction(label: "0x9") == nil)
}

@Test func electronicVRWriteEncodes() {
    #expect(PTPCameraPropertyWrite.electronicVR(on: true).data == Data([1]))
    #expect(PTPCameraPropertyWrite.electronicVR(on: false).data == Data([0]))
    #expect(PTPCameraPropertyWrite.electronicVR(on: true).property == .electronicVR)
}

@Test func optionLabelsDecodeVibrationReductionEnum() {
    let labels = PTPCameraPropertyDecoders.optionLabels(
        for: .movieVibrationReduction, rawValues: [0, 1, 2, 9])
    #expect(labels == ["OFF", "ON", "SPORT"])
}
```

- [ ] **Step 2: Run tests to verify they fail.** Run: `just test`. Expected: FAIL.

- [ ] **Step 3: Implement.** Next to `shutterMode(_:)`/`movieTVLock(unlocked:)` builders (~line 186):

```swift
    /// Movie VR write (`MovieVibrationReduction` 0xD1F9, UINT8). 2-byte prop → standard 0x1016
    /// path in the session. [verify-on-HW]
    public static func vibrationReduction(label: String) -> PTPCameraPropertyWrite? {
        guard let code = PTPCameraPropertyDecoders.movieVibrationReductionCode(for: label) else {
            return nil
        }
        return PTPCameraPropertyWrite(property: .movieVibrationReduction, data: Data([code]))
    }

    /// Electronic VR toggle (`ElectronicVR` 0xD314, UINT8 on/off). [verify-on-HW]
    public static func electronicVR(on: Bool) -> PTPCameraPropertyWrite {
        PTPCameraPropertyWrite(property: .electronicVR, data: Data([on ? 1 : 0]))
    }
```

  In `optionLabels(for:rawValues:)` add before `default`:

```swift
            case .movieVibrationReduction:
                label = movieVibrationReduction(UInt8(truncatingIfNeeded: raw))
```

- [ ] **Step 4: Run tests to verify they pass.** Run: `just test`. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/OpenZCineCore/PTPCameraProperties.swift Tests/OpenZCineCoreTests/CameraPropertyTests.swift
git commit -m "feat(core): VR / e-VR write builders and picker option labels"
```

---

### Task 4: Shell — stabilization picker wired to the IBIS tile

**Files:**
- Modify: `ios/Runner/NativeAppRoot.swift` (`CameraPicker` enum :5152; model funcs near `switchBaseISO` :4676; `commandStabilizationLabel` :4792 unchanged)
- Modify: `ios/Runner/MonitorPanels.swift` (tile mapping :233-244; picker panel body — locate via step 1)

**Interfaces:**
- Consumes: Task 3's write builders; existing `PendingCameraWrite`, `drainPendingWritesIfIdle()`, `cameraControlOptions[PTPPropertyCode]`.
- Produces: `CameraPicker.stabilization`; `NativeAppModel.setVibrationReduction(_ label: String)`, `NativeAppModel.setElectronicVR(on: Bool)`; `StabilizationPickerPanel` view.

- [ ] **Step 1: Discovery.** Read `ios/Runner/MonitorPanels.swift:660-800` (`bottomPickerBody(_:)` / `topPickerBody(_:)`) to learn exactly how a `CameraPicker` case maps to its panel view and how panels are laid out (`PickerPanel` drum vs custom bodies), and `grep -n "cameraControlOptions" ios/Runner/NativeAppRoot.swift` to find where descriptor enums populate options (so `.movieVibrationReduction` options refresh the same way). Adjust step 3's integration points to what you find — the view code itself stays as written.

- [ ] **Step 2: Add the picker case.** In `CameraPicker` (NativeAppRoot.swift:5152): add `case stabilization` with `title: "Stabilization"`, `subtitle: "VR · electronic VR"`, `valueLabel: "STAB"` (must be unique — the `byValueLabel` dictionary traps duplicates), `isTopBar: false`, `cameraControl: nil` (writes go through the model funcs below, not `applyPickerValue`).

- [ ] **Step 3: Add model funcs + panel view.** Model funcs (pattern-match `switchBaseISO`, NativeAppRoot.swift:4676):

```swift
    /// Queues a movie-VR write ("OFF"/"ON"/"SPORT"). [verify-on-HW]
    func setVibrationReduction(_ label: String) {
        guard let write = PTPCameraPropertyWrite.vibrationReduction(label: label) else { return }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        cameraState = cameraState.applyingCameraProperties(
            cameraPropertySnapshot, mediaStatus: currentMediaStatus())
        guard !isDemoSession else { return }
        pendingCameraWrites.append(
            PendingCameraWrite(picker: .stabilization, value: label, write: write))
        connectionMessage = "Queued VR \(label) for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    /// Queues an electronic-VR on/off write. [verify-on-HW]
    func setElectronicVR(on: Bool) {
        let write = PTPCameraPropertyWrite.electronicVR(on: on)
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        cameraState = cameraState.applyingCameraProperties(
            cameraPropertySnapshot, mediaStatus: currentMediaStatus())
        guard !isDemoSession else { return }
        pendingCameraWrites.append(
            PendingCameraWrite(
                picker: .stabilization, value: on ? "e-VR ON" : "e-VR OFF", write: write))
        connectionMessage = "Queued e-VR \(on ? "ON" : "OFF") for the next live-view safe point."
        drainPendingWritesIfIdle()
    }
```

  Panel view (in MonitorPanels.swift, near the other picker bodies); wire it into the picker-body switch for `.stabilization` per step 1's discovery, and match the neighboring panels' container chrome:

```swift
/// Stabilization picker (movie VR + electronic VR) for the command monitor's VR tile.
struct StabilizationPickerPanel: View {
    @Environment(NativeAppModel.self) private var model

    private var vrOptions: [String] {
        model.cameraControlOptions[.movieVibrationReduction] ?? ["OFF", "ON", "SPORT"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            optionRow(
                title: "VR", options: vrOptions,
                selected: model.cameraPropertySnapshot.vibrationReduction
            ) { model.setVibrationReduction($0) }
            optionRow(
                title: "e-VR", options: ["OFF", "ON"],
                selected: model.cameraPropertySnapshot.electronicVR
            ) { model.setElectronicVR(on: $0 == "ON") }
        }
        .padding(16)
    }

    private func optionRow(
        title: String, options: [String], selected: String?,
        action: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiveDesign.muted)
                .frame(width: 44, alignment: .leading)
            ForEach(options, id: \.self) { option in
                Button { action(option) } label: {
                    Text(option)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(option == selected ? LiveDesign.accent : LiveDesign.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                                .fill(
                                    option == selected
                                        ? LiveDesign.accentDim : LiveDesign.surface)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

  (If `cameraControlOptions` / `cameraPropertySnapshot` aren't visible to views, expose read-only computed vars on the model following `commandStabilizationLabel`'s pattern.) Then the tile (MonitorPanels.swift:242): `case .ibis: nil` → `case .ibis: .stabilization`. Update the tile title (:229) from `"IBIS / ES"` to `"VR / e-VR"`.

- [ ] **Step 4: Build + screenshot-verify (MANDATORY).** `just ios-build`, launch the sim in demo mode, cycle DISP to command mode (or `ZC_DEMO_DISP=command`), tap the VR tile. `xcrun simctl io booted screenshot /tmp/claude/stab-picker.png` then `sips -r -90 /tmp/claude/stab-picker.png` (landscape). Verify: panel fully on-screen, all four edges clean, no truncation; tile label updates optimistically after a selection. Fix and re-screenshot until clean.

- [ ] **Step 5: Run `just native-check`, then commit.**

```bash
git add ios/Runner/NativeAppRoot.swift ios/Runner/MonitorPanels.swift
git commit -m "feat(ios): stabilization picker for the command monitor VR tile"
```

---

### Task 5: Core cleanup — codec/resolution write reality + stale comments

**Context (spec deviation, agreed):** the spec said "un-stub" these writes, but the picker path is *already wired*: `applyPickerValue` (NativeAppRoot.swift:5046) writes exact camera-advertised values via `screenSize(raw:)` / `fileType(raw:)`, packet-capture-confirmed to go through `0x1016` during live view. The label-based `codecWrite`/`resolutionWrite` encoders in `PTPCameraProperties.swift` are unreachable from the pickers. This task deletes the dead paths and truths-up comments; on-device ZR validation is the remaining acceptance item.

**Files:**
- Modify: `Sources/OpenZCineCore/PTPCameraProperties.swift:1-8` (header comment), `:121-147` (request overloads), `:201-269` (dead encoders)
- Test: `Tests/OpenZCineCoreTests/CameraPropertyTests.swift`

**Interfaces:**
- Consumes: nothing new. Produces: unchanged public surface minus the dead `request(control:label:snapshot:)` codec/resolution arms.

- [ ] **Step 1: Verify the encoders are dead.** Run: `grep -rn "codecWrite\|resolutionWrite\|reverseCodecNames\|containerCode\|bitDepth(from" Sources ios Tests`. Expected: definitions in `PTPCameraProperties.swift` plus possibly tests. If any *production* call site outside `request(control:label:snapshot:)` appears, stop and reassess.

- [ ] **Step 2: Delete and reconcile.** Remove `codecWrite`, `resolutionWrite`, `reverseCodecNames`, `containerCode(for:)`, `bitDepth(from:)`. Collapse `request(control:label:snapshot:)` so `.codec`/`.resolution` fall through to `request(control:label:)` (which returns nil for them) — `applyPickerValue` never routes them here. Update the file-header comment (lines 3–8) and the `case .codec, .resolution` comment to state the truth: picker writes use exact camera-advertised `screenSize(raw:)`/`fileType(raw:)` values via the safe-point queue (packet-capture-verified during live view); label-based encoding is intentionally unsupported. Delete any tests that exercised the removed encoders; keep/adjust tests for `screenSize(raw:)`/`fileType(raw:)` (add if missing):

```swift
@Test func advertisedModeWritesUseExactRawValues() {
    let size = PTPCameraPropertyWrite.screenSize(raw: 0x1770_0D08_1900_0000)
    #expect(size.property == .movieRecordScreenSize)
    #expect(size.data == Data(ByteCoding.uint64LE(0x1770_0D08_1900_0000)))
    let codec = PTPCameraPropertyWrite.fileType(raw: 0x0031_0C03)
    #expect(codec.property == .movieFileType)
    #expect(codec.data == Data(ByteCoding.uint32LE(0x0031_0C03)))
}
```

- [ ] **Step 3: Run `just test` (fallback per Global Constraints).** Expected: PASS, no dangling references.

- [ ] **Step 4: Commit.**

```bash
git add -A Sources Tests
git commit -m "refactor(core): remove dead codec/resolution label encoders; document the verified write path"
```

---

### Task 6: Internal protocol notes fix

**Files:**
- Modify: the internal property-wire-operations notes

- [ ] **Step 1: Correct the two spots.** Replace the claim that 2-byte and 4-byte codes "flow through the same extended ops" with the verified behavior (mirror `PTPOperation.swift:57-62`): 2-byte `0xDxxx` properties use standard `GetDevicePropValue 0x1015` / `SetDevicePropValue 0x1016`; the Ex ops (`0x943A–0x943C`) are for 4-byte `0x0001_Dxxx` extended properties; the ZR closes the connection if a 2-byte recording-format property is Ex-written. Also update the "unverified-on-hardware" codec/resolution bullets to match Task 5's reconciled comments (writes ship via advertised-mode values; on-device confirmation pending).

- [ ] **Step 2: Run `just check` (docs/lint only).** Expected: PASS.

- [ ] **Step 3: Commit.**

---

### Task 7: On-device ZR validation checklist (user-assisted)

No code. With the real ZR connected, validate and record results in the PR description:

- [ ] VR tile shows the body's actual VR state (toggle VR in the camera menu → tile follows on the next poll).
- [ ] Setting VR OFF/ON(/SPORT) from the picker sticks on the body; a `0xA0xx` refusal surfaces the queued-write message instead of silently dropping.
- [ ] e-VR toggle round-trips the same way.
- [ ] Codec picker: selecting an advertised codec sticks (check body menu); refusal surfaces a message.
- [ ] Resolution/frame-rate picker: selecting an advertised mode sticks; refusal surfaces a message.
- [ ] If a raw VR value outside 0/1/2 appears, note the hex label shown and extend the decode table.
- [ ] Remove the `[verify-on-HW]` tags that validated; keep tags on anything the body refused, with a note.
