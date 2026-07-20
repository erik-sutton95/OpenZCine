# Android GPU-native live feed (GLES → Vulkan)

**Status:** execution plan for Metal-parity presentation on Android.  
**Date:** 2026-07-20  
**Floor device:** SM-A127F (Exynos 850, Vulkan 1.1, ~3.7 GB RAM).

## Problem

Lab gfxinfo on A12 with feed + LUT only:

- JPEG decode ~7 ms @ ~48 fps (fine, background thread).
- UI frame p50 ~42 ms, **~99% janky**, GPU p50 ~18 ms.
- Live LUT path used Compose `Canvas` + AGSL `RuntimeShader` at UI size.

iOS direction is Metal present (no GPU→CPU→GPU round trip). Android’s equivalent is
**swapchain/surface present with a GPU grade pass**, not AGSL inside Compose.

## Constraints

| Stage | Reality |
| ----- | ------- |
| MJPEG HW decode | `MediaCodec video/mjpeg` **absent** on A12 and most phones |
| Decode | Keep `BitmapFactory` + `inBitmap` pool (measured best on A12) |
| Effect math SOT | Swift `FeedEffectsRenderPlan` cubes + uniforms |
| Existing GLES | `FeedEffectsGlProgram` + ES2 shaders (live 29–32 + Media3) |

## Architecture

```text
MJPEG ──CPU decode pool──► upload ──► GPU grade (GLES or Vulkan) ──► SurfaceView
Compose chrome overlays the surface (glass, bars, pickers).
```

### Backend selection

1. **Vulkan** when device reports Vulkan 1.1+ and the native module loads.
2. Else **GLES2** surface (always for live assists on API 29+).
3. **AGSL Canvas** only as last-resort wear-preview baker / high-end optional, not the live monitor default.

### Phases

| Phase | Deliverable |
| ----- | ----------- |
| 0 | `LiveFeedGpuBackend` contract + design doc |
| 1 | GLES `SurfaceView` for live+assists on **all** API 29+ (drop AGSL as live default) |
| 2 | Native Vulkan renderer + SPIR-V port of the grade pass; GLES fallback |
| 3 | Opportunistic MediaCodec MJPEG; AHardwareBuffer upload hooks when available |
| 4 | GPU histogram path (Vulkan compute or GLES reduce) feeding existing scope UI |

## Success metrics (A12)

- Live + LUT: janky frames **&lt; 40%** (from ~99%), UI p50 **&lt; 25 ms**.
- Decode still ≥ camera rate with latest-wins conflation.
- Visual parity: same Swift plan as Media3 GLES path (on-device pixel tests where feasible).

## Non-goals

- Full monitor chrome in Vulkan.
- Inventing HW MJPEG on devices that lack the codec.
- Three divergent LUT implementations — one plan, multiple adapters.
