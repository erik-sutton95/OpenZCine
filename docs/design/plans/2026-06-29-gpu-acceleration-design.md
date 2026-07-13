# GPU Acceleration Design — Live-View Monitor

**Context:** A question from a graphics/game-dev background — "can we push more to the GPU?" Short
answer: **yes, and your instincts transfer directly.** A real-time camera monitor is a
graphics-rendering problem, not traditional app dev. iOS gives you the full toolbox: **Metal**
(shaders + compute), **Core Image** (already GPU-backed), and **Metal Performance Shaders** (MPS,
tuned GPU primitives). This doc maps the game-dev techniques onto our pipeline, grounded in the
current code, and shows how they upgrade the already-planned off-main refactor.

> This is a **design**, not an executed change. GPU pipelines must be validated with an on-device
> **Xcode GPU frame capture** (the iOS equivalent of RenderDoc) + **Metal System Trace** against a
> live ZR — so, like the refactor plan, this lands after device validation, not blind.

## The mental model: what's already GPU vs. wastefully CPU

| Stage | Today | GPU verdict |
| ----- | ----- | ----------- |
| JPEG decode | ImageIO/`UIImage(data:)` (HW-assisted, but on main until refactor Phase A) | HW decoder; fine once off-main |
| LUT / false-color / peaking / zebra | Core Image `CIColorCube` + filter chain — **already GPU** | Good; only fuse if profiling demands |
| **Display** | Core Image → `createCGImage` (**GPU→CPU readback**) → `UIImage` → `UIImageView` (**CPU→GPU re-upload**) | ❌ **Redundant round-trip — the #1 win** |
| **Scopes** (histogram, waveform, parade) | `CGContext` CPU downscale to 200px → **CPU pixel loop** (4×256-bin hist + ~7.5k points) → SwiftUI `Canvas` | ❌ **Textbook GPU compute/scatter — the #2 win** |

The two ❌ rows are where a graphics person's instinct pays off most. The effects are already on the
GPU; the *display* and the *scopes* are not.

---

## GPU Win 1 — Eliminate the CPU readback: render to a Metal layer

**The problem (pure graphics terms):** every frame currently does
`LiveFrameProcessor.render` → `context.createCGImage(...)` (`ios/Runner/LiveFrameProcessor.swift:179`)
which forces the GPU to finish, copies the result **GPU→CPU** into a `CGImage`, wraps it in a
`UIImage`, and hands it to a `UIImageView` — which then re-uploads it **CPU→GPU** to composite. You
render on the GPU, drag the pixels through system memory, and shove them back. That's the blit-through-RAM
anti-pattern; the fix is to present straight to the drawable (the swapchain).

**The fix (WWDC20 "Optimize the Core Image pipeline for your video app"):**
- Host the feed in a `CAMetalLayer`-backed view (or `MTKView`), `framebufferOnly = false` so Core
  Image may use Metal **compute**.
- Build **one** `CIContext(mtlCommandQueue:options:)` shared with the app's `MTLCommandQueue` (today
  the context has no explicit device/queue — `LiveFrameProcessor.swift:141`).
- Per frame, render the effect graph into the drawable's texture via a `CIRenderDestination` whose
  texture is supplied by a **block** (lets Core Image enqueue without blocking on the prior frame),
  then `commandBuffer.present(drawable); commandBuffer.commit()`. **No `createCGImage`, no `UIImage`,
  no readback.**

```swift
// Sketch — the per-frame present loop (real code: WWDC20 session 10008).
let dest = CIRenderDestination(width: w, height: h, pixelFormat: layer.pixelFormat,
                               commandBuffer: cmd) { drawable.texture }
dest.isFlipped = true
try ciContext.startTask(toRender: outputImage, to: dest)   // GPU only
cmd.present(drawable)
cmd.commit()
```

**Payoff:** removes a full-frame GPU→CPU→GPU round-trip every frame (the single biggest per-frame
cost when effects are on). **This replaces the planned refactor's Phase B** — rendering to a Metal
drawable is strictly better than "render with `createCGImage` off-main," because off-main still pays
the readback. Effort: medium. Risk: medium (new view + Metal lifecycle). Validate with a GPU capture.

---

## GPU Win 2 — Compute the scopes on the GPU

**The problem:** `refreshScopes` (`ios/Runner/LiveFrameProcessor.swift:117`) →
`FrameSampling.rgbaBuffer` (CPU `CGContext` downscale to 200px, `:71`) → `ScopeSampler.sample`
(`Sources/OpenZCineCore/ScopeSampler.swift:48`) walks the buffer on the **CPU**, building four
256-bin histograms and a ~7.5k-element `[ScopePoint]` — on the main actor, every 3rd frame. This is
the classic "analyze every pixel" loop that GPUs exist for.

### 2a. Histogram → `MPSImageHistogram` (drop-in)
`MPSImageHistogram` computes the per-channel histogram of an `MTLTexture` into an `MTLBuffer` in one
GPU pass. Configure `MPSImageHistogramInfo { numberOfHistogramEntries: 256, … }`, `encode(to:
sourceTexture:histogram:histogramOffset:)`, read the bin buffer. It replaces the entire CPU
histogram loop **and** removes the 200px downsample — a ~1 MP ZR frame is nothing for the GPU, so
the histogram becomes **full-res and more accurate**. The existing `remapToReferenceScale` /
`trafficLights` (256-bin, cheap) stay on the CPU and consume the GPU result unchanged.

### 2b. Waveform / Parade → additive-blend scatter (the game-dev technique)
A waveform monitor **is** a GPU scatter: for each source pixel, plot a point at
`x = pixel.x`, `y = luma` (parade: one target column-band per channel) into an accumulation texture
with **additive blending**, so overlapping samples brighten the trace — exactly a point-cloud +
additive-blend accumulation pass. Implementation: a Metal render pipeline with `blendingEnabled`,
`sourceRGBBlendFactor = .one`, `destinationRGBBlendFactor = .one`; a vertex shader that reads the
source texture by `vertex_id` and positions the point; a tiny fragment shader emitting the trace
colour/intensity. Render once per frame into a scope texture, composite it over the feed (or into the
scope panel). No CPU loop, no `[ScopePoint]` array crossing the actor boundary, full-res input.

### 2c. Vectorscope (if/when added)
Same pattern: scatter at `(Cb, Cr)` with additive blend → the vectorscope graticule. Trivial once 2b
exists.

**Payoff:** deletes the per-frame CPU pixel loop, the `CGContext` software downscale, the fresh
RGBA buffer + colorspace allocation, and the SwiftUI `Canvas` path rebuilds — and makes the scopes
full-resolution. **This supersedes the planned Phase B3** ("sample scopes off-main"): don't move the
CPU loop off-main — replace it with GPU compute. Effort: 2a small, 2b medium. Risk: low–medium.

---

## GPU Win 3 — Fuse the effect shaders (optional, later)

The effects are a Core Image **chain**: base cube → peaking (`CIEdges` + `CIMorphologyMaximum` +
`CIColorMatrix`) → zebra (`CIStripesGenerator` + `CIMultiplyCompositing`) — each filter is a pass
with intermediate textures (`LiveFrameProcessor.swift:160-184`). A single hand-written Metal fragment
shader doing LUT + false-color + peaking + zebra in **one pass** (sampling a 3D LUT texture, computing
the Sobel/exposure locally) removes the intermediates and the graph-compile overhead.

**Verdict:** only after Wins 1–2 and only if a GPU capture shows the filter chain dominating. Core
Image is already GPU and convenient; a premature Metal rewrite trades the well-tested LUT/peaking/zebra
math for hand-rolled shaders. High effort, uncertain marginal payoff. Keep `OpenZCineCore`'s peaking/
exposure math as the reference the shader must match.

---

## GPU Win 4 — Zero-copy decode (advanced, measure first)

JPEG decode is already hardware-assisted (ImageIO), and Phase A moves it off-main. For a *fully*
GPU-resident frame (never touching CPU memory), decode the MJPEG with **VideoToolbox**
(`VTDecompressionSession`, HW JPEG) → `CVPixelBuffer` → wrap as an `MTLTexture` via
`CVMetalTextureCache` (zero-copy), feeding Wins 1–2 directly. Only worth it if decode or the
CPU→GPU upload shows up in Metal System Trace after Wins 1–2; otherwise the ImageIO path is fine.

---

## How it all composes (the GPU-native frame)

Once Wins 1–2 land, the per-frame shape becomes **one command buffer, one GPU submission, zero
readback**:

```
decoded frame texture
      │ (CVMetalTextureCache or CIImage from CGImage)
      ▼
[ Core Image effect graph ]  →  present to CAMetalLayer drawable      (Win 1)
      ├─ MPSImageHistogram  →  bin buffer  →  histogram scope          (Win 2a)
      └─ additive scatter   →  waveform/parade/vectorscope textures    (Win 2b)
```

Main-thread per-frame work drops to ~nothing: hardware decode hands off a texture; everything else is
GPU passes in one command buffer. This **converges with the refactor**: Win 1 replaces Phase B and
Win 2 replaces Phase B3. (Phase C — the `NativeCameraSession`→`actor` move — was **dropped**: the
session is not `@MainActor`, so PTP assembly/parse already run off-main; see the audit doc's
Correction.) Net: the off-main refactor and the GPU work are the same goal reached more thoroughly.

## Effort / risk / payoff

| Win | Effort | Risk | Payoff | Order |
| --- | ------ | ---- | ------ | ----- |
| 1 — render to Metal layer (no readback) | Medium | Medium | Highest per-frame win when effects on | **First** |
| 2a — `MPSImageHistogram` | Small | Low | Deletes CPU histogram loop; full-res | **Second** |
| 2b — scatter waveform/parade | Medium | Low–Med | Deletes CPU point loop + Canvas | Third |
| 3 — fused effect shader | High | Med | Marginal vs. Core Image | Only if profiled |
| 4 — VideoToolbox zero-copy decode | High | Med | Only if decode/upload profiles hot | Only if profiled |

## Verification (the graphics workflow you already know)

- **Xcode GPU frame capture** — capture one frame, inspect every encoder/pass, texture, and pipeline
  state (RenderDoc-style). This is how you confirm "no readback" and see the scope passes.
- **Metal System Trace** (Instruments) — GPU vs. CPU timeline, command-buffer scheduling, hitches.
- **Time Profiler** — confirm the main thread is idle per frame.
- All require a real device + the live ZR stream; a build pass cannot validate a GPU pipeline.

## Caveats / what NOT to do

- Don't rewrite the **effects** in Metal first — they're already GPU; the readback (Win 1) and scopes
  (Win 2) are the real wins. Win 3 is last and conditional.
- Keep `Sources/OpenZCineCore` UI-free: Metal/CoreImage/MPS live in the shell. The scope **math**
  (`ScopeSampler` reference, `ExposureScale`, IRE mapping) stays in core as the spec the shaders match
  and the CPU fallback.
- `MPSImageHistogram` / additive-scatter need an `MTLTexture` of the frame — which Win 1 already
  establishes — so do Win 1 first; 2a/2b reuse its texture + command queue.

## Sources

- [Optimize the Core Image pipeline for your video app — WWDC20 (session 10008)](https://developer.apple.com/videos/play/wwdc2020/10008/)
- [CAMetalLayer — Apple Developer Documentation](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer)
- [MPSImageHistogram — Apple Developer Documentation](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagehistogram)
- [MPSImageHistogramInfo — Apple Developer Documentation](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagehistograminfo)
- [Metal Best Practices Guide: Drawables — Apple](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)
