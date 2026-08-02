# Transport architecture: from inferred topology to declared setups

Status: DESIGN FOR REVIEW — nothing below is implemented except Stage 0.
Owner intent (2026-08-02): "It should be modular and each transport path should be isolated
logic-wise. Rock solid on iOS and Android. One camera used across multiple settings should be
seamless."

## The disease, with receipts

Five times on this branch the same class of bug shipped, was patched, and returned wearing a
different coat. Every patch was correct; none could be sufficient, because they all treated a
symptom of one structural fact: **the app does not remember which way it talks to a camera — it
re-derives it, after the fact, from artifacts.**

| Patch | What it fixed | What it could not fix |
|---|---|---|
| `1ddf832` evidence field | Records gained `pairedViaCameraAccessPoint` | The tri-state (`true/false/nil`) was born ambiguous: most connects cannot read the SSID, so most records carry `nil` |
| `807bcc6` two more holes | Post-confirm gap; legacy twin records | Evidence still arrived late, on the wrong record, or never |
| `a0864f1` session latch | Recovery stopped reconfiguring Wi-Fi on non-AP sessions | Had to LATCH topology at establishment precisely because records could not be trusted to know it |
| `2da5523` merge tightening | Router records stopped being swallowed by AP records | The already-merged record on every existing install still carries AP artifacts |
| `81e0db5` hangup re-pair | New camera-side network profiles self-heal | The app still decided to skip pairing from ITS records rather than the camera's word |

The recurring "join NIKON_…" alert is the visible face: a join machinery that any code path can
reach, gated by an ever-growing list of exclusions (wizard state, recovery latches, evidence
values, subnet shapes, discovery presence, declined-SSID mutes). Each exclusion is a patch-site;
the list is the bug.

## The principle

**Transport is a decision the operator made once, not a property the network reveals.** The
system's job is to remember that decision and route every behavior through it. Concretely:

1. Transport intent is an **explicit, persisted value** — chosen at setup time, carried through
   records, connects, discovery, recovery, and the relay. Never inferred from an SSID string, a
   subnet, or a host address. (Inference survives in exactly one place: the one-time migration
   of pre-existing records.)
2. Each transport is an **isolated module** owning its whole lifecycle. The camera-AP module is
   the ONLY code that may touch `NEHotspotConfiguration`/AccessorySetupKit. A router connect
   cannot prompt a Wi-Fi join because the infrastructure module *contains no join code* — the
   bug class becomes unrepresentable, not guarded against.
3. **The camera's word beats the app's records.** Establishment treats camera refusals and
   hangups as authoritative signals about pairing state (the `81e0db5` rule, generalized into
   the connector contract instead of a special case).

## Target shape

### Core (shared with Android through the facade)

```swift
/// The operator's declared path to one camera, in one rig configuration.
enum CameraTransport: Codable, Sendable {
    case cameraAccessPoint(ssid: String?)      // the app joins the CAMERA's network
    case infrastructure(networkName: String?)  // router: both devices on someone's network
    case phoneHotspot                          // the camera joins the PHONE's network
    case usbC
    case hdmiCapture                           // picture only; control optional via another setup
}

/// One camera identity → many setups. THE persisted unit; replaces the flat record + the
/// evidence tri-state + the fuzzy cross-host merge.
struct CameraSetup: Codable, Identifiable {
    let cameraID: CameraIdentity      // serial-first; name/GUID fallback
    var transport: CameraTransport
    var host: String?                 // last-known address on this path (nil for USB/HDMI)
    var displayName: String
    var lastConnectedAt: Date?
    var isDefault: Bool               // the row's big Connect uses this setup
}
```

Setups are keyed by `(cameraID, transport-kind)` — a camera has at most one setup per transport
kind, edited in place. There is no cross-host merge heuristic: a DHCP move UPDATES the
infrastructure setup's `host`; it cannot collide with the AP setup because they are different
rows of a different table.

Migration (one-time, tested, then the inference code is deleted): existing
`PTPIPSavedCameraRecord`s map — evidence `true` → `.cameraAccessPoint`; hotspot subnet/label →
`.phoneHotspot`; `usb:` host → `.usbC`; everything else → `.infrastructure`. A merged record
that historically carried both AP artifacts and router use maps to BOTH setups (AP from its
SSID, infrastructure from its host) — which un-poisons every install like the owner's.

### iOS connectors

```
protocol CameraConnector {
    func reachability(for setup: CameraSetup) -> SetupAvailability   // drives the row chip
    func prepare(_ setup: CameraSetup) async throws                  // e.g. AP join — ONLY here
    func discover(_ setup: CameraSetup) async -> [DiscoveredCamera]  // transport-scoped
    func establish(_ setup: CameraSetup) async throws -> ActiveSession
    func recover(_ session: ActiveSession) async -> RecoveryOutcome  // per-transport policy
}
```

- `CameraAPConnector` — join machinery (NEHotspot/ASK), credential store, the DJI-style popup,
  the scanner. Recovery may rejoin the AP. Owns the `NIKON_*` SSID vocabulary exclusively.
- `InfrastructureConnector` — discovery on the current network (Bonjour + subnet probe), waits
  out drops, NEVER touches Wi-Fi configuration. Owns the "wrong network" hint.
- `HotspotConnector` — hosts nothing, joins nothing; waits for the camera to appear on the
  hotspot subnet; recovery waits for the camera to rejoin.
- `USBConnector` — ImageCaptureCore attach lifecycle.
- `HDMISource` — picture-only; composes with any control connector (the hybrid).

A thin `ConnectionOrchestrator` resolves `setup.transport → connector` and runs shared PTP
establishment through it. The pairing decision consults the connector AND the camera: a
refusal/hangup during a pairing-skipped establishment always falls back to one fresh pairing.

The a0864f1 latch generalizes: `ActiveSession.transport` is locked at establishment, and
recovery dispatches on IT — the latch stops being a bolt-on flag and becomes the design.

### What gets deleted (the point of the exercise)

- `CameraWiFiJoinPolicy.joinTargetIfNeeded` and its exclusion chain
- `proactiveJoinTarget` brand-prefix fishing (replaced by: the AP connector may auto-prepare
  ONLY its own declared setups)
- `pairedViaCameraAccessPoint` tri-state and every read of it
- `pathKindsCompatible` / `recordsDescribeSameCamera` cross-host merge heuristics
- Scattered `usesIPhoneHotspot` subnet checks (one constant inside `HotspotConnector`)
- Every `NIKON_` derivation outside `CameraAPConnector`
- `establishedSessionUsedCameraAP` (subsumed by `ActiveSession.transport`)

### Android alignment

Android already types transports (its pairing flow is sequence-derived and closer to this
design). Stage 5 moves `CameraTransport`/`CameraSetup` into the shared core so both platforms
persist the same shape through the facade, and Android's connectors mirror the iOS split where
its platform machinery differs (no NEHotspot equivalent; its AP join is user-guided).

> Inventory of every current inference site (both platforms) is appended in
> `## Appendix: audit inventory` once the sweep completes — each entry is either assigned to a
> connector or scheduled for deletion.

## Saved cameras: one camera, many setups (UX)

The list keeps its shape — one ROW per camera — and the paths become first-class:

1. **Chips connect.** Each setup chip (USB-C · Router · Camera AP · Hotspot) is directly
   tappable to connect via that setup. The row's big Connect uses the default (star-marked)
   setup; long-press a chip to make it default.
2. **"+ Add setup"** chip on every camera row opens a mini-wizard scoped to that camera: pick
   the transport, do only that transport's steps (USB: plug in; AP: join+confirm; router:
   pick/confirm network, camera-side profile guidance). Adding USB-C to an AP camera no longer
   means re-running first-pair.
3. **Per-setup availability**: each chip carries its own dot — infrastructure: discovered on
   the current network; USB: cable attached; AP: joinable; hotspot: hotspot up. "Offline" stops
   being one ambiguous word for four different situations.
4. **Per-setup management** in the ••• sheet: rename, forget a single setup, set default.
5. **Structural safety**: connecting a setup can only run its own connector — the Router chip
   cannot produce an AP join prompt, by construction rather than by gate.

## Migration stages (each shippable, each hardware-checkpointed)

| Stage | Content | Risk |
|---|---|---|
| 0 ✅ | Stopgaps shipped 2026-08-02: declined-join session mute; hangup→re-pair fallback | low |
| 1 | Core `CameraTransport`/`CameraSetup` + one-time record migration (pure, heavily tested); list renders from setups; old connect paths still run underneath | low |
| 2 | Extract `CameraAPConnector` + `InfrastructureConnector`; orchestrator dispatches; join machinery moves INSIDE the AP connector; delete the exclusion-chain gates | medium |
| 3 | Recovery/reconnect per connector; delete the session latch; hotspot + USB connectors | medium |
| 4 | Saved-cameras UX: chip-connect, add-setup mini-wizard, per-setup availability/management | low |
| 5 | Android: shared `CameraSetup` in core via facade; connector split on their side | medium |

Verification per stage: full core suite + new per-connector contract tests (each connector gets
"can never" tests — e.g. `InfrastructureConnector` has a compile-time-absent join surface,
asserted by API shape), two-sim relay regression, and an on-hardware checkpoint with the owner
before the next stage starts.

## Appendix: audit inventory (2026-08-02 sweep, both platforms)

**35 distinct topology-inference sites** — each becomes connector-internal or is deleted:

- **SSID-shape / "NIKON" matching — 21 sites.** 11 in the shared core (`CameraWiFiSSID`:
  prefix constants, name→SSID derivation, `isNikonZAccessPoint`, OCR brand repair, the
  brand-prefix proactive fallback; `CameraWiFiScreenParser` synthesis), 5 in iOS
  (`cameraAccessPointSSID` 3-tier inference, evidence stamping, identity gates), 4 in Android
  (`CameraApJoiner.looksLikeNikonAccessPointSsid` — a SECOND, laxer reimplementation of the
  core's matcher rather than a facade call), 1 in the facade. Destination: all of it inside
  `CameraAPConnector` (iOS) / its Android twin; the core keeps ONE matcher both call.
- **Subnet constants — 14 sites.** `192.168.1.1` as the AP host in 9 places across three
  languages; `172.20.10/24` as hotspot proof; two private-range scan filters; two dedupe
  policies reasoning from shared addresses. Destination: one constant per connector.
- **Free-text inference — 4 sites.** `usesIPhoneHotspot` substring-matches the transport
  string; hotspot detection via `bridge*` interface-name prefix; transport kind from a `usb:`
  host-key prefix; Android escalates to first-time pairing by substring-matching failure
  message text (`SavedCamerasExperience.kt:459`). All deleted by typed transports and typed
  establishment errors.

**Where each platform actually stands**

- Android is CLOSER than expected: it has a typed wizard enum (`PairingPath`, 5 cases) AND a
  typed persisted enum (`SavedCameraTransport`) — but the persisted one has only 3 cases, and
  the wizard→persistence mapping (`PairingExperience.kt:964`) collapses Router into
  `PHONE_HOTSPOT`. Android's version of the iOS "Wi-Fi" string collapse, one line, high
  leverage. Its `resolvedHost` (`SavedCamerasExperience.kt:194`) is already the natural
  connector boundary.
- iOS declares intent at wizard time (`FirstPairTransportMethod`) and DESTROYS it at
  `transportLabel(for:)` (`NativeAppRoot.swift:4210`), which mints the persisted string from
  the discovery source. Everything downstream is reconstruction. `cameraAccessPointSSID`
  (`NativeAppRoot.swift:3760`) is the natural seam for the AP connector.

**Live divergences found by the sweep (fixed/known)**

1. ✅ FIXED in this commit: Android's discovery filter excluded `10/8` while the shared core
   deliberately includes it for set routers (its comment claimed the core agreed — stale). A
   camera on a 10.x router was iOS-visible and Android-invisible.
2. OPEN (folds into Stage 5): Android's `looksLikeNikonAccessPointSsid` is laxer than the
   core's `isNikonZAccessPoint`; unify on the core matcher through the facade.
3. OPEN (folds into Stage 1): Android's persisted-enum collapse of Router→Hotspot mirrors the
   iOS string collapse — both replaced by `CameraTransport`.
