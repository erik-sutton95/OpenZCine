# Live-View Off-Main Pipeline Refactor (P1-1 / P1-4 / P1-6) — Implementation Plan

**Goal:** Move the per-frame live-view work (JPEG decode, Core Image render, scope sampling, and PTP packet assembly/parse) off the main thread, so the SwiftUI UI and gesture handling never compete with the ~30fps pipeline.

**Architecture:** Stage the move in three independently-shippable phases, lowest-risk first. **Phase A** decodes the JPEG off-main. **Phase B** renders the Core Image effects off-main and caches the result keyed on (frame, effects), so the view just displays a finished bitmap (subsumes P1-4 render-caching and P1-6 off-main scope sampling). **Phase C** converts `NativeCameraSession` from a `@MainActor` class to an `actor`, moving PTP packet assembly + parsing off-main. Each phase must pass `just native-check` and be profiled on-device before the next begins.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI `@Observable`, Core Image (`CIContext`/`CIColorCube`), UIKit (`UIImageView`/`UIImage`), ImageIO, PTP-IP over BSD sockets.

## Global Constraints

- Swift 6.0 strict concurrency; no data races; `Sendable` across every actor boundary. (verbatim: CLAUDE.md)
- Shared core `Sources/OpenZCineCore` stays UI-free — no SwiftUI/UIKit/CoreImage imports. (verbatim: CLAUDE.md)
- Shell uses `@Observable`/`@Bindable`, `async/await`, no Combine, no `NavigationView`/`ObservableObject`. (verbatim: CLAUDE.md)
- No force-unwrap without a `// SAFETY:` comment. (verbatim: CLAUDE.md)
- Verification gate is `just native-check` (swift-format lint --strict + swift test + ios-build). Never call `xcodebuild`/`swift test` directly in its place. (verbatim: CLAUDE.md)
- A **new** file under `Sources/OpenZCineCore` must be registered in the Xcode Runner target: `ruby scripts/add-core-file-to-xcode.rb <File>.swift` (the app compiles core sources directly).
- Do NOT regress these existing wins: per-frame `autoreleasepool` around decode, the single reused `UIImageView`, the reused `CIContext`/`cubeFilters`/`LUTCubeCache`, command-mode frame-loop pause, scope throttle (every 3rd frame, 200px downsample).
- Every phase ends with on-device Instruments profiling (Time Profiler + Animation Hitches + Allocations) against a live Nikon ZR; a static/build pass is necessary but not sufficient for this work.

---

## Current state (baseline, verified 2026-06-28)

- Decode: `streamUntilStall` (on `@MainActor NativeAppModel`) runs `autoreleasepool { UIImage(data: frame.jpeg) }` and assigns `liveFrameImage` — `ios/Runner/NativeAppRoot.swift` (~1401–1406, first frame ~1362).
- Render: `LiveFrameView.updateUIView` (`ios/Runner/MonitorExperience.swift:416`) calls `coordinator.render(image, effects:)` **synchronously on main** every update; `LiveFrameProcessor.render` (`ios/Runner/LiveFrameProcessor.swift:157`) does `CIImage(image:)` → filter chain → `context.createCGImage(...)` (blocking GPU readback). It already early-returns the input when `effects.isIdentity`.
- The render result is never cached: `render` always allocates a fresh `UIImage`, so the `uiView.image !== rendered` guard at `MonitorExperience.swift:419` never short-circuits, and `updateUIView` re-renders on any unrelated parent invalidation.
- Scope sampling: `refreshScopes` (`ios/Runner/LiveFrameProcessor.swift:117`) runs `FrameSampling.rgbaBuffer` (CGContext downscale) + `ScopeSampler.sample` on the `@MainActor` model, every 3rd frame.
- Session: `@MainActor final class NativeCameraSession: @unchecked Sendable` (`ios/Runner/NativeCameraSession.swift:84/275`); `transact` assembles packets and parses the LiveViewObject on the main actor; `transactionGate` (`AsyncSerialGate`) serializes whole transactions.

---

## Phase A — Off-main JPEG decode

**Why first:** Smallest, highest-confidence win. `UIImage(data:)` defers the actual JPEG decode to draw time on the main thread; forcing a full decode off-main hands the UI an already-decoded bitmap. No change to the session or the view tree.

### Task A1: Testable off-main JPEG decoder

**Files:**
- Create: `ios/Runner/JPEGFrameDecoder.swift`
- Test: `ios/RunnerTests/JPEGFrameDecoderTests.swift` (create the RunnerTests target if absent — see note)

> Note: if `ios/RunnerTests` does not yet exist, this task includes creating a unit-test target in `ios/Runner.xcodeproj` (one-time). If standing up the target is non-trivial, fall back to exercising the decoder from a core-level test by passing raw bytes through an injected decode closure; keep the UIKit-touching code in the shell.

**Interfaces:**
- Produces: `enum JPEGFrameDecoder { static func decode(_ jpeg: Data) -> CGImage? }` — fully decodes a JPEG to a bitmap-backed `CGImage` off the caller's thread (uses ImageIO `CGImageSourceCreateImageAtIndex` with `kCGImageSourceShouldCacheImmediately: true` to force decode). `CGImage` is `Sendable`-safe to hand back to `@MainActor`.

- [ ] **Step 1: Write the failing test** (`ios/RunnerTests/JPEGFrameDecoderTests.swift`)

```swift
import Testing
import UIKit
@testable import Runner

@Test func decodesValidJPEGToExpectedPixelSize() throws {
    // 2x2 red JPEG encoded at runtime so the test owns no binary asset.
    let src = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
        UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    let jpeg = try #require(src.jpegData(compressionQuality: 1))
    let decoded = try #require(JPEGFrameDecoder.decode(jpeg))
    #expect(decoded.width == 2)
    #expect(decoded.height == 2)
}

@Test func returnsNilForGarbageData() {
    #expect(JPEGFrameDecoder.decode(Data([0x00, 0x01, 0x02])) == nil)
}
```

- [ ] **Step 2: Run to verify it fails** — `just native-check` (or the RunnerTests scheme). Expected: FAIL, `JPEGFrameDecoder` undefined.

- [ ] **Step 3: Implement** (`ios/Runner/JPEGFrameDecoder.swift`)

```swift
import ImageIO
import CoreGraphics
import Foundation

/// Fully decodes a JPEG to a bitmap-backed CGImage off the caller's thread, so the main thread
/// only displays an already-decoded image (UIImage(data:) defers decode to draw time on main).
enum JPEGFrameDecoder {
    static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
```

- [ ] **Step 4: Run to verify it passes** — `just native-check`. Expected: PASS, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** — `perf(ios): off-main JPEG frame decoder (P1-1 phase A/1)`

### Task A2: Decode each frame off the main actor

**Files:**
- Modify: `ios/Runner/NativeAppRoot.swift` (`streamUntilStall`: the first-frame decode ~1362 and the per-frame decode ~1401)

**Interfaces:**
- Consumes: `JPEGFrameDecoder.decode(_:) -> CGImage?`
- Produces: `model.liveFrameImage` is now assigned a `UIImage` wrapping an already-decoded `CGImage`.

- [ ] **Step 1:** Replace the per-frame `autoreleasepool { UIImage(data: frame.jpeg) }` with an off-main decode hop. The `jpeg` is `Data` (Sendable); decode on a detached task and resume on the actor:

```swift
let jpeg = frame.jpeg
let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
    autoreleasepool { JPEGFrameDecoder.decode(jpeg).map(UIImage.init(cgImage:)) }
}.value
```

Apply the same to the first-frame decode. Keep the `if let image = decoded { ... }` body unchanged.

- [ ] **Step 2:** Build — `just native-check`. Expected: `** BUILD SUCCEEDED **`, 303+ tests pass.
- [ ] **Step 3: On-device profile** — Time Profiler over a 2-min live-view run; confirm `UIImage(data:)`/JPEG decode no longer appears on the main thread. Record before/after main-thread time.
- [ ] **Step 4: Commit** — `perf(ios): decode live-view JPEG off the main actor (P1-1 phase A/2)`

> Risk: a per-frame `Task.detached` adds scheduling overhead at 30fps. If profiling shows it, replace with a single long-lived decode `actor` (serial) that the loop `await`s — same interface, one reused executor. Note this in the commit if changed.

---

## Phase B — Off-main cached render + scope sampling (P1-4, P1-6)

**Why:** The synchronous `createCGImage` in `updateUIView` is the largest per-frame main-thread cost whenever a LUT/peaking/zebra is active, and it re-fires on unrelated invalidations. Move render off-main, cache by (frame, effects), and make the view a dumb displayer.

> **GPU-native alternative (preferred).** Rendering to a `CAMetalLayer` drawable via
> `CIRenderDestination` *eliminates* the `createCGImage` readback rather than just moving it
> off-main, and lets the scopes become GPU compute. See
> `docs/design/plans/2026-06-29-gpu-acceleration-design.md`. If taking the GPU path, Win 1
> replaces B1/B2 and Win 2 replaces B3; Phase A (off-main decode) and Phase C (actor) still apply.

### Task B1: Make `LiveFrameProcessor` render callable off-main and `Sendable`

**Files:**
- Modify: `ios/Runner/LiveFrameProcessor.swift` (class annotations + a render-cache field)

**Interfaces:**
- Produces: `final class LiveFrameProcessor: @unchecked Sendable` whose `render(_:effects:)` is safe to call from a single dedicated executor (NOT concurrently). `CIContext` is documented thread-safe for rendering; `cubeFilters` mutation must be confined to that one executor.

- [ ] **Step 1:** Add a last-result cache to avoid re-rendering an unchanged (frame, effects) pair:

```swift
private var lastKey: (image: ObjectIdentifier, effects: LiveImageEffects)?
private var lastOutput: UIImage?
```

- [ ] **Step 2:** At the top of `render(_:effects:)`, short-circuit on a cache hit (this is P1-4):

```swift
let key = (ObjectIdentifier(image), effects)
if let lastKey, lastKey == key, let lastOutput { return lastOutput }
```
…and before each `return`, store `lastKey = key; lastOutput = result`. (`LiveImageEffects` is already `Equatable`; the identity-path return stores the input image.)

- [ ] **Step 3:** Mark the class `@unchecked Sendable` with a `// SAFETY:` comment stating all access is confined to the renderer task created in B2.
- [ ] **Step 4:** Build + existing behavior unchanged — `just native-check`. Commit — `perf(ios): cache last live-frame render by (frame, effects) (P1-4)`.

### Task B2: Render off-main in the model; view displays the finished frame

**Files:**
- Modify: `ios/Runner/NativeAppRoot.swift` (own a `LiveFrameProcessor`; render after decode; add `@Observable var renderedFrameImage: UIImage?`)
- Modify: `ios/Runner/MonitorExperience.swift` (`LiveFrameView` takes only the finished image; remove the `render` call from `updateUIView`)

**Interfaces:**
- Consumes: `LiveFrameProcessor.render(_:effects:)` (B1).
- Produces: `model.renderedFrameImage` — the effects-baked frame; `LiveFrameView` becomes `{ let image: UIImage }` and sets `uiView.image = image` directly.

- [ ] **Step 1:** Give the model a long-lived renderer + executor (single serial actor or a dedicated `DispatchSerialQueue`-backed task) and, after decode, render off-main, then assign on the actor:

```swift
let effects = liveImageEffects                      // value snapshot (Sendable)
let rendered = await renderer.render(image, effects: effects)   // off-main
renderedFrameImage = rendered
```
Re-render the **last** frame when effects change with no new frame: add `.onChange(of: visibleAssistTools)`/`.onChange(of: selectedLUT)` (or a model hook) that re-renders `lastDecodedFrame` so toggling a LUT updates a paused feed.

- [ ] **Step 2:** Simplify `LiveFrameView` to display only:

```swift
private struct LiveFrameView: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView { /* unchanged setup */ let v = UIImageView(); /* … */ v.image = image; return v }
    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image !== image { uiView.image = image }   // no render here
    }
}
```
Update the call site to pass `model.renderedFrameImage ?? model.liveFrameImage` (fallback to undecorated frame).

- [ ] **Step 3:** Build — `just native-check`. **On-device profile:** confirm `createCGImage` is off the main thread with a LUT+peaking active; confirm `updateUIView` no longer renders on unrelated state changes. Commit — `perf(ios): render live frame off-main; view displays finished bitmap (P1-1 phase B, P1-4)`.

### Task B3: Move scope sampling onto the off-main hop (P1-6)

**Files:**
- Modify: `ios/Runner/NativeAppRoot.swift` (call `refreshScopes` work off-main), `ios/Runner/LiveFrameProcessor.swift` (sampling helper)

**Interfaces:**
- Produces: `model.scopeSamples` assigned from a `ScopeSamples` (already `Sendable`) computed off-main.

- [ ] **Step 1:** On the same detached/renderer hop (gated by `scopesActive` + the existing every-3rd-frame throttle), compute the downsample + `ScopeSampler.sample` off-main and return the `Sendable` `ScopeSamples`; assign `scopeSamples` on the actor. Reuse the destination buffer and cache `CGColorSpaceCreateDeviceRGB()` (hoist to a `static let`) to stop per-call allocation.
- [ ] **Step 2:** Build — `just native-check`. **On-device profile:** confirm the `CGContext.draw` downscale is off the main thread. Commit — `perf(ios): sample scopes off the main actor (P1-6)`.

---

## Phase C — ~~`NativeCameraSession` → `actor`~~ DROPPED (2026-06-29)

> **Dropped — the premise was a misread.** This phase assumed `NativeCameraSession` is `@MainActor`
> so that packet assembly/parse ran on main. In fact line 84's `@MainActor` is on
> `NativeCameraConnectionStore`; the session (line 275) is a plain `@unchecked Sendable` class whose
> nonisolated async methods run on the **global executor** when the `@MainActor` model `await`s them
> (SE-0338). Assembly + parse were **already off-main**, so an `actor` buys no off-main win and adds
> actor-hop overhead + reentrancy risk to a field-critical path. Phases A and B (→ GPU Win 1) plus
> P1-6 cover the *real* main-thread costs (decode, render, scopes). The original "Why" and tasks
> below are retained only as a record of the dropped plan.

**Original (obsolete) Why:** After A+B, the remaining per-frame main-thread cost is PTP packet assembly (`PTPIPTransactionCollector.collect` accumulating the ~MB LiveViewObject) and the LiveViewObject parse, both on the `@MainActor` session. An `actor` moves them off-main and removes `@unchecked Sendable`.

> Important: an `actor` does **not** serialize across `await` (reentrancy), so the `transactionGate` stays — it guarantees one transaction completes before the next starts. Phase C is about isolation + off-main execution, not removing the gate.

### Task C1: Convert the session to an actor

**Files:**
- Modify: `ios/Runner/NativeCameraSession.swift` (`@MainActor final class … : @unchecked Sendable` → `actor NativeCameraSession`)
- Modify: call sites that assumed main-actor synchronicity (most are already `await session.…`)

- [ ] **Step 1:** Change the declaration to `actor NativeCameraSession`. Remove `@MainActor` and `@unchecked Sendable`. Let the compiler enumerate every now-cross-actor access (build with `just native-check`); fix each by `await`ing or moving the access inside an actor method.
- [ ] **Step 2:** Confirm `establishmentSummary`/`nextTransactionID` are actor-isolated (this also closes P2-7's inaccurate-invariant note). Keep `transactionGate`; keep the deadline task from P0-3 (it captures `command`, still valid).
- [ ] **Step 3:** Audit `NativeAppModel` (`@MainActor`) callers: each `session.method()` becomes a suspension; verify no code assumed a synchronous return between `await`s (re-read state after each await). Pay attention to `streamUntilStall`, keepalive, event-drain, and `clearCameraSessionState`/`close` ordering.
- [ ] **Step 4:** Build — `just native-check`. **On-device profile + soak:** a ≥30-min live-view + reconnect + record-toggle soak on a real ZR; confirm packet assembly/parse left the main thread and that reconnection, keepalive, the event drain (P0-1), and the transaction deadline (P0-3) still behave. Commit — `refactor(ios): make NativeCameraSession an actor; PTP assembly/parse off main (P1-1 phase C)`.

> Risk: highest of the three phases — it touches every session entry point and the concurrency model of a field-critical path with no socket-level unit harness. Land it alone, behind the on-device soak, and be ready to revert the single commit if the soak regresses.

---

## Self-review notes

- Spec coverage: P1-1 (Phases A+C off-main decode/assembly/parse; B off-main render), P1-4 (B1 cache + B2 no-render-in-updateUIView), P1-6 (B3). P2-7 partially addressed by C1.
- Verification honesty: A1/B1 are unit-tested; A2/B2/B3/C are build-verified + **on-device profiled** (threading changes with no unit seam). Each phase ships independently and is revertible as a single commit.
- Order rationale: decode (A) and render (B) are the dominant main-thread costs and the lowest-risk; the actor conversion (C) is deferred to last and isolated.
