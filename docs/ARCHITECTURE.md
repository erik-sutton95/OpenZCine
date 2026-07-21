# Architecture — OpenZCine

## Overview

OpenZCine uses a portable Swift business/protocol core with native SwiftUI and Jetpack Compose
shells. iOS consumes the core directly. Android packages the same core with the Swift SDK for
Android and exposes a deliberately small Swift facade/JNI boundary to Kotlin.

## Layer Map

The iOS dev guide describes a canonical `MyApp/App/Features/Core/Resources` directory layout.
**That directory rename is NOT applied to this repository** (see the deviation note below).
Instead, the guide's organizing principles map onto the existing tree as follows:

| Guide layer | This repo path | Purpose |
| --- | --- | --- |
| App | `ios/Runner` | SwiftUI `@main` entry point, scene setup, app lifecycle |
| Features | `ios/Runner` | Feature views, view models, coordinators, overlays |
| Resources | `ios/Runner` | Asset catalogues, localisation strings, `Info.plist` |
| Core | `Sources/OpenZCineCore` | Portable camera protocol, state machines, business logic |
| Core tests | `Tests/OpenZCineCoreTests` | Swift Testing suite for the shared core |
| Shell tests | `ios/RunnerTests` | Swift Testing suite for the iOS shell |
| Android facade | `Sources/OpenZCineAndroidFacade` | Swift-owned Android sessions and JNI wires |
| Facade tests | `Tests/OpenZCineAndroidFacadeTests` | Swift tests for Android transport/session wires |
| Android app | `Apps/Android/app` | Compose phone shell, lifecycle, rendering, storage, and adapters |
| Android API | `Apps/Android/core-api` | Typed Kotlin interface between the app and camera session |
| Wear OS | `Apps/Android/wear`, `Apps/Android/wear-relay` | Wear UI and phone-mediated relay |
| Android tests | `Apps/Android/*/src/test`, `Apps/Android/*/src/androidTest` | JVM policy tests and device UI tests |

## Portable Core Rule

`Sources/OpenZCineCore` **must remain UI-free and platform-agnostic.** It must never import:

- SwiftUI, UIKit, AppKit
- Android, Compose, or any Android-platform framework
- Any framework that is not available across all target platforms

Platform adapters own sockets, permissions, lifecycle, rendering, storage, and all UI. The
interop boundary between core and shell must be kept as narrow as possible.

## iOS Shell Standards (`ios/Runner`)

All new code in the iOS shell follows these conventions:

### State Management

- **`@Observable`** (Observation framework, Swift 5.9+) — the only pattern for observable state
  in new code. `ObservableObject` / `@Published` are deprecated.
- **`@Bindable`** — for two-way bindings from `@Observable` models into child views.
- State that belongs to the core is owned there; the shell holds only UI-layer state.

### Navigation

- **`NavigationStack`** with typed `NavigationPath` for all navigation hierarchies.
- `NavigationView` is deprecated and must not appear in new code.

### Concurrency

- **`async/await`** for all asynchronous work. No Combine for new code.
- Swift 6.0 strict concurrency: annotate actors, isolate state correctly, eliminate data races.
- Long-running network tasks (PTP-IP socket read loops) run on a dedicated `Actor` in the core.

### Error Handling

- **Typed `LocalizedError`** conformances for all user-facing error presentation.
- No raw string errors or force-unwrapping without a `// SAFETY:` justification comment.

### Testing

- **Swift Testing** (`import Testing`, `#expect`, `#require`) for all new tests.
- XCTest is acceptable only when integrating with existing test targets not yet migrated.
- ViewModels must have unit tests covering their core logic.
- Critical user flows (camera connection, record start/stop, live-view activation) must have
  UI-level integration tests.
- 80 % or higher line coverage target for `Sources/OpenZCineCore`.

## Android Shell Standards (`Apps/Android`)

- Jetpack Compose owns UI and app-local presentation state; Kotlin never packs PTP commands or
  invents camera property values.
- `core-api` defines the typed Kotlin session boundary. `OpenZCineAndroidFacade` owns PTP session
  serialization, raw protocol values, transport framing, and JNI memory/lifetime rules.
- Android adapters own NSD, USB Host, permissions, CameraX/ML Kit, Keystore, MediaStore, lifecycle,
  rendering, and platform share surfaces.
- JVM tests cover pure state/policy. Instrumentation tests cover critical Compose and Android
  platform integration, and UI changes require portrait/landscape edge inspection.

## iOS orientation and unified monitor

Portrait is unlocked app-wide (alongside the existing landscape orientation); it is not a
separate mode or feature flag. Each screen in `ios/Runner` decides its own layout by reading its
own `GeometryReader` and branching on `height > width` — there is no shared orientation service or
environment value.

### The unified monitor shell

The live-view monitor is a single view tree, `MonitorShell(context:)`
(`ios/Runner/MonitorUnified.swift`), that renders both landscape and portrait from one body —
there are no separate landscape/portrait shell structs and no feature flag selecting between them.
`MonitorShell` computes a `MonitorZoneMap` once per layout pass via
`MonitorZoneLayout.map(...)` (`Sources/OpenZCineCore/MonitorZoneLayout.swift`) and mounts each
unified module (`MonitorInfoBar`, `MonitorCaptureStrip`, `MonitorAssistStrip`,
`MonitorSystemCluster`, `MonitorScopes`, plus the shared feed/command/panel views) at the frame
and style hint the map returns for that zone; a `nil` zone stays unmounted.

`MonitorZoneLayout.map(...)` is a pure **adapter, not a re-derivation**: it delegates to the two
original layout policies — `MonitorLiveViewModuleLayout.fit(...)` for landscape,
`MonitorPortraitLayout.zones(...)` for portrait — and normalizes their outputs into one zone
vocabulary (frame + style hint, e.g. `.infoPill`/`.infoBar`, `.axisHorizontal`/`.axisVertical`,
`.scopesFloating`/`.scopesStacked`). Both policies remain in the portable core, UI-free and
unit-tested by their own long-standing suites (500+ tests) plus a golden-parity suite
(`Tests/OpenZCineCoreTests/MonitorZoneLayoutTests.swift`) that asserts the map's frames equal the
legacy policies' outputs exactly for a fixture matrix (both orientations, all DISP modes, portrait
aspect × scope-count combinations). No new layout math was invented to unify the shells — only the
container/mounting layer changed.

Rotation is a **geometry change under stable view identity**, not a tree swap: `LiveViewShell`
(`ios/Runner/MonitorExperience.swift`) mounts one `MonitorShell(context:)` with
`.animation(.easeInOut(duration: 0.3), value: context.isPortrait)`, so every module glides to its
new zone frame when `context.isPortrait` flips. There is no `matchedGeometryEffect`, no rotation
namespace, and no hero-tag plumbing — earlier "rung 2" approximated the morph with matched-geometry
heroes across two parallel shells; unification replaced that with the real thing.

Android follows the same product model in one Compose `MonitorScreen` tree. It calls the shared
Swift monitor-zone map through the facade, retains state across configuration changes, and keeps
feed, focus, framing, scope, and chrome geometry registered to the same fit/fill content rectangle.

**Portrait monitor v2 (live mode)** is the zone shape `MonitorPortraitLayout.zones(...)` produces:
a top bar overlaid on the feed, the feed itself (pinch-toggled between `.fit16x9` and a
center-crop `.fill`), a dynamic scopes region, and a persistent 100pt bottom system bar (a
`LiveDesign.glass` band that runs to the physical bottom edge, clearing the record button and the
home-indicator area) — the tile grid (fit) or capture bar (fill) fills whatever height those leave.
Clean and command modes keep the pre-v2 structure.

Fit and fill diverge on how scopes render, matched by `OperatorPreferences.scopeActivationOrder`
(persisted, oldest→newest activation, maintained by `AssistToolActivation.set` for
`MonitorAssistTool.scopeTools` only):

- **Fit** stacks `OperatorPreferences.displayedFitScopes` — the 2 *most recently activated* scope
  tools (re-sorted into canonical order for display), capped regardless of how many are actually
  active. Below the scopes zone, fit mounts a live-only, chrome-gated horizontal assist toolbar
  (`MonitorAssistStrip(axis: .horizontal)`, zone `assistStrip`) that sits between the scopes and
  the tile grid and slides down as the scopes region grows — the toolbar is dormant (zero height)
  outside `.live` or when `displayChrome.assistToolbarVisible` is off. With ≥2 scopes displayed,
  `NativeAppModel.scopeCapActive` refuses further scope activations in fit: the blocked toolbar
  buttons render at ~0.35 opacity (still tappable) and a tap fires a self-dissolving
  `MonitorToast` ("2 scopes max in fit view — close one or pinch to fill"). Scopes beyond the 2
  displayed stay active-but-hidden rather than being dropped.
- **Fill** mounts the landscape-identical floating `MonitorScopes(.scopesFloating)` panels —
  draggable, resizable, uncapped — over the visible (post-crop) feed region; every active scope
  tool floats, including ones fit was hiding. Pinching between fit and fill destroys no state:
  `scopeActivationOrder` is the single source of truth both modes read from.

### Camera load management

`NativeAppModel` stops live view with `EndLiveView` whenever the feed is completely hidden (command
mode or a full-screen monitor panel), then resumes it only when the operator can see it again. While
recording, property polling is restricted to battery, external-power, and warning status at a low
cadence; storage refreshes every 15 seconds and mode/lens descriptors every 60 seconds outside a
take. Pending writes coalesce by PTP property so only an operator's latest queued value reaches the
camera.

The preview stream—not the camera-card recording—is capped to VGA during a take and stepped down
further for serious/critical phone thermal state. Nikon `WarningStatus` (`0xD102`) is polled and
shown as `OK`/`CHECK`; the body-specific thermal bit and the `MovieRecordInterrupted` error-value
table remain **verify-on-hardware**, so they are surfaced without guessing their meaning.

### ADR-001 — Platform PTP-IP socket adapters

The iOS PTP-IP adapter uses Apple's Network.framework TCP sockets directly. The Android Swift
facade uses its platform socket API and retains the same transaction/session policy. No
third-party networking library is introduced, and portable protocol/business rules stay outside
either platform socket implementation.

### ADR-002 — Stable appGUID for Camera Pairing

The camera stores a GUID from the client's Init Command request. A random GUID on every launch
would force the camera into re-pairing mode each time. The app persists a stable `appGUID` in the
iOS Keychain (shell responsibility) and passes it to the core connection API so the camera
recognises returning clients without operator intervention.

### ADR-003 — Shared Core, Platform Shells

Business logic and protocol state live in `Sources/OpenZCineCore`. Platform shells (`ios/Runner`,
`Apps/Android`) own rendering, UI state, and platform lifecycle. Android reuses the core through
the Swift SDK for Android and `Sources/OpenZCineAndroidFacade` without duplicating protocol logic.

### ADR-004 — Flutter Prototype Archived

The Flutter prototype at `reference/flutter-prototype/` is retained only as a protocol and
live-view implementation reference while it remains useful. It is not built or tested in CI and
must not be treated as a production target.

### ADR-005 — Transaction-Level CameraTransport Boundary (Wi-Fi + USB-C)

Wi-Fi (PTP-IP) and USB-C share one session layer behind the portable `CameraTransport` protocol
(`Sources/OpenZCineCore/CameraTransport.swift`). The protocol is **transaction-level** — one call
executes a whole PTP transaction (command + optional data + response) and a separate call reads
the next camera event — because iOS exposes USB PTP only through ImageCaptureCore's
`ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`, which owns the USB endpoints and
runs one full transaction per call. Packet-level control is not available over USB on iOS, so the
shared abstraction cannot sit any lower.

- `ios/Runner/PTPIPTransport.swift` — Wi-Fi implementation: dual TCP sockets, the PTP-IP
  Init_Command/Init_Event handshake, and PTP-IP container framing.
- `ios/Runner/USBCameraTransport.swift` — USB-C implementation: `ICDeviceBrowser` discovery and
  authorization, PIMA 15740 generic containers (`PTPUSBContainer` in the core) over
  `requestSendPTPCommand`, and `ptpEventHandler` bridged into the event drain.
- `NativeCameraSession` keeps orchestration only (open/pair/identify, live view, keep-alive) and
  is transport-agnostic.
- `Apps/Android/app/.../transport` owns Android NSD and USB Host discovery plus raw socket/USB byte
  adapters. It does not build PTP operations locally.
- `Sources/OpenZCineAndroidFacade` owns Android PTP-IP and USB transaction/session serialization,
  response validation, event draining, and the narrow JNI records consumed by `core-api`.

USB cameras are identified by stable `usb:<device-id>` host keys in discovery results and saved
camera records (`transport: "USB-C"`), so startup policies can skip network probing for tethered
bodies and reconnect them silently on plug-in.

### ADR-006 — Bug-Report Paths and Relay

Bug reports are intentionally a platform-shell concern, not a portable-core feature. **Report a
Problem** offers two public GitHub-issue paths: an anonymous in-app form and the signed-in
[GitHub bug-report form](https://github.com/erik-sutton95/OpenZCine/issues/new?template=bug_report.yml). The anonymous
form sends the report text the operator supplies plus a small, closed set of app/platform fields.
It never ships a GitHub credential, installation identifier, raw diagnostics, arbitrary logs,
camera identity, or network identifier. Operators can explicitly opt into a closed
privacy-filtered activity snapshot containing lifecycle events and allowlisted error/warning codes,
or user-selected screenshots. The relay expands incident codes into fixed operational traces; it
never receives raw runtime stacks, exception messages, paths, addresses, or timestamps. The apps
re-render selected screenshots with generic filenames and no embedded file metadata; a server-side canonicalizer
enforces that boundary again. Screenshot pixels may still contain sensitive information, so the UI
requires a public-sharing warning and review. The signed-in route hands richer optional details and
attachments directly to GitHub. Local diagnostics remain a separate user-reviewed share flow.

`services/bug-relay` is an independently deployable Cloudflare Worker. It validates the narrow
wire contract, rate-limits anonymous submissions, makes retries idempotent, and uses a private
GitHub App installation with only Issues access to create a labelled public issue. Canonical PNG
screenshots are kept in a private R2 bucket and are exposed only through opaque relay URLs embedded
in the public issue; no original source image or filename is retained. The GitHub App private key
remains a Worker secret; neither mobile binary can create an issue directly. The separate
feature-request links continue to open GitHub Discussions, where accounts remain required for
attributable conversation.

## Deviations from the iOS Dev Guide

> **Directory-rename deviation:** The iOS dev guide's `MyApp/App/Features/Core/Resources`
> directory structure assumes a single Xcode target where all layers live under one source root.
> **This rename is NOT applied here** for two reasons:
>
> 1. `Sources/OpenZCineCore` is a Swift Package Manager target defined in `Package.swift`. Renaming
>    it would break the SPM manifest, the Xcode workspace, and any downstream consumers of the
>    package as a library.
> 2. The portable-core rule (ADR-003) requires a hard physical boundary between the core and all
>    platform-specific code. Collapsing them into a single source tree under `ios/Runner` or a
>    monolithic `MyApp/` directory would undermine that boundary.
>
> The guide's organizing principle — separating App/Features/Resources from Core — is fully
> honoured. It is mapped onto `ios/Runner` (App + Features + Resources) and
> `Sources/OpenZCineCore` (Core), preserving both the intent and the existing tool integration.

## Reference documentation

- [`docs/red-log3g10-reference.md`](red-log3g10-reference.md) — RED Log3G10 / RWG summary, exposure
  scale anchors, and links to RED's official white papers (used by false colour, scopes, and R3D
  proxy workflows).
