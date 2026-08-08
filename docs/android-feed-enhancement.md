# Android feed enhancement — upscaling and noise reduction

**Status: pinned, not scheduled.** iOS ships both (`3f4952b6`, VideoToolbox). The Android
counterpart is researched to the point where the shape and the costs are known, and parked there.
Both settings rows exist on Android reading "Coming soon" so the gap is visible in the product
rather than only in a document.

## What has to be matched

iOS `linkRows` → Processing card (`ios/Runner/MonitorPanels.swift`):

| Row | Backing | Placement in the pipeline | Why there |
| --- | --- | --- | --- |
| Feed Upscaler — Off / Fast / Quality / AI | Plain sample, sharpening kernel, MetalFX Spatial, `VTLowLatencySuperResolutionScaler` | **After** the effects bake | Peaking, false colour, zebra and the scopes keep measuring the true source frame at its own resolution |
| Feed Noise Reduction — switch | `VTTemporalNoiseFilter` | **On the decode side, before** the effects | So peaking stops sharpening grain — that *is* the benefit |

Two insertions, at opposite ends. Anything that treats this as one filter in one place is not
matching the feature, whatever it does to the picture.

Also inherited from iOS, and cheap to carry over: only options the device can actually run are
listed, the row disappears when that is just the floor, and AI is named for the property an
operator has to weigh rather than its mechanism — it infers detail the camera never captured, so
critical focus is judged on Quality or Fast.

## The candidate: Play services Media Enhancement API

`com.google.android.gms:play-services-media-effect-enhancement` (beta). Docs:
[get started](https://developer.android.com/media/ai-enhancement/get-started) ·
[overview](https://developer.android.com/media/ai-enhancement/overview) ·
[surface mode](https://developer.android.com/media/ai-enhancement/surface-mode-lifecycle) ·
[bitmap mode](https://developer.android.com/media/ai-enhancement/bitmap-mode-lifecycle).

Capability map is good:

| VideoToolbox | Media Enhancement |
| --- | --- |
| `VTLowLatencySuperResolutionScaler` | upscale (generative super-resolution) |
| `VTTemporalNoiseFilter` | denoise |
| `VTFrameProcessor` | `EnhancementSession` |
| `CVPixelBuffer` in/out | input `Surface` → output `Surface`, or `Bitmap` in Bitmap mode |

Two findings that decide the design:

**`enableDenoiseOnly` exists.** The Bitmap-mode sample constructs
`EnhancementOptions(w, h, mode, enableTonemap, enableDeblurDenoise, enableDenoiseOnly,
enableUpscale)`. Denoise fused with deblur would have been unusable here — deblur fabricates edge
sharpness, which is exactly what an operator reads to judge critical focus, so a fused switch would
have belonged behind the AI-upscaler warning rather than beside the deterministic options. The
separate flag makes it a real NR counterpart. **Confirm the semantics against the AAR** before
relying on it; this is inferred from one code sample.

**Tonemap stays off, always.** SDR-to-SDR local tone mapping would fight the LUT / Log3G10 chain
and silently move a picture someone is reading exposure off.

**The published API surface is unsettled.** Three sources give three different `EnhancementOptions`
signatures — get-started has `enableTonemap`/`enableDeblurDenoise`/`enableFaceDetection`,
bitmap-mode has the four-flag form above, and a third account has separate photo/video pairs
(`isUpscaleVideoEnabled`). Same split on the input surface: the docs have the caller supplying one
via `options.setInputSurface(...)` from an `ImageReader`, the third account has the session handing
you `session.inputSurface`. That is beta04→beta07 churn. **Read the AAR, do not design against any
published snippet.**

## The four costs

### 1. The models are a download, and we live on a camera AP with no internet

`isModuleInstalledAsync()` / `installModule()` go through Play services. An operator who installs
on set and joins the ZR's access point never gets the models — the phone has no route out. Same
class of problem as the RED LUT internet hop, and it needs the same kind of answer: prefetch while
the phone is on real internet, plus an honest unavailable-offline state rather than a switch that
does nothing. This is the largest single item and it is an OpenZCine problem, not an API one.

### 2. Matching iOS means two sessions, and we already have a heat audit

NR before the grade and SR after it are two `EnhancementSession`s on one NPU per frame. Sessions
are documented as heavyweight GPU/NPU contexts meant to be reused, not stacked. Either measure two
concurrently, or ship one and say which — but do not quietly relocate NR to after the LUT and call
it parity: post-LUT denoise gives a cleaner-looking picture while peaking carries on chewing grain,
which was the entire point of the iOS placement.

### 3. Surface mode means giving up the swapchain

`VulkanLiveFeedBackend` owns the `SurfaceView` and presents
(`Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/LiveFeedGpuBackend.kt`). Post-grade
enhancement means the backend renders into a `SurfaceTexture`/`ImageReader` and the session
presents — a real refactor of `src/main/cpp/live_feed_vk/live_feed_vk_renderer.cpp`, and again for
the GLES floor path. Pre-grade NR in surface mode is the mirror image: an
`AHardwareBuffer`→`VkImage`/`EGLImage` import so both backends can sample the enhanced output as an
external texture.

### 4. Reach

Premium tier only — Pixel 10 Pro / Galaxy S26 Ultra class, gated by `isDeviceSupportedAsync()`,
with initialization refusing outright below the threshold rather than dropping frames. That is
acceptable and mirrors iOS, where the row disappears on floor hardware. `minSdk` is 29 against the
client's `@RequiresApi(30)`, so a guard, not a blocker. GMS is already a dependency
(`play-services-wearable`), so this adds a module rather than a new class of dependency — but
no-GMS builds lose the feature entirely.

## Plan

**Stage 0 — settle the API.** Pull the current beta AAR, read `EnhancementOptions`,
`EnhancementSession` and `EnhancementCallback` directly. Confirm `enableDenoiseOnly` means denoise
without deblur, and which side owns the input surface. Nothing below is designable until this is
done.

**Stage 1 — the probe.** Bitmap mode, denoise only, at the existing decode point: we already hand a
`Bitmap` to `LiveFeedGpuBackend.submitFrame`, so it is a small diff behind
`isDeviceSupportedAsync()`. It pays the CPU/GPU round trip that surface mode exists to avoid, so it
is a probe and not a shipping shape — but it answers *does this visibly help the ZR's feed, and at
what frame rate cost* before anyone touches the swapchain. Measure on the S26 Ultra: fps, latency,
thermals over a sustained session.

**Stage 2 — decide, on evidence.** If Stage 1 is worth it, surface mode and the swapchain refactor;
if not, close this out and leave the rows saying what they say. Either outcome is a result.

**Stage 3 — the offline story.** Only if Stage 2 goes ahead: model prefetch away from the camera
AP, and the unavailable state.

**Stage 4 — UI.** Replace the two "Coming soon" rows with the iOS controls and copy, including the
"AI invents detail" warning and the supported-options-only rule.

## Explicitly not doing

A hand-rolled fallback ladder for unsupported devices — edge-aware spatial denoise, history
accumulation with neighbourhood rejection, FSR-style upscaling. That is a second renderer, built on
spec, for devices the feature was never going to reach. iOS does not have one either; it hides the
row.

Camera2 `NOISE_REDUCTION_MODE` is not a candidate: it controls the phone's own capture pipeline and
cannot touch an incoming camera feed.

## Open questions for the next pass

- Does `enableDenoiseOnly` actually suppress deblur, or only bias it?
- Is the denoise spatial only? iOS's is temporal with a reference window including future frames.
  If Android's is single-frame, it will clean the stream's compression artefacts well and moving
  sensor grain less well — which changes what the switch should promise in its help text.
- Any exposed upscale factor, or is it fixed? iOS's model caps at 960 in / 1920 out, which is why
  MetalFX carries the result the rest of the way to an iPad panel.
- Sustained-session thermals with an NPU pass in the live path, next to the existing camera-heat
  findings.
