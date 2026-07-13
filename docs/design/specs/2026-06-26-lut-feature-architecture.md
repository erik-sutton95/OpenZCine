# OpenZCine LUT feature — architecture (umbrella spec)

- **Status:** Draft (awaiting review)
- **Date:** 2026-06-26
- **Scope:** Whole feature, spanning `Sources/OpenZCineCore` (portable) and `ios/Runner` (shell)

This is the umbrella design for the full LUT feature. It fixes the cross-phase decisions so the
five phases don't paint each other into a corner. Each phase keeps its own detailed spec + plan;
this document is the shared blueprint. Phase 1 (assist-bar interaction + popup unification) has its
own spec: [2026-06-26-assist-bar-interaction-and-popup-unification-design.md](2026-06-26-assist-bar-interaction-and-popup-unification-design.md).

## What we're building

A **LUT (Look-Up Table) monitoring tool** on the live view: the operator applies a 3D `.cube` LUT
to the displayed image to preview a graded look on the camera's log/flat signal. LUTs come from
three sources:

1. **Generated open conversions** — N‑Log→Rec.709 and RWG/Log3G10→Rec.709, computed from published
   transfer functions (redistributable; no proprietary assets in the repo).
2. **Custom `.cube` import** — the operator's own files, via the Files picker.
3. **RED official IPP2 Output Presets** — downloaded through RED's own ToC-gated page (never
   bundled), organized by contrast / highlight roll-off.

Modelled on the archived Flutter prototype's `lib/lut/` subsystem
([cube_lut](../../../reference/flutter-prototype/lib/lut/cube_lut.dart),
[lut_library](../../../reference/flutter-prototype/lib/lut/lut_library.dart),
[red_download_page](../../../reference/flutter-prototype/lib/lut/red_download_page.dart)), ported to
Swift and iOS-native rendering.

## Phase roadmap & dependencies

| Phase | Deliverable | Depends on |
| --- | --- | --- |
| 1 | Assist-bar interaction (tap/long-press) + popup unification | — |
| 2 | LUT engine: `.cube` parser + library (core), `CIColorCube` live-view application (shell), LUT button + compact drawer, one generated N‑Log→709 | 1 |
| 3 | Custom `.cube` import (Files → library) | 2 |
| 4 | Full generated conversions (N‑Log→709, RWG/Log3G10→709) + full-screen library w/ organization | 2 |
| 5 | RED acquisition (WebView + ToC + download/unzip) + contrast/roll-off facets | 4 |

Each phase: branch → tests → `just native-check` green → PR.

## Architecture: core vs. shell boundary

The core stays UI-free and portable (CLAUDE.md). Anything touching sockets, GPU, WebView, files,
or UI lives in the shell.

| Concern | Layer | Notes |
| --- | --- | --- |
| `.cube` parse → `CubeLUT` value type | **Core** | Port of `parseCubeLut`. Pure, fully testable. |
| LUT library model (`StoredLUT`, categories, default pick, facet parsing) | **Core** | Pure logic over filenames/metadata; file I/O is injected. |
| Generated conversion math (Log3G10, N‑Log transfer fns → cube samples) | **Core** | Pure math → `CubeLUT`; golden-value tested. |
| Active-LUT selection state (persisted) | **Core** | Add to `AssistConfiguration` (Codable), like guides/grid. |
| `CIColorCube` application on live-view frames | **Shell** | Core Image; reused `CIContext`; perf-critical. |
| LUT file storage (`<app documents>/luts`) | **Shell** | Foundation file APIs; library model is injected the dir. |
| Zip extraction (RED download) | **Shell** | Needs a dependency (ZIPFoundation); core never sees zips. |
| RED `WKWebView` + ToC + `WKDownload` | **Shell** | "Present, don't bypass" posture preserved from prototype. |
| Custom import (`.fileImporter`, `.cube` UTType) | **Shell** | — |
| LUT button / drawer / full-screen library UI | **Shell** | SwiftUI. |

### `.cube` parsing (core)

Port `CubeLut` + `parseCubeLut`: parse `LUT_3D_SIZE` + RGB triplets, red-fastest order, domain
0–1, skipping comments/metadata; throw a typed `LocalizedError` (not Flutter's `FormatException`)
on a missing or out-of-range `LUT_3D_SIZE` (`2...64`), a non-default `DOMAIN_*`, or a triplet-count
mismatch. Value type, `Sendable`.

### LUT application (shell, Phase 2)

Core Image gives us the 3D-LUT filter natively, so we do **not** hand-roll the atlas+shader the
Flutter prototype needed:

- Build a `CIFilter.colorCube()` (`CIColorCube`) / `CIColorCubeWithColorSpace` from the parsed
  `CubeLUT` once per LUT selection — **not per frame** (cache the filter + a single shared
  `CIContext`).
- Insert it between live-view frame decode and display. The exact hook is pinned in Phase 2 after
  reading the decode path (`LiveFeedModule`, [MonitorExperience.swift:194](../../../ios/Runner/MonitorExperience.swift));
  the recent OOM fix (autoreleasing frame decodes, reusing the image view) means the integration
  must avoid per-frame allocations and honour the existing reuse.
- **Data layout caveat:** `CIColorCube` expects the cube as a flat `Float32` array laid out with
  red varying fastest within `[b][g][r]`, RGBA, premultiplied-not-required; the parser's
  red-fastest RGB order maps with a known repack. Validate against a golden identity LUT (a LUT
  that must round-trip the image unchanged).
- Off when no LUT selected (identity / filter bypassed) — zero cost on the default path.

### LUT library & storage (core model + shell I/O)

- `StoredLUT { fileName, displayName, category, url }`; library lists/imports/deletes `.cube`
  files under an injected root (`<app documents>/luts` in production, a temp dir in tests) — same
  shape as the prototype's `LutLibrary`.
- **Categories** come from the source: a RED zip's folder names, or `Imported` for file imports,
  or `Generated` for the built-in conversions.
- **Facets (Phase 5):** parse RED's filename tokens (`REC709`, `*_CONTRAST`, roll-off `R_1..R_5` /
  `SOFT`/`MEDIUM`/`HARD`) into structured facets for browse-by-contrast/roll-off. `pickDefaultRec709`
  (prefer REC709 + medium contrast + soft roll-off) ports directly.

### Generated conversions (core, Phase 4; one in Phase 2)

Compute `.cube` samples from published transfer functions — these are math, not assets, so they're
genuinely open and committable (or generated at first run into the library):

- **N‑Log → Rec.709:** Nikon N‑Log inverse OETF → linear scene → Rec.709 OETF (+ a standard
  display tone curve). Golden-value tested at known stops.
- **RWG/Log3G10 → Rec.709:** Log3G10 decode → REDWideGamutRGB→Rec.709 primaries matrix → Rec.709
  OETF. Golden-value tested.

These ship as the "open" alternative to RED's official LUTs.

### RED acquisition (shell, Phase 5)

Faithful port of the prototype's compliance posture: a native gateway screen → `WKWebView` to RED's
real IPP2 Output Presets page → inject the same phone-friendly T&C helper CSS/JS via `WKUserScript`
→ user accepts RED's **real** terms → intercept the user-triggered download via `WKDownload`
(forwarding cookies/UA) → unzip → import into the library. **We present, we do not bypass**: no
auto-accept, no constructed deep link, no scraping.

## Storage & licensing posture (hard constraints)

- **Never commit RED or other vendor `.cube` files** to this public repo (CLAUDE.md: no
  non-redistributable assets). RED LUTs live only in app storage after the user's ToC-gated
  download.
- Generated conversions are computed from documented math → redistributable.
- Custom imports are the user's own files in app storage.
- `.gitignore` must exclude any runtime LUT store and any downloaded/binary `.cube` (tests use
  small synthetic fixtures, not vendor files). Verify the pre-commit proprietary guard covers this.

## UX summary

- **LUT button** on the bottom assist bar (Phase 2), using the Phase 1 interaction model:
  - **Tap** → toggle the active LUT on/off (identity when off).
  - **Long-press** → a **compact drawer** (picker-style slide-up, per Phase 1): active LUT, a
    quick-pick of recent/favourite LUTs, **None**, and a **Manage…** affordance.
- **Manage…** → a **full-screen LUT library**: browse (by category, and by contrast/roll-off for
  RED), select, delete, **Import file**, and **Download from RED**.

## Cross-phase risks

- **Live-view performance** — Core Image per frame must reuse context/filter and avoid allocations;
  measure against the OOM-sensitive frame path. Primary technical risk; front-loaded in Phase 2.
- **`CIColorCube` data layout** — wrong repacking silently corrupts color; guard with an identity
  golden test.
- **Color accuracy of generated LUTs** — validate transfer-function math with golden values; these
  are monitor previews, not graded masters, but must be visibly correct.
- **Zip dependency** — adds an SPM/shell dependency (ZIPFoundation) for Phase 5 only.
- **`WKDownload` + session cookies** — RED's CDN link is session-gated; cookie/UA forwarding must
  match the WebView, as in the prototype.

## Acceptance (feature-level, realized across phases)

Operator can: toggle a LUT from the assist bar; pick among generated conversions; import a custom
`.cube`; download RED's official LUTs after accepting RED's terms; and see the selected LUT applied
live with no perceptible frame-rate regression — with no proprietary assets committed to the repo.
