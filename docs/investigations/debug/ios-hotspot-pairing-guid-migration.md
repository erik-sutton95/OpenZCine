---
status: awaiting_human_verify
trigger: "Phone Hotspot first-pair wizard reaches Find and pair but remains on Looking for cameras after the camera joins"
created: 2026-07-15T08:00:00Z
updated: 2026-07-15T08:09:00Z
---

## Current Focus

hypothesis: CONFIRMED - the PTP-IP initiator GUID changed while the saved-camera record did not
next_action: Verify an upgraded TestFlight install with the saved hotspot camera and a Nikon ZR

## Resolution

root_cause: PR #25 changed the PTP-IP initiator GUID from the previously paired `ZCineCtrl` bytes
to `OpenZCine`. `NativeCameraConnectionStore.guid()` then replaced the persisted identity while
retaining the saved camera. Hotspot discovery still found the camera, but the explicit pairing
screen filtered it by saved host or camera name and rendered the empty "Looking for cameras" state.

fix: Preserve every valid persisted 16-byte initiator GUID. For installs that already received the
broken migration, let the explicit pairing wizard surface a saved camera as a repair fallback when
no new camera is present. The existing saved-profile connection path can then retry first-time
pairing when the camera rejects the replaced identity. New cameras still take priority over repair
candidates, and fresh installs continue to seed the `OpenZCine` identity.

verification: `just test` and `just check` passed with 666 tests, including initiator persistence
and hotspot repair policy coverage. The focused `FirstPairWizardStepTests` suite passed, and
`just native-check` passed the Swift package, iOS, and watchOS build gates. Physical-camera
confirmation remains.

files_changed: [Sources/OpenZCineCore/PTPIPHandshake.swift,
  Sources/OpenZCineCore/PTPIPSavedCameraRecords.swift,
  Tests/OpenZCineCoreTests/PTPIPHandshakeTests.swift,
  Tests/OpenZCineCoreTests/CameraStartupPolicyTests.swift,
  ios/Runner/NativeCameraSession.swift, ios/Runner/NativeAppRoot.swift,
  ios/RunnerTests/FirstPairWizardStepTests.swift]
