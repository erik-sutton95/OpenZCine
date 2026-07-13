---
status: awaiting_human_verify
trigger: "iOS app killed after ~68s with Terminated due to memory issue during live view with pipelined decode, MetalLiveView, GPU capture enabled"
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:30:00Z
symptoms_prefilled: true
---

## Current Focus

hypothesis: CONFIRMED — pipelined fetch + debug GPU capture/validation + duplicate full-frame bitmaps
next_action: Human verify on device with live view + Metal + GPU scopes for 5+ minutes

## Symptoms

expected: Live view runs indefinitely without memory growth; frames released after display
actual: App terminated by iOS after ~68 seconds with "Terminated due to memory issue" (IDEDebugSessionErrorDomain code 11)
errors: Terminated due to memory issue
reproduction: Xcode debug run on iPhone 16 Pro Max, iOS 26.5, with GPU frame capture/validation, ZC_METAL_FEED=1, ZC_GPU_SCOPES=1, pipelined live view decode
started: After recent pipelined decode / off-main CI bake / MetalLiveView changes

## Eliminated

- hypothesis: LiveFrameRenderer actor queue grows unbounded
  evidence: Single actor, serial await per frame — no queue
  timestamp: 2026-07-01

- hypothesis: model.liveFrameImage alone leaks every frame
  evidence: Single slot replacement; leak required additional retention from pipeline overlap + GPU debug
  timestamp: 2026-07-01

## Evidence

- timestamp: 2026-07-01
  checked: streamUntilStall pipelining
  found: nextFrameTask started before decode/scope completed — two full JPEGs + decoded UIImage + scope re-decode in flight
  implication: Peak memory ~2× per frame; compounds with GPU paths

- timestamp: 2026-07-01
  checked: Runner.xcscheme LaunchAction
  found: enableGPUFrameCaptureMode=1, enableGPUValidationMode=1 (user session); scheme now 0/0
  implication: Debug GPU capture retains frame history → linear growth until jetsam (~68s)

- timestamp: 2026-07-01
  checked: MetalLiveView.draw
  found: task.waitUntilCompleted() blocked main thread; subagent 7e5b46c6 added MTLCaptureScope
  implication: Main-thread stall + unpresented drawables; removed waitUntilCompleted

- timestamp: 2026-07-01
  checked: LiveFrameProcessor render cache
  found: lastRenderInput + lastRenderedImage retain two full bitmaps across CPU bake path
  implication: evictCachedRender() added between frames

- timestamp: 2026-07-01
  checked: just native-check
  found: pass
  implication: Build/tests green

## Resolution

root_cause: Combined unbounded peak retention from (1) pipelined live-view fetch overlapping decode/scope work (2+ full JPEGs and bitmaps in flight), (2) Xcode debug GPU frame capture + validation retaining GPU workload history, (3) LiveFrameProcessor single-frame memo holding prior baked bitmaps on CPU path, (4) main-thread waitUntilCompleted in Metal feed draw stalling drawable release.
fix: Serial fetch-after-process pipeline (depth 1), scope sample in-flight guard, evict render cache between frames, CIContext cacheIntermediates false, remove waitUntilCompleted, scheme GPU capture/validation default off, document debug settings in ScopeAssistSampling.
verification: just native-check passes; device soak pending human verify
files_changed: [ios/Runner/NativeAppRoot.swift, ios/Runner/LiveFrameRenderer.swift, ios/Runner/LiveFrameProcessor.swift, ios/Runner/MetalLiveView.swift, ios/Runner/WaveformMetalView.swift, ios/Runner/GPUScopeSampler.swift, ios/Runner/ScopeAssistSampling.swift, ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme]
