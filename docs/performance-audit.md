# OpenZCine — Performance & Stability Audit

- **Date:** 2026-06-28
- **Branch audited:** `feat/lut`
- **Scope:** Full codebase — live-view pipeline, scope/LUT compute, SwiftUI rendering, PTP-IP networking & concurrency, memory & lifecycle.
- **Goal:** Maximum performance and stability for a field-monitor app that DPs and production depend on.

## Method

Five focused passes read the hot-path files in full (live-view pipeline, scope/LUT
compute, SwiftUI rendering, PTP-IP/concurrency, memory/lifecycle). Every load-bearing
claim below was then **verified directly against source** before being recorded — line
numbers and the "verified" notes reflect the code as of the audit date.

This is a **static** audit: it predicts hotspots with high confidence but does not measure
on-device milliseconds. On-device Instruments profiling (see *Validation* below) is the
required confirmation step.

## Verdict

The foundations are good — reconnect backoff, per-frame memory hygiene, CIContext/LUT
reuse, and connected-path task lifecycle are all done right. But there are **two silent,
time-dependent stability bugs that can fail a shoot** (event channel never drained; no
background handling), a **socket recursion that can crash under flaky Wi‑Fi**, and one
**root-cause architecture issue** — the entire live-view pipeline runs on the main thread —
that drives most of the performance symptoms.

## Remediation tracker

| ID | Severity | Title | Status |
| -- | -------- | ----- | ------ |
| P0-1 | Field-critical | PTP-IP event channel never drained | ✅ Fixed |
| P0-2 | Field-critical | No background/foreground lifecycle handling | ✅ Fixed |
| P0-3 | Field-critical | No whole-transaction deadline; command gate can wedge | ✅ Fixed |
| P0-4 | Field-critical | Socket receive self-recurses on `EAGAIN`/`EINTR` | ✅ Fixed |
| P0-5 | Field-critical | `.cube` LUT import has no size cap | ✅ Fixed |
| P1-1 | Performance | Per-frame main-thread work: decode + render + scopes (session is *already* off-main — see Correction) | ✅ decode (Phase A) + render (Win 1, gated) + scopes (P1-6) |
| P1-2 | Performance | Parser copies full frame 3× to read ~12 header bytes | ✅ Fixed |
| P1-3 | Performance | `cameraState` reassigned every frame → whole-HUD invalidation | ✅ Fixed |
| P1-4 | Performance | Render output never cached; re-renders on unrelated churn | 📋 Planned |
| P1-5 | Performance | `readExact` is O(n²) on large frames | ✅ Fixed |
| P1-6 | Performance | Scope downsample runs `CGContext.draw` on `@MainActor` | ✅ Fixed (FrameScopeSampler actor) |
| P2-1 | Hygiene | RED zip import buffers whole archive in RAM, on `@MainActor` | ✅ Fixed |
| P2-2 | Hygiene | `CameraPicker.allCases.first(where:)` linear scan in `body` | ✅ Fixed |
| P2-3 | Hygiene | Scene enumeration + layout `fit()` inside `body` per frame | 🔗 Fold into refactor (Phase B); mitigated by P1-3 |
| P2-4 | Hygiene | Socket I/O ignores `Task` cancellation; establish not cancellable | ✅ Partially fixed (2026-07-02): gate waits are cancellable, establishment is generation-guarded; raw syscalls stay deadline-bounded by P0-3 |
| P2-5 | Hygiene | Stale per-camera state survives reconnect | ✅ Fixed |
| P2-6 | Hygiene | Discovery loop polls every 0.85 s forever | ✅ Fixed |
| P2-7 | Hygiene | `AsyncSerialGate` leaks cancelled waiters; `@unchecked` invariant inaccurate | ✅ Fixed (2026-07-02) |

## Root cause behind most performance findings

> **Correction (2026-06-29).** The original audit claimed `NativeCameraSession` is `@MainActor`
> (citing line 84) and concluded "every per-frame operation runs on the main thread." **That is
> wrong.** Line 84's `@MainActor` annotates `NativeCameraConnectionStore`; `NativeCameraSession`
> (line 275) is a plain `@unchecked Sendable` class with nonisolated async methods. When the
> `@MainActor` model `await`s them they run on the global executor (SE-0338), so **PTP packet
> assembly and LiveViewObject parse were already off-main.** The actual per-frame *main-thread*
> costs were only three things: `UIImage(data:)` JPEG decode (on the model), the `createCGImage`
> Core Image render (in `updateUIView`), and scope sampling (on the model). They are addressed by
> **Phase A** (off-main decode ✅), **GPU Win 1** (Metal render, no readback, gated ✅), and **P1-6**
> (off-main scopes ✅). The `@MainActor`→`actor` conversion (refactor plan **Phase C**) is therefore
> **dropped** — its premise was false; it would add actor-hop overhead at real risk to a
> field-critical path for no benefit.

## P0 — Field-critical (can fail a shoot or crash). Verified

### P0-1 · PTP-IP event channel is opened but never read

`getEventEx` (opcode `0x941C`) is defined at `Sources/OpenZCineCore/PTPOperation.swift:60`
and has **zero call sites** in the repo. The event socket is established during handshake
(`ios/Runner/NativeCameraSession.swift:339`) and never drained again. PTP-IP cameras push
async events (record start/stop from the body, prop changes, capture-complete, store-full)
onto this dedicated channel; with no reader, the camera's send buffer backs up and —
firmware-dependent on the ZR — the session stalls or drops, deep into a long take.
**Fix:** a dedicated, cancellable event-drain loop bound to session lifecycle; tear it down
in `close()`.

### P0-2 · No background/foreground lifecycle handling

No `scenePhase` observer, no `didEnterBackground` — confirmed absent across `ios/Runner`.
When the phone is pocketed or locked mid-setup, the live-view loop, the 10 s keep-alive, the
discovery loop, and the per-frame GPU render all keep running with the screen off → worst-case
battery/thermal profile, and iOS eventually jetsam-kills the backgrounded app holding live
sockets + GPU. The code already gates the pipeline in command mode
(`ios/Runner/NativeAppRoot.swift:1319`).
**Fix:** `@Environment(\.scenePhase)` → on `.background` cancel live/keep-alive/discovery tasks
and `stopLiveView()` (keep the session object); on `.active` restart.

### P0-3 · A slow camera can wedge every command behind one transaction

Reads enforce a timeout *per `poll`* (`ios/Runner/NativeCameraSession.swift:1162`) but there
is **no whole-transaction deadline**, and `transact` holds the transaction gate. A camera/link
that dribbles bytes never trips the per-poll timeout, so record-stop, AF, and keep-alive queue
behind it — the operator hits **Stop and nothing happens** until the watchdog forces a full
reconnect.
**Fix:** an overall per-transaction deadline + cancellable in-flight reads.

### P0-4 · Socket receive self-recurses on `EAGAIN`/`EINTR` → stack-overflow crash

`ios/Runner/NativeCameraSession.swift:1155` calls `receiveOnQueue` recursively on a transient
errno, and `waitForDescriptor` returns "ready" even when `POLLIN` wasn't the actual revent
(`ios/Runner/NativeCameraSession.swift:1170`) — the classic spurious-wakeup path. A flaky AP
can spin this until the socket-queue thread's stack overflows — a hard, unrecoverable crash.
**Fix:** convert both `receiveOnQueue` and `waitForDescriptor` from recursion to `while` loops.

### P0-5 · `.cube` LUT import has no size cap

`CubeLUT.parse` reads `LUT_3D_SIZE` (`Sources/OpenZCineCore/CubeLUT.swift:53`) with no upper
bound; a malformed or hostile file declaring a huge size drives an unbounded `[Float]`
allocation → OOM. Separately, a valid cube >64 is silently dropped at render time (CIColorCube
caps `inputCubeDimension` at 64). DPs import third-party RED/Nikon LUT packs, so this is a real
input.
**Fix:** clamp/validate `size` to `2...64`, throw a typed error above it (early, before the
data block is accumulated).

## P1 — Performance (degrades the monitor: jank, lag, thermals, battery). Verified

- **P1-1 · Whole live-view pipeline on `@MainActor`** — the root cause above. With a LUT +
  peaking active (the common grading case), the synchronous `createCGImage` readback on main
  caps achievable FPS and spikes thermals on long takes.
- **P1-2 · Parser copies the full multi-MB frame 3× per frame to read ~12 header bytes** —
  `Array(liveViewObject)` at `Sources/OpenZCineCore/PTPLiveViewObject.swift:208`, `:217`,
  `:241` each materialize the entire ~0.5–2 MB LiveViewObject just to read header offsets —
  ~45–180 MB/sec of transient allocation on the main thread. **Fix:** slice the small header
  prefix once and read via indexed subscript / `withUnsafeBytes`.
- **P1-3 · `cameraState` reassigned wholesale every frame** — `cameraState = cameraState.updating(...)`
  runs per frame (`ios/Runner/NativeAppRoot.swift:1311`, `:1359`, `:1466`). It's a 13-field
  value type; replacing it dirties every keypath, so every chrome view reading any field
  re-evaluates its body ~30×/sec. **Fix:** split the high-frequency telemetry (`timecode`,
  `liveFPS`) into its own small `@Observable`; throttle `liveFPS` to ~1 Hz.
- **P1-4 · Render output never cached** — `render()` always allocates a fresh `UIImage`, so the
  `uiView.image !== rendered` guard at `ios/Runner/MonitorExperience.swift:419` never
  short-circuits. **Fix:** memoize the last render keyed on `(ObjectIdentifier(frame), effects)`.
- **P1-5 · `readExact` is O(n²) on large frames** — `buffer.removeFirst(byteCount)`
  (`ios/Runner/NativeCameraSession.swift:996`) shifts/reallocates a 1–2 MB `Data` every frame.
  **Fix:** track a read cursor/offset and compact lazily; reuse one buffer.
- **P1-6 · Scope downsample runs `CGContext.draw` + fresh buffers on `@MainActor`** — every 3rd
  frame, `FrameSampling.rgbaBuffer` (`ios/Runner/LiveFrameProcessor.swift:71`) allocates a new
  buffer, recreates the color space, and software-rescales a ~1 MP JPEG. **Fix:** do it on the
  off-main decode hop; reuse the buffer + cache the color space.

## P2 — Hygiene & latent hazards

- **P2-1** RED zip import buffers the whole archive in RAM, twice, on `@MainActor` —
  `Data(contentsOf:)` + `Archive(data:)` + a growing `var fileData` (`ios/Runner/NativeAppRoot.swift:113`,
  `:121`, `:2008`). Download streams to disk correctly; only import is greedy. Fix:
  `Archive(url:accessMode:.read)` + file-to-file `extract`, off-main, with a size cap.
- **P2-2** `CameraPicker.allCases.first(where:)` linear-scans inside `body` ~150×/sec across the
  5-button bar (`ios/Runner/MonitorExperience.swift:1170`). Fix: static `[String: CameraPicker]` map.
- **P2-3** Scene enumeration + duplicate layout `fit()` solves inside `body` per frame
  (`ios/Runner/MonitorExperience.swift:54`, `:574`, `:900`). Fix: cache reactively; memoize `fit()`.
- **P2-4** Socket I/O ignores `Task` cancellation; the establishment `Task` isn't
  stored/cancellable (`ios/Runner/NativeAppRoot.swift:507`). Fix: check `Task.isCancelled`,
  store+cancel the establishment task, pair cancellation with `close()`.
- **P2-5** Stale per-camera state survives reconnect — `lockedControls`, `cameraControlOptions`,
  etc. aren't cleared in `clearCameraSessionState` (`ios/Runner/NativeAppRoot.swift:1163`).
- **P2-6** Discovery loop polls every 0.85 s forever on the connect screen
  (`ios/Runner/NativeAppRoot.swift:846`). Fix: back off after N empty cycles; pause on background.
- **P2-7** `AsyncSerialGate` leaks cancelled waiters (`ios/Runner/NativeCameraSession.swift:900`)
  and the `@unchecked Sendable` invariant is inaccurate during establishment — both dissolved by
  converting the session to an `actor`.

## What's already correct (do not regress)

- CIContext / cube filters / LUT tables created once and reused
  (`ios/Runner/LiveFrameProcessor.swift:141`, `LUTCubeCache`).
- `autoreleasepool` around per-frame decode (`ios/Runner/NativeAppRoot.swift:1337`).
- Single reused `UIImageView` (`ios/Runner/MonitorExperience.swift:396`).
- Reconnect backoff with jitter + cap + escalation ladder (`Sources/OpenZCineCore/ReconnectBackoff.swift`).
- PTP-IP framing handles partial reads and bounds-checks length to 8…128 MiB
  (`ios/Runner/NativeCameraSession.swift:976`).
- Blocking syscalls kept off main via `performOnQueue`.
- Connected-path task hygiene (stored, cancelled, `[weak self]`/identity guards).
- Scopes throttled to every 3rd frame + 200 px downsample + gated on active.
- GUID/pairing in `UserDefaults` is **not** a security issue — the GUID is a hardcoded app
  constant and Nikon PTP-IP pairing is identity-based with no secret material.

## Remediation order

1. **P0 stability first** — event-drain loop, `scenePhase` gating, transaction deadline, `EAGAIN`→loop, LUT size cap. Mostly localized, low blast radius; each prevents a class of field failure.
2. **The `@MainActor`→`actor` refactor + off-main decode/render** — biggest performance win; dissolves P1-1/2/4/6 and several P2s. Largest change — do it deliberately, re-run `just native-check`.
3. **`@Observable` split + render cache** (P1-3, P1-4) — kills the steady-state HUD redraw drain.
4. **P2 cleanups.**

## Validation (required)

Profile on-device against a live ZR stream with Instruments:

- **Time Profiler** — confirm main-thread decode/render cost.
- **Animation Hitches / Core Animation FPS** — confirm dropped frames.
- **Allocations** — confirm per-frame churn.
- **Energy / thermal state** — over a ≥30-minute run.

A static audit predicts; Instruments confirms in milliseconds and catches anything the static
pass missed.

## Further GPU acceleration

Beyond moving work *off the main thread*, there's headroom to move it *onto the GPU* — eliminating
the per-frame CPU readback (render to a `CAMetalLayer` drawable, no `createCGImage`) and computing
the scopes on the GPU (`MPSImageHistogram`; additive-blend scatter for waveform/parade). This
upgrades the off-main refactor (it replaces its render/scope phases). Full design:
[docs/design/plans/2026-06-29-gpu-acceleration-design.md](design/plans/2026-06-29-gpu-acceleration-design.md).

## Night audit — 2026-07-02

A second full static audit (five parallel passes over the live-view pipeline, scopes/assists,
SwiftUI rendering, networking/concurrency, and memory/lifecycle), briefed on everything already
fixed above. Executed in four verified batches — `just native-check` green after each, and
simulator screenshots of the scopes / LUT-assist / command scenes confirmed visual parity with the
pre-change build (identical or sub-0.1 % antialiasing noise).

### Fixed — stability

- **Establishment lifecycle**: the connect task is stored/cancellable and generation-guarded, so a
  slow handshake finishing after Disconnect can no longer resurrect a dead session; new
  establishment awaits the previous session's socket teardown (one PTP-IP command channel per
  initiator).
- **Orphaned frame fetch**: every `streamUntilStall` exit cancels the in-flight
  `liveViewFrame()` task — it previously kept the transaction gate queued/held through stall
  recovery (operator-visible as commands hanging during a restart).
- **`AsyncSerialGate` cancellation (P2-7)**: cancelled waiters are removed immediately and
  `transact()` re-checks cancellation after acquiring the gate, so stale commands never touch the
  socket.
- **Transaction packet cap** (512): a desynced stream that never sends `operationResponse` can no
  longer grow memory and hold the gate forever.
- **Single-flight property polls and pending-write drains**, bound to their session — slow links
  can't stack transactions behind the gate and delay frame fetches.
- **Media task lifecycle**: clip streams, listing passes, and the thumbnail worker are cancelled
  on session teardown (waiting cells are resumed — no leaked continuations) and paused on
  backgrounding (resumed on foreground).
- **Scope sample gate**: `defer`-cleared with a stale-publish guard, so an early exit can't
  silently stop all scope sampling.

### Fixed — performance (visuals unchanged)

- LiveViewObject header parsed **once** per frame instead of three times (~30 ×/s).
- Renderer actor round-trips collapsed to one hop per displayed frame; the identity/Metal path
  skips the actor entirely (one eviction on transition out of CPU baking).
- On the GPU-scopes path, the CPU/GPU histogram sampling pipeline is skipped entirely when only
  waveform/parade are visible (the scatter panels read the clean frame directly).
- `GPUScopeSampler` reads bins in the command buffer's completed handler (no
  `waitUntilCompleted` thread pinning), double-buffered against readback/zero-fill races.
- SwiftUI isolation: command-monitor hero timecode extracted (per-frame timecode publishes no
  longer re-evaluate the whole dashboard), `HistogramScopePlot` and `LiveFocusBoxOverlay` gained
  the `Equatable` redraw guard, GPU scatter panels no longer observe histogram bins they don't
  draw.
- Media memory: photo grid/list cells decode 640 px downsampled stills via a shared ImageIO actor
  (was full-resolution, a jetsam risk); thumbnail fetch backlog capped; `LUTCubeCache` LRU-bounded
  (24 cubes); RED zip extraction off the main actor and the downloaded archive deleted after
  import.

### Deferred (documented, not executed — medium risk or needs hardware validation)

- **Move the streaming loop off `@MainActor`** — flagged independently by three passes as the
  single biggest remaining win (decode → display latency, main-thread scheduling). Deliberate
  refactor; needs on-device Instruments before/after.
- **Shared downsample texture** between `GPUScopeSampler` and the scatter views (one downsample
  pass per tick instead of per consumer).
- **Live-view fetch watchdog deadline** — `liveViewFrame()` passes `deadline: nil`; a camera that
  accepts the request but never streams bytes can still freeze the feed until the operator
  intervenes. Needs a design that doesn't spawn a timer per frame (e.g. a coarse shared deadline).
- **Keep-alive / event-drain failure escalation** — repeated failures currently only log; they
  could drive the same reconnect path the stream watchdog uses.
- **Media delivery cancel wiring** — the delivery sheet's Cancel doesn't abort an in-flight
  export/upload.
- **CI filter graph caching for peaking/zebra** (rebuilt per frame; needs pixel-identical
  verification), and playback scope downsample before `createCGImage` readback.
