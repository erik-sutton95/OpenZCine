# Android camera-control write authority

Standing rules for Compose → Kotlin session → JNI → Swift facade → `OpenZCineCore`.
Keep the bridge; do not grow a second decision brain in Kotlin.

## Authority

| Layer | Owns |
| --- | --- |
| **Shared core** | Encode labels, property codes, multi-write sequences, poll order, ISO policy |
| **Swift facade** | Session, transport, `applyAndroidControl`, **native write + readback confirm** |
| **Kotlin session / shell** | Lifecycle, Compose state, map exceptions to UI; **do not re-decide success** |

If `applyControl` returns without throwing, the write is accepted. Surface only
`CameraControlException` failures (rejected, transport, unsupported encode, native
readback mismatch). Do **not** toast “did not confirm” from a post-write property
refresh that lags dual-property ISO or similar.

## Capability lists

- Drive **picker options** and fail-closed UI (empty domain → no invented codec/resolution packs).
- **Do not** hard-reject labels the shared core can encode for simple numeric/enum writes
  (ISO is the reference case: Auto can park outside the fixed ladder; body is range authority).
- **Do** hard-reject codec/resolution labels that lack an advertised raw pack — never invent
  `MovFileType` / `MovScreenSize` values.

## Product rules stay in core policy

ISO Auto On/Off, M-mode manual gate, R3D dual-base always-manual, and recording locks live in
`ISOPickerPolicy` (Swift + thin Kotlin mirror). Shells must not invent divergent Android-only
product rules.

## Soft confirm inventory (MonitorScreen)

Post-write soft confirm was removed: every `session.applyControl` path already runs
`confirmAndroidControlWrites` in the facade. Pre-write skip when live readback already matches
the desired label remains (avoids redundant wire trips; REC/codec always write).
