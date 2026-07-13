---
status: awaiting_human_verify
trigger: "Waveform and Parade scopes do NOT update until user enables Histogram assist"
created: 2026-07-01T18:00:00Z
updated: 2026-07-01T18:00:00Z
symptoms_prefilled: true
---

## Current Focus

reasoning_checkpoint:
  hypothesis: "ZC_GPU_SCOPES=1 + GPUScopeSampler available: shouldSample returns false for waveform/parade-only, so scopeScatterFrame never updates; enabling histogram makes shouldSample true and unblocks scatter frame refresh"
  confirming_evidence:
    - "ScopeAssistSampling.shouldSample lines 90-92 only return true for histogram/trafficLights when gpuScopes && gpuHistogramSamplerAvailable"
    - "scopeScatterFrame assignment is inside if shouldSampleScopes block (NativeAppRoot ~1904)"
    - "GPU Waveform/Parade use ScopeScatterView(image: frame) not scopeAssist.samples"
    - "Runner.xcscheme sets ZC_GPU_SCOPES=1 by default"
  falsification_test: "Include waveform/parade in shouldSample GPU branch → scatter updates without histogram"
  fix_rationale: "GPU scatter scopes need the throttle tick to publish scopeScatterFrame; shouldSample must be true when they are visible"
  blind_spots: "Playback path uses CPU ScopeMini without frame param — separate code path"

hypothesis: CONFIRMED — shouldSample GPU gate excludes waveform/parade
next_action: Fix shouldSample; run just native-check

## Symptoms

expected: Waveform and parade scopes update independently when visible
actual: They stay frozen until histogram assist is enabled
errors: none
reproduction: Enable waveform or parade only on live view with ZC_GPU_SCOPES=1 (scheme default)
started: After scope sampling refactor for GPU waveform/parade

## Eliminated

- hypothesis: needsPointSamples returns false blocking all sampling
  evidence: needsPointSamples only affects includePoints in CPU sampler; GPU path uses frame scatter
  timestamp: 2026-07-01

- hypothesis: scopeSampleInFlight stuck
  evidence: Gate never entered when only waveform/parade — in-flight guard irrelevant
  timestamp: 2026-07-01

- hypothesis: WaveformScopePlot Equatable throttling
  evidence: GPU path uses ScopeScatterView not WaveformScopePlot when gpuScopes on
  timestamp: 2026-07-01

- hypothesis: visibleAssistTools missing waveform/parade
  evidence: Panels render when enabled; freeze is content not visibility
  timestamp: 2026-07-01

## Evidence

- timestamp: 2026-07-01
  checked: ScopeAssistSampling.shouldSample
  found: GPU+histogram sampler branch returns histogram||trafficLights only
  implication: waveform/parade-only skips entire sampling block including scopeScatterFrame

- timestamp: 2026-07-01
  checked: NativeAppRoot live loop 1890-1916
  found: scopeScatterFrame updated only inside shouldSampleScopes
  implication: histogram enable is accidental unblock

- timestamp: 2026-07-01
  checked: MediaBrowser playback path
  found: PlaybackAssistOverlayModule uses CPU samples only; PlaybackEffectsBox always includePoints
  implication: playback unaffected by this bug

## Resolution

root_cause: ScopeAssistSampling.shouldSample omitted waveform/parade when GPU scopes and GPU histogram sampler are active; scopeScatterFrame refresh is gated on shouldSample, so GPU scatter views never receive new frames until histogram/traffic lights trigger sampling.
fix: Return true from shouldSample when waveform or parade are visible in the GPU+histogram-sampler branch.
verification: just native-check passed (format, Swift package build+tests, iOS build)
files_changed: [ios/Runner/ScopeAssistSampling.swift]
