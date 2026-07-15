# Android core feasibility: Swift core reuse vs Kotlin PTP-IP port

Status: **CONFIRMED** — the cross-compile experiment passed (see the addendum at the end).
Scope: gates the Android epic ([discussion #19](https://github.com/erik-sutton95/OpenZCine/discussions/19),
issues #69–#81). Tracked as issue #68 / Kaneo OPE-25.

## Question

The Android app needs the camera brain: PTP-IP/MTP protocol codecs, session state, monitor layout
math, LUT/scope/assist math, and connection policies. Do we compile the existing
`Sources/OpenZCineCore` for Android with the official Swift SDK for Android and call it from a
Kotlin/Compose shell, or port that logic to Kotlin?

## Part A — core portability audit (repo ground truth, audited 2026-07-14)

### Inventory

`Sources/OpenZCineCore`: **55 Swift files, 12,450 LOC**, plus **58 test files, 9,045 LOC** in
`Tests/OpenZCineCoreTests`. Swift 6 language mode, strict concurrency (`Sendable` throughout,
value types, `async/await` protocol boundaries; no actors declared in the core itself).

Imports, exhaustively:

| Import | Files | Notes |
| --- | --- | --- |
| `Foundation` | 51 | `Data`, `Codable`/JSON, `URL(Components)`, `Date` — no `URLSession`, no `FileManager`, no `NotificationCenter`, no `DispatchQueue` |
| `CryptoKit` | 1 | `FrameioOAuth.swift`, one `SHA256.hash` for the PKCE S256 challenge |

That is the complete list. **No** CoreImage/CoreGraphics/CoreMedia, **no** Network.framework,
**no** Combine, **no** Keychain, **no** OSLog anywhere in the core. The AGENTS.md "UI-free and
portable" claim holds file by file. The single non-portable dependency, `CryptoKit`, is fixed by
swapping to [swift-crypto](https://github.com/apple/swift-crypto) (`import Crypto`) on non-Apple
platforms — API-compatible by design, a conditional import plus one package dependency.

Persistence and platform state are already outside the core: `PTPIPPairedHosts` and
`OperatorPreferences` are pure value/list manipulation over data the shell stores;
`ThermalLoadPolicy` takes an abstract thermal level the shell maps from `ProcessInfo.ThermalState`;
credentials live in the iOS shell's `CameraWiFiCredentialStore` (Keychain). Nothing in the core
needs an Android Keychain equivalent.

### What's in it (bucketed by porting cost)

| Bucket | ~LOC | Files (largest) | Porting character |
| --- | --- | --- | --- |
| PTP-IP / MTP protocol codecs + session records | ~4,800 | `PTPCameraProperties` (1,434), `PTPLiveViewObject`, `PTPIPSavedCameraRecords`, `PTPOperation`, `PTPIPHandshake`, `PTPUSBContainer`, `PTPIPPacket/Transaction/ReadBuffer`, `ByteCoding` | Dense, byte-exact, hardware-verified against a real ZR. Highest-risk to re-implement; every Nikon property encoding quirk would need re-validation on hardware. |
| Monitor layout math | ~2,000 | `MonitorLayoutPolicy` (1,160), `MonitorZoneLayout`, `MonitorPortraitLayout` | Pure geometry with 500+ tests incl. golden-parity suites. Mechanical but large; a Kotlin copy drifts the moment iOS layout changes. |
| Image/assist math | ~2,500 | `FalseColor` (636), `ScopeSampler`, `ExposureScale`, `CubeLUT`, `MonitorLUT`, `TrafficLightsMeter`, `FocusAssist`, `MonitorDisplayToneMap` | Colorimetry verified against RED/N-Log specs. Numerically sensitive; float-for-float parity in Kotlin is achievable but every curve needs duplicate golden tests. |
| Connection/UX policies | ~2,200 | `OperatorPreferences` (1,362), `CameraLinkHealth`, `ReconnectBackoff`, `LiveViewWatchdog`, `ThermalLoadPolicy`, `ISOPickerPolicy` | Simple individually, but they encode months of hardware-derived tuning (reconnect settle, link scoring, watchdogs). |
| Media / R3D parsing | ~270 | `MediaClipFilename`, `R3DHeaderParser`, `R3DClipIndex` | Small binary parsers. |
| Integration protocols | ~530 | `FrameioOAuth`, `FrameioModels`, `WatchRelayProtocol` | Frame.io models port easily; `WatchRelayProtocol` is iOS/watchOS-only and simply isn't compiled/used on Android. |

### Interop surface an Android shell needs

On iOS the shell owns exactly what AGENTS.md says it should: sockets
(`ios/Runner/PTPIPTransport.swift`, 627 LOC, `import Darwin` — implements the core's
`CameraTransport` protocol at the whole-transaction level), USB
(`USBCameraTransport.swift` over ImageCaptureCore), discovery plumbing, decode/render
(Metal/CoreImage), storage, permissions, UI. The core's `CameraTransport` protocol
(`Sources/OpenZCineCore/CameraTransport.swift`) is the narrow waist:
`executeTransaction(...) -> PTPIPTransactionResult`, `nextEvent() -> PTPEvent`, `close()`.

**Kotlin must implement natively regardless of the decision** (this is the decision-independent
work list):

- Wi-Fi join UX: `WifiNetworkSpecifier`/`ConnectivityManager` camera-AP join, phone-hotspot path,
  local-network permissions (#70).
- mDNS/NSD discovery via `NsdManager` (or a Swift mDNS responder later) feeding host/name strings
  into the session layer (#69, platform half).
- Live-view frame decode + render: MediaCodec/BitmapFactory JPEG decode, GPU compositing of
  LUT/false-color/peaking, Compose integration (#71) — iOS renders with Metal/CoreImage; none of
  that is in the core on either platform.
- The entire Compose shell: monitor chrome, rotation, DISP modes (#72), playback/media UI (#77
  UI half), preferences storage (DataStore), credential storage (Android Keystore /
  EncryptedSharedPreferences), OAuth browser flow (Custom Tabs), lifecycle/foreground-service
  handling.
- USB host transport is now implemented in `Apps/Android/app/.../transport/`: Kotlin owns
  `UsbManager` attach/detach, Android's per-device consent, Still Image/PTP endpoint claim, and
  raw bulk/interrupt bytes; `Sources/OpenZCineAndroidFacade/AndroidUSBPTPTransport.swift` owns
  generic PTP container framing and session policy. A USB serial is read only after Android grants
  access and becomes a local SHA-256 reconnect digest; the raw serial is never saved, shown,
  logged, or sent over the network. **[VERIFY-ON-HW]** Nikon cable/session behavior remains a
  physical-device validation item, not a claimed compatibility result.

**What Kotlin would call in the core** (the reuse surface): session open/close +
`CameraTransport` execution, `PTPIPHandshake` framing, `PTPCameraProperties`
encode/decode (ISO/WB/shutter/codec/battery...), `PTPLiveViewObject` frame extraction,
`PTPEvent` parsing, `MonitorZoneLayout.map(...)` + layout policies, `CubeLUT`/`MonitorLUT`/
`MonitorDisplayToneMap` LUT parsing and curve math, `ScopeSampler`/`FalseColor`/`FocusAssist`
sample math, `CameraLinkHealth`/`ReconnectBackoff`/`LiveViewWatchdog` policies,
`PTPIPSavedCameraRecords` codecs, media/R3D parsers.

### Where sockets go under core reuse

Two viable shapes:

1. **Sockets in Kotlin**, PTP framing in Swift — chatty JNI boundary on the hot live-view path
   (a frame fetch is several transactions); rejected as the default.
2. **Sockets in Swift on Android** — POSIX/BSD sockets work under bionic; the iOS
   `PTPIPTransport` already sits on raw `Darwin` sockets, so an Android twin is a near-copy with
   `Glibc`/`Android` imports. The whole session (transport + framing + state) then lives in one
   Swift library, and the JNI surface collapses to a **coarse facade**: connect/disconnect,
   property get/set, an event callback, and a "next live-view JPEG frame" byte-buffer pull.
   This is the recommended boundary — few calls per frame, byte arrays and simple enums only.

### Honest Kotlin-port estimate

A faithful port is not "the PTP-IP layer" — the epic needs layout math, LUT/scope math, and
policies too. Realistic scope: **~10–11k LOC of dense, hardware-calibrated logic plus ~9k LOC of
tests re-written in Kotlin**, then re-verified against a physical ZR (the property encodings and
reconnect behaviors were debugged on hardware; a port re-opens every one of those). Ongoing cost
is worse than the initial cost: every core change ships twice, with drift caught only by duplicate
golden tests. The one genuinely cheap Kotlin subset would be "transport + handshake + record
start/stop" (~1.5k LOC) — enough for a demo, but the epic's assist-parity goals (#73) pull in the
expensive buckets immediately.

## Part B — Swift SDK for Android state (public sources, checked 2026-07-14)

### Toolchain status

- The Swift SDK for Android is **officially released, not experimental**: Swift 6.3
  (released 2026-03-24) contains the first official release of the SDK
  ([swift.org 6.3 release post](https://www.swift.org/blog/swift-6.3-released/)), after the
  [Oct 2025 nightly-preview announcement](https://www.swift.org/blog/nightly-swift-sdk-for-android/)
  and the [Android workgroup](https://forums.swift.org/t/announcing-the-android-workgroup/80666)
  standing up official CI. Current bundle: 6.3.3. This matches the repo (Swift 6 language mode,
  local toolchain 6.3.x). Swift 6.2 and earlier were community-SDK only
  ([finagolfin/swift-android-sdk](https://github.com/finagolfin/swift-android-sdk), which now
  points users at the official SDK).
- Install: `swift sdk install <download.swift.org artifactbundle URL>` plus Android NDK **r27d+**;
  build with `swift build --swift-sdk aarch64-unknown-linux-android28`
  ([getting-started guide](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)).
  Cross-compiles from macOS (OSS toolchain, not Xcode's) or Linux. ABIs demonstrated officially:
  arm64 + x86_64, API level 28 triples.

### Foundation coverage vs this core

Android gets the modular non-Darwin Foundation: `FoundationEssentials` (Data, Codable/JSON, URL,
Date — the swift-foundation rewrite) plus optional Internationalization/Networking/XML modules
([Skip porting notes](https://skip.dev/docs/porting/)). Mapping to the audit above:

- Everything the core uses (`Data`, `Codable`, `URLComponents`, `Date`) is `FoundationEssentials`.
  The known Android Foundation gaps — `URLSession` CA-certificate discovery, `FileManager` quirks,
  bionic libc differences — are **all in APIs this core does not use**. Frame.io HTTP calls stay
  in the shell (the Android adapter uses `HttpURLConnection`; iOS uses `URLSession`), while the
  portable core owns PKCE, OAuth form construction, endpoint paths, and Codable models.
- `CryptoKit` becomes `swift-crypto`: one conditional import.
- ICU is the headline size risk (`lib_FoundationICU.so` historically ~40 MB,
  [forums thread](https://forums.swift.org/t/android-app-size-and-lib-foundationicu-so/78399)) —
  but the core uses **no** `Locale`/`Calendar`/`DateFormatter`/`NumberFormatter` at all; its only
  format-ish API is 8 `String(format:)` call sites, trivially replaceable if they turn out to pull
  the Internationalization module in. Whether the build links ICU is a **build-experiment check**.
- Swift runtime `.so` payload: ~15 MB uncompressed per ABI per third-party measurements
  ([ignit.group](https://ignit.group/blog/swift-on-android-a-practical-use-case)); no official
  figure published. With an arm64-only internal track that is acceptable for this app class.

### Interop (Kotlin to Swift and back)

- [swift-java](https://github.com/swiftlang/swift-java) ships `jextract` with a **JNI mode**
  (the Android path), generating Java/Kotlin-callable wrappers and supporting callbacks from
  Java back into Swift; the Swift 6.3 release notes explicitly bless it for integrating Swift
  into Kotlin/Java Android apps. Official end-to-end samples (Gradle wiring, callbacks) live in
  [swiftlang/swift-android-examples](https://github.com/swiftlang/swift-android-examples)
  (`hello-swift-java`, `hello-swift-raw-jni-callback`, `swift-java-weather-app`).
- Maturity caveat: swift-java is **pre-1.0, no API-stability guarantee** (repo README). The
  fallback that removes this risk entirely is a handful of manual `@_cdecl` C shims plus
  hand-written JNI — viable precisely because the facade in this design is a dozen coarse
  functions, not a generated mirror of the whole core API. Community `.aar` packaging exists
  ([readdle/swift-android-gradle](https://github.com/readdle/swift-android-gradle), rebased on
  the official SDK; Skip's tooling likewise).

### CI, runtime, production users

- GitHub Actions: [skiptools/swift-android-action](https://github.com/skiptools/swift-android-action)
  cross-compiles and runs SwiftPM tests in an Android emulator on `ubuntu-latest` or Intel macOS
  runners (ARM macOS runners build but can't run the emulator). finagolfin runs daily CI the same
  way. So `Tests/OpenZCineCoreTests` (9k LOC) can run **unmodified on Android in CI** — the
  Kotlin port's "duplicate test suite" cost simply does not exist on this path.
- The SDK bundles stdlib plus **Dispatch and Foundation including the async/await concurrency
  runtime** ([workgroup FAQ post](https://www.swift.org/blog/exploring-the-swift-sdk-for-android/));
  no published strict-concurrency gaps on Android were found (absence of evidence — flagged in
  the unknowns below).
- Debugging is the weakest area: LLDB/Android-Studio integration was listed as *ongoing work* in
  the Dec 2025 workgroup post. Mitigation: the core is pure logic with a 9k-LOC test suite — debug
  on macOS, treat on-device Swift debugging as printf/logcat for now.
- Production users named by swift.org: **Spark (Readdle)**, **flowkey** (~10 years of Swift on
  Android), MediQuo, Naturitas — "downloaded millions of times" collectively.

## Decision

### Options compared

| Criterion | A: Reuse core via Swift SDK for Android | B: Kotlin port |
| --- | --- | --- |
| Core-logic fidelity / single source of truth | **Wins.** One codebase, one 9k-LOC test suite, zero drift; hardware-derived quirks fixed once | Permanent dual maintenance; every core change ships twice, drift caught only by duplicate golden tests |
| Toolchain risk | Real but shrinking: SDK officially released in Swift 6.3; swift-java pre-1.0 (manual JNI fallback exists) | **Wins.** Zero — Kotlin/AGP is boring |
| CI complexity | One extra job (`swift-android-action` on ubuntu-latest); core tests run as-is in the emulator | New ~9k-LOC Kotlin test rewrite plus a parity harness against the Swift suite |
| Contributor accessibility | Android contributors need Swift-cross-compile literacy for core changes (shell stays pure Kotlin/Compose) | **Wins.** Plain Kotlin throughout |
| Binary size | ~15 MB/ABI Swift runtime (+ICU only if linked — expected not; verify) | **Wins.** ~0 overhead |
| Debugging | Core: macOS-side (tests) + logcat on device; on-device LLDB still maturing | Android Studio native, first-class |
| Incremental delivery | Facade grows function by function; demo = transport + record quickly | Cheap demo subset (~1.5k LOC), then the expensive ~10k-LOC tail before assist parity |

### RECOMMENDATION — Option A: reuse `Sources/OpenZCineCore` via the Swift SDK for Android

The three facts that drove it:

1. **The core is already portable to an unusual degree** — 12,450 LOC importing nothing but
   Foundation (plus one swappable SHA256), no URLSession/FileManager/Keychain/locale APIs; it
   sits entirely inside `FoundationEssentials`, the best-supported slice of Android Foundation.
   The porting work AGENTS.md prescribed has already been paid for.
2. **The toolchain risk collapsed in March 2026**: the Swift SDK for Android is an official
   swift.org release on exactly this repo's Swift version (6.3), with GitHub Actions support that
   runs the existing 9k-LOC test suite in an Android emulator unmodified, and named production
   users (Spark, flowkey) at millions of installs.
3. **A Kotlin port is not 1.5k LOC of transport — it is ~10k LOC of hardware-calibrated codecs,
   colorimetry, and layout math plus a rewritten test suite**, then re-validation on a physical ZR
   of behaviors (Nikon property quirks, reconnect settle, curve math) that took months to debug on
   hardware. And it is a permanent tax, not a one-off.

Honest unknowns (all cheap to retire; none expected to flip the decision): whether the core build
links ICU (the 8 `String(format:)` sites are the only suspects — replaceable), swift-java API
churn before 1.0 (fallback: manual `@_cdecl`/JNI shims for a roughly dozen-function facade),
on-device debugging ergonomics, strict-concurrency runtime behavior on device, and the real arm64
`.so` size. **Confirmation step (follow-up task): a local cross-compile experiment** — install the
6.3.3 artifactbundle plus NDK r27d, run `swift build --swift-sdk
aarch64-unknown-linux-android28` on `OpenZCineCore` (with the CryptoKit-to-swift-crypto
conditional), run the test suite via `swift-android-action` or a local emulator, and measure the
`.so` payload. Only a failure there reopens Option B.

### Interop-boundary sketch (Option A)

```text
+---------------------------- Android app (Kotlin/Compose) ----------------------------+
| Compose monitor shell - NsdManager discovery - WifiNetworkSpecifier join             |
| MediaCodec/Bitmap JPEG decode - GPU compositing - DataStore/Keystore - OAuth UI      |
+-------------------+-------------------------------------------------------------------+
                    | JNI facade (~12 coarse functions; byte arrays + simple enums):
                    |   connect(host)/close - property get/set - record start/stop
                    |   nextLiveViewFrame() -> ByteArray - event callback - layout/LUT queries
+-------------------+---------------- libOpenZCineCore.so (Swift) ----------------------+
| AndroidPTPIPTransport (POSIX sockets - twin of ios/Runner/PTPIPTransport.swift)       |
| + everything in Sources/OpenZCineCore, unchanged                                      |
+---------------------------------------------------------------------------------------+
```

Boundary rules: coarse-grained calls only (no per-field JNI chatter); `Data`/byte-array and
primitive types across the seam; the live-view hot path is one call per frame; the facade lives in
a new target (e.g. `Sources/OpenZCineCoreAndroidFacade`) or `#if os(Android)` files so the core
itself stays untouched. Sockets go Swift-side (shape 2 above) to keep the whole transaction
machinery in one place — the iOS transport is already raw POSIX sockets, so the Android twin is a
near-copy, not new design.

### Implemented Android USB-host boundary

USB has a deliberately different platform ownership split because Android exposes host endpoints
through `UsbManager`, while the shared core's portable seam starts at a complete PTP transaction:

```text
Kotlin / Android APIs                         Swift Android facade + shared core
----------------------------------------      -----------------------------------------
UsbManager attach/detach + consent            PTP USB generic-container framing
Still Image/PTP interface + endpoints   -->   transaction IDs + data-phase validation
claim/release + raw bulk/interrupt I/O         OpenSession/pair/identify + event decoding
local USB host-key digest only                 camera operations and CloseSession policy
```

`AndroidUsbPtpCameraSource` discovers only a complete USB Still Image interface with bulk IN,
bulk OUT, and interrupt IN endpoints. It owns `UsbRequest` lifecycle and closes an active claim on
detach; the JNI raw-handle close path is intentionally able to interrupt an in-flight endpoint read
without waiting for that read's normal command timeout. Swift's `AndroidUSBPTPTransport` rejects
ambiguous data phases, retains fragmented/concatenated containers safely, and treats an idle
interrupt timeout as non-terminal so the next event can still arrive. Saved USB profiles store a
privacy-safe local `usb:<digest>` key and display only connection state, never that key or a raw
serial.

**[VERIFY-ON-HW]** This boundary has automated Kotlin/Swift coverage and a debug-only visual
fixture, but no supported Nikon body was attached for this implementation pass. Verify on a Nikon
ZR (or supported body) with a data-capable cable: Android permission denial/retry, interface
claim, event delivery through idle timeouts, detach during an active command/session, and the
CloseSession → OpenSession retry after app-control refusal.

### Phased plan mapped to the board

**Decision-independent (can start now, in Kotlin, regardless of A/B):**

- #70 pairing UX (Wi-Fi APIs, permissions, hotspot path — pure platform work).
- #71 decode/render spike (MediaCodec/GPU — the core never decoded pixels on iOS either).
- #72 Compose monitor shell (zone frames arrive as plain rects whichever brain computes them).
- #79 CI scaffolding for the Gradle build; #81 Play Console internal-track setup.

**Decision-dependent sequencing (Option A):**

1. **Phase 0 — cross-compile experiment** (the confirmation step above; blocks only Phase 1).
2. **Phase 1 — core `.so` + facade + transport** (#69): CryptoKit-to-swift-crypto conditional,
   Android socket transport, JNI facade, core tests green in the Android emulator on CI (the
   Swift half of #79). Exit: connect plus a property read on hardware.
3. **Phase 2 — live view end-to-end** (#71 wiring + #72): frame pull through the facade into
   MediaCodec/Compose; record start/stop.
4. **Phase 3 — assists** (#73): LUT/false-color/scope math already in the `.so`; Kotlin owns only
   GPU compositing and scope-trace rendering.
5. **Phase 4 — playback and media** (#77): media/R3D parsers from the `.so`; browse UI in Compose.
6. **Phase 5 — distribution** (#81): arm64-only internal track first; size audit before widening.

(Board duplicates #74/#75/#76/#78/#80 mirror #70/#71/#72/#73/#77 and follow them.)

## Source dates

swift.org sources span Oct 2025 – Mar 2026; skip.dev porting docs and the CI action are
current 2026; binary-size figures are 2026 third-party blogs, not official numbers.

## Experiment results (2026-07-14) — decision CONFIRMED

The Phase 0 confirmation experiment was run locally on an Apple Silicon Mac. Every unknown listed
in the decision section was retired; none flipped the decision.

### Versions used

| Component | Version |
| --- | --- |
| Swift toolchain (swiftly, swift.org open source) | 6.3.3 (`swift-6.3.3-RELEASE`) — the bundle requires an exact match; Xcode's 6.3.2 cannot drive it |
| Swift-on-Android artifactbundle | `swift-6.3.3-RELEASE_android` from download.swift.org (checksum-verified `swift sdk install`) |
| Android NDK | r27d (`setup-android-sdk.sh` links `ndk-sysroot` into the bundle) |
| Target triple | `aarch64-unknown-linux-android28` |
| swift-crypto | 3.15.1 (resolved from `from: "3.0.0"`) |
| Test device | Android emulator, API 28 `default;arm64-v8a` image, arm64 host (native, no translation) |

### Build outcome

`swift build --swift-sdk aarch64-unknown-linux-android28` (debug and release) **succeeds** for the
whole package — all 55 core files plus the 58 test files — after a three-file diff:

1. `Package.swift` — add `apple/swift-crypto` with the `Crypto` product gated
   `.when(platforms: [.linux, .android])`, so Darwin builds do not link it (a `Package.resolved`
   pin is the only Darwin-visible artifact).
2. `Sources/OpenZCineCore/Frameio/FrameioOAuth.swift` — `#if canImport(CryptoKit)` / `import
   Crypto` for the one SHA256 call, exactly as planned. **One surprise beyond the plan:** the
   audit missed that `URLRequest` (used by the three Frame.io token-request builders in this same
   file) lives in FoundationNetworking on non-Darwin. Importing FoundationNetworking works but
   drags libcurl/ICU into the payload and its static variant is missing from the 6.3.3 bundle
   (`-l_CFURLSessionInterface` link failure under `--static-swift-stdlib`). Since the Android
   shell owns HTTP through its platform adapter and would never consume `URLRequest`, the three builders are now
   `#if !os(Android)` instead; the pure PKCE/URL/parse logic compiles everywhere.
3. `Tests/OpenZCineCoreTests/FrameioOAuthTests.swift` — the two tests covering those builders get
   the same gate.

Darwin behavior is untouched: `just check` and `just native-check` are green, all 650 tests pass
on macOS.

### Binary size (release, arm64, stripped with `llvm-strip`)

| Artifact | Size |
| --- | --- |
| `libOpenZCineCore.so` (entire core + statically linked swift-crypto) | **3.9 MB** (20 MB unstripped) |
| Required runtime `.so` set from the bundle (as currently linked, incl. ICU) | 76.9 MB |
| — of which `lib_FoundationICU.so` 40.6 MB + `libFoundation.so` 8.6 MB + `libFoundationInternationalization.so` 3.6 MB | 52.8 MB |
| Same payload gzip-compressed (≈ download cost) | 26.6 MB |
| Runtime subset if the umbrella-Foundation symbols are migrated (see ICU below) | 24.1 MB |

`--static-swift-stdlib` does not apply when the product is a dynamic library (it silently keeps
dynamic runtime linking), so the shipped-runtime numbers above are the realistic packaging shape —
the same one the official swift-android-examples use (runtime `.so` files in `jniLibs`).

### ICU finding

ICU **is** currently linked, but not for the suspected reason. The 8 `String(format:)` sites (and
everything else) bind **zero** symbols from `libFoundationInternationalization.so` directly; the
`NEEDED` entries come from the umbrella `libFoundation.so`, which the build autolinks because 18
symbols resolve there rather than in `libFoundationEssentials.so` (which serves the other 88):
`String(format:)`, the static `CharacterSet` sets (`.whitespaces`, `.newlines`, …),
`NSString.pathExtension`/`lastPathComponent`/`deletingPathExtension`,
`StringProtocol.components(separatedBy:)`/`trimmingCharacters(in:)`/`caseInsensitiveCompare`/
`range(of:)`, and `Error.localizedDescription`. The umbrella hard-depends on Internationalization
and ICU, so they ride along (~53 MB uncompressed). All 18 call sites are mechanically replaceable
with Essentials-only equivalents, which would drop the per-ABI payload from ~82 MB to ~30 MB
uncompressed — worthwhile Phase 5 (size-audit) work, **not** a feasibility blocker.

### Test run on Android

The full core test suite was executed **on an Android 28 arm64 emulator** (headless, local): the
cross-built `OpenZCinePackageTests.xctest` executable plus the runtime `.so` set were pushed via
`adb` to `/data/local/tmp` and run with `--testing-library swift-testing`.

Result: **648 of 648 tests in 22 suites passed** (1.2 s) — the two gated URLRequest-builder tests
are Darwin-only by design, all other 648 run identically to macOS. Byte-exact protocol codecs,
layout golden-parity suites, and colorimetry curves all pass unmodified on Android. This also
retires the strict-concurrency-runtime unknown for everything the tests exercise.

### Verdict

**CONFIRMED — Option A stands.** The core cross-compiles with a three-file, Darwin-identical diff;
the artifact is 3.9 MB; the test suite passes on-device unmodified. Caveats carried forward:

- The runtime payload is ~82 MB/ABI uncompressed (~27 MB gzipped) until the 18 umbrella-Foundation
  call sites are migrated to Essentials-only APIs (→ ~30 MB); track under the Phase 5 size audit.
- `--static-swift-stdlib` is not usable for the `.so` packaging shape today; plan on shipping the
  runtime `.so` set like the official examples do.
- Do not reintroduce `import FoundationNetworking` into the core — it adds 16 MB, re-links ICU
  transitively, and its static archives are incomplete in the 6.3.3 bundle.
- swift-java/JNI facade and on-device debugging remain untested (Phase 1 scope, as planned).

### Phase 1 note (2026-07-14) — facade shape decided: manual JNI shims

swift-java/jextract was evaluated first, as planned, and set aside for now: the newest release is
0.4.2 (2026-06-26, pre-1.0, no API-stability guarantee), and its supporting Java libraries are
**not published to Maven Central** — consumers must clone swift-java and `./gradlew
publishToMavenLocal`, which is unacceptable as a build prerequisite for this repo's Gradle CI. For
a facade of a dozen coarse functions, hand-written `@_cdecl` shims
(`Sources/OpenZCineAndroidFacade`, importing the NDK's `<jni.h>` through the header-only `CJNI`
target) cost ~150 lines and zero new dependencies. Revisit jextract when its runtime jars reach
Maven Central and the API stabilizes; the facade surface is deliberately small enough to migrate.

**Session layer landed (2026-07-14):** the facade now carries the PTP-IP protocol/session slice
(`Sources/OpenZCineAndroidFacade/PTPIPClientSession.swift`), with sockets Swift-side per shape 2
above — the facade is the Android platform adapter, so a blocking POSIX twin of the iOS
`PTPIPSocket` lives inside it and the JNI surface stays coarse. Facade functions to date:

- `coreVersion()`, `deriveAccessPointSSID(name)`, `resolveDisplayName(name)`,
  `startConnectionDemo(listener)` (spike surface), and the session slice:
- `sessionConnect(host, listener)` — Init handshake on both channels + the Nikon
  open/pair/identify sequence (quiet saved-profile attempt, falling back to first-time pairing
  with the PIN pushed via the listener), phases mirroring `CameraConnectionPhase`;
- `sessionReadProperty(code)` — `GetDevicePropValueEx` decoded by the core
  (battery → percent, others raw hex until their display decoders are wired);
- `sessionDisconnect()` — best-effort `CloseSession` before dropping sockets (the iOS
  reconnect-wedge fix semantics);
- `sessionStartLiveView(listener)` / `sessionStopLiveView()` — a Swift-side frame pump on the
  session's command socket (`StartLiveView` + `DeviceReady` readiness poll, then
  `GetLiveViewImageEx` on an absolute-schedule ~30 fps poll ceiling), pushing JPEG bytes,
  monotonic timestamps, camera recording state, and optional stereo dBFS/peak-hold values to the
  Kotlin listener from one background thread. The Swift core alone maps Nikon's live-view
  sound-indicator bytes to dBFS; Kotlin receives only the resolved typed presentation payload.
  Backpressure is latest-wins by construction (frames are pulled, never queued); stop and
  disconnect both join the pump so `EndLiveView` always precedes `CloseSession` — the iOS
  heat-audit lesson (a hidden feed must end live view on the body) carried over.

The layer compiles on Darwin too, so `Tests/OpenZCineAndroidFacadeTests` exercises the same wire
behavior against a scripted fake ZR (`FakeZRServer`) in `swift test` — sequencing, the pairing
fallback, property decode, and graceful teardown; real-ZR validation of connect + property read
is the remaining hardware step.

### Release packaging (2026-07-14)

Android builds now cross-compile and stage the Swift core through a Gradle-owned task rather than
reading an ignored `src/main/jniLibs` directory. The release contract is explicit: ship only
**arm64-v8a**, built as `aarch64-unknown-linux-android29` for the app's Android 10 minimum. The
task uses the exact Swift 6.3.3 toolchain and `swift-6.3.3-RELEASE_android` SDK, copies the full
dynamic `NEEDED` closure, and records it for archive verification. `verifyReleaseNativeLibraries`
then checks the release APK and AAB entry lists without extracting either archive: every staged
library, including `libOpenZCineAndroid.so`, must be present under that ABI and no second ABI may
slip into a Play upload. The Android CI and Play-internal workflow install the same pinned SDK
before Gradle runs. A debug-device startup calls the existing `SwiftCoreSmoke` JNI round trip; it
remains a hardware smoke check because hosted x86 GitHub runners cannot load the arm64-only app.
`just android-bridge-smoke <adb-serial>` makes that check reproducible: it builds the generated
debug APK, installs it with data preserved, launches the app, and requires the arm64 core-version
line from logcat.
