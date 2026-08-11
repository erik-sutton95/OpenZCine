# Android live-view latency audit

**Date:** 2026-08-10. **Trigger:** two field reports.

> "Even through USB the latency is not the greatest. Wifi is barely usable in my opinion. The
> usable latency starts with very strong compression. Competition for example zine control is much
> better in this department."

And, separately:

> "both OpenZcine and ZRCTL have a noticeable latency issue on Android phones with MediaTek
> Dimensity chipsets. Yesterday I tested a relatively high-end phone powered by the Dimensity
> 9500s, but I still experienced noticeable display latency. In comparison, on Android phones with
> Snapdragon chipsets, the latency is barely noticeable."

Five parallel read-only audits: fetch loop, decode, presentation, end-to-end queueing, and an
iOS-versus-Android differential. This is the synthesis, what was fixed, and what is still open.

## What the reports actually tell us

Three deductions constrain everything below.

**USB is affected too**, so this is not primarily a network problem. Any theory that only explains
Wi-Fi is incomplete.

**Cost scales with frame size** — "usable latency starts with very strong compression". That points
at per-pixel or per-byte work, not at protocol overhead.

**The chipset split is the sharpest clue, and it does not point where it first appears to.** A
Dimensity 9500s has ample throughput to decode a 0.59 MP JPEG. Raw compute cannot be the
difference between two flagships. What *does* differ by vendor is GPU driver behaviour and
scheduler placement — and the reporter says a competitor shows the same split, which rules out
anything specific to this codebase and points at something both apps sit on top of.

## Two premises that turned out to be wrong

Recorded because both nearly caused wasted work.

**The adaptive quality ladder is not a missing feature.** It shipped on both platforms and was
deleted from both on 2026-08-04 by explicit decision — automatic preview softening read as
instability (`docs/networking-audit-2026-08-04.md`). It must not be re-ported. The "very strong
compression" report is a request for a *manual* result, not evidence of a missing automatic one.

**Fetch already overlaps decode on Android.** iOS overlaps explicitly; Android overlaps
structurally, because the pump thread hands the frame to a conflated channel and loops straight
back to the next fetch. Same win, different mechanism. Not a gap.

## Fixed

| # | Finding | Where |
| --- | --- | --- |
| 1 | The grade was re-uploaded to the GPU on **every recomposition**, and the monitor recomposes at feed rate — so a 33³ LUT and two 64³ cubes were re-uploaded 25–30×/s, each upload ending in a full `vkQueueWaitIdle`, taken under the same lock the frame present needs | `LiveFeedGpuBackend.kt` |
| 2 | USB read in 16 KiB chunks: 7–13 sequential transfers per frame, two Large-Object allocations *per chunk*, USB bus idle in between | `USBPTPTransactionTransport.swift` |
| 3 | The pump thread ran at default priority and the decoder ran on the shared `Dispatchers.Default` pool, competing with scope and LUT work, while UI and render threads sit at −10 | `PTPIPClientSession.swift`, `LiveFeedView.kt` |
| 4 | The shared frame flow had a **64-deep SUSPEND buffer**, so the producer was paced by the slowest of six consumers — three of which run on the main thread | `SwiftCoreLiveFrameSource.kt` |
| 5 | The packet was assembled by concatenating a parsed header back onto its payload and re-parsing: three extra JPEG-sized copies per frame. iOS deleted this | `PTPIPClientSession.swift` |
| 6 | Every `recv` allocated and zeroed a fresh 256 KiB buffer. iOS keeps one scratch per socket | `PTPIPClientSession.swift` |
| 7 | No latency instrumentation existed at all — every counter measured throughput | `FramePacing.kt` |
| 8 | `decode avg` in the pacing line spanned decode **and** present, hiding a blocking GPU submit inside a number read as decoder cost | `FramePacing.kt` |

Findings 7 and 8 are the ones to apply first: the pacing line now reports **frame age at
presentation** and times decode and present separately. Nothing else in this document can be
confirmed or killed without them.

## Open, ranked — and the top item needs a decision, not just work

### 1. The Vulkan present blocks the decode thread, every frame

`LiveFeedVk_SubmitBitmap` runs synchronously on the decode coroutine: a whole-frame `memcpy` into
staging, then **`vkQueueWaitIdle`** (a full GPU drain), then `vkWaitForFences(UINT64_MAX)`, then a
vsync-paced `vkAcquireNextImageKHR`. Pipeline depth is one: frame N+1 cannot begin decoding until
frame N has finished rendering. iOS has no CPU wait anywhere in its present.

This is the leading explanation for the chipset split. There are **zero vendor branches** anywhere
in the Android live path, so the split has to come from something whose *cost* varies by driver —
and a full queue drain after a staging copy is exactly that: on a tile-based deferred renderer
(Mali/Immortalis, i.e. Dimensity) it forces the whole binning and fragment pass to complete with
nothing able to pipeline behind it. It is also transport-independent, which is the only theory here
that explains **USB being affected too**.

**Falsifiable cheaply, and that should happen before any Vulkan code is written:** force the GLES
path on a Dimensity device (`LiveFeedGpuBackendFactory.preferVulkan`) and compare the new age
counter. The GLES path renders on its own thread and does not block.

### 2. The presentation path is chosen backwards

The feed is routed through Compose Canvas — two nested offscreen HWUI layers plus N glass blur
passes per frame — whenever glass is `FULL`, which requires API 33+ **and ≥4 GB RAM**. A nominal
4 GB phone reports ~3.6 GB, falls to `FLAT`, and gets the fast `SurfaceView` path. A flagship
Dimensity reports 8–12 GB and gets the slow one. **Better silicon is routed to the worse
pipeline**, and render-target switches are precisely what tilers pay most for.

**This one is a product decision, not an engineering call.** Routing the feed to `SurfaceView`
everywhere would delete the layer round-trips outright, but the liquid-glass pills would stop
showing live video behind them — they would blur chrome only. That is a visible divergence from
iOS and it was a deliberate trade in the other direction. It needs an explicit call.

### 3. Shaders run per display pixel, not per source pixel

Source is 1024×576 (0.59 MP); a fitted viewport on a 1080p panel is ~2.07 MP. Every LUT lookup,
LIMITS composite, zebra test and peaking tap is paid **3.5× over**. iOS does the opposite: it bakes
into an intermediate at the *feed's* resolution and the present is a single scaled sample.

This is the finding that best matches "cost scales with frame size", and unlike #2 it costs nothing
visible — the picture is the same. With peaking on, it is the difference between ~40 M and ~141 M
texture fetches per frame.

### 4. Wi-Fi power save is never inhibited

No `WifiLock` anywhere, in any mode. Wi-Fi power-save policy is vendor firmware, MediaTek's is more
aggressive than Qualcomm's, and a strict request/response pull loop pays the wake latency directly
on every frame. This is the **only** hypothesis that explains a competitor showing the same split,
since nothing in our code is shared with theirs but this is. It is also the cheapest thing on this
list to try: acquire `WIFI_MODE_FULL_LOW_LATENCY` while a wireless camera session is live.

### 5. Smaller, verified, uncontroversial

- **No frame deadline on the Android live-view fetch.** iOS clamps to `25×RTT` within 6–15 s;
  Android's `getLiveViewImageEx` has none, so a trickling link can hold the serial gate
  indefinitely.
- **Fixed event-poll stride of 8**, where iOS scales the stride by measured RTT using
  `LiveViewPollPacing` — which lives in the *shared core* and the Android facade simply never calls.
- **Per-frame `NewByteArray`** into ART's Large Object Space, on the pump thread, so a collection
  blocks the fetch loop. Needs a pool ≥3 deep, because consumers retain the array past the callback.
- **GLES path copies the whole bitmap on the CPU** before uploading it, purely to break aliasing
  against the decoder's ring — the decoder already owns a 3-deep ring that could hold a lease
  instead.
- **The scopes decode the JPEG a second time.** Correct isolation, real CPU cost, and iOS reuses
  the already-decoded frame instead.
- **A redundant `inJustDecodeBounds` pass per frame** computing a constant. Left alone deliberately:
  the saving is small and whether the bound can ever be exceeded by a non-camera source needs
  checking first.

### Not a gap

Thermal handling is genuinely equivalent on both platforms — and inert on the stream on both, which
may itself be worth revisiting. The relay encoder-queue bug fixed on iOS has no Android analogue by
design: that host re-encodes nothing and its per-watcher lane is already a bounded drop-oldest
channel.

## What to do next, in order

1. Read the new age and present counters off a Dimensity device. Everything above is reasoning from
   source; none of it is a profile.
2. Force GLES on that device and read them again. That one comparison confirms or kills #1.
3. Try the `WifiLock` — it is hours of work and would explain the competitor datum.
4. Then decide #2, which is Erik's call, and schedule #3, which is not.
