# Android ↔ iOS parity pack — performance & architecture audit

**Date:** 2026-07-20  
**Branch:** `feat/android-assist-tools-parity`  
**Kaneo:** OPE-106 (parent), OPE-51 (media), OPE-52 (playback)  
**Devices:** Galaxy A12 lab phone (landscape) vs iOS Simulator (landscape)

## Scope of this session

| Track | Status | Notes |
| --- | --- | --- |
| Camera drop / disconnect hang | **Fixed (core)** | UI-first leave monitor; 2s teardown bound before EndLiveView; LV stall escalate → session Disconnected after 3 pump ends |
| LUTs | **Major progress** | Built-in/custom/delete/import parity; RED download WebView + zip import; internet hop CTA still needs Frame.io hop reuse |
| Splash | **Fixed** | Landscape HStack, 0.22 corner radius, responsive logo size |
| Media browse | **Partial** | Glass filter popup + FILTER badge; listing count / sweep-select / density placement still open |
| Playback | **Partial** | Compact transport glyphs; buffer underlay, share placement, clip slide animation still open |
| Perf / arch audit | **This doc** | |

## Architecture requirements (project contract)

1. **Swift core** owns portable business / protocol / LUT / media classification math.  
2. **SwiftUI** is the iOS shell only.  
3. **Kotlin + Compose** is the Android shell; adapters own sockets, permissions, lifecycle, storage, UI.  
4. **Small JNI/facade boundary** — no re-implementation of PTP or cube policy in Kotlin.

### Compliance assessment

| Area | Verdict | Detail |
| --- | --- | --- |
| Live feed GPU (GLES/Vulkan) | **Good / shell-local** | Present path correctly stays in Android adapters. Glass FULL correctly falls back to Compose so Kyant can sample. |
| Live view / disconnect | **Improved** | Was shell-awaiting native teardown (anti-pattern vs iOS). Now UI-first. Facade still owns EndLiveView → CloseSession. |
| LUT parse / pack | **Good** | `LUTLibraryWire` + Swift validate/pack; Kotlin stores files only. |
| RED download | **Acceptable shell** | WebView + DownloadManager is platform-owned; cube import still hits Swift validate. Prefer not to re-encode RED short names in Kotlin forever — expose `RedPresetName.short` / `defaultRedLUT` over JNI. |
| Media library filters | **Good** | Filter model is Kotlin UI over shared classification where applicable; no protocol invent. |
| Playback assists | **Mostly good** | Assists share models with live; scope sampling uses TextureView path on playback (correct). |
| Operator Settings LUT rows | **Debt** | Dead `StoredLutLibraryRows` / `RedLutWorkflowRows` still compile but are unused — iOS keeps LUT out of settings. Delete or never surface. |

### Sub-par findings (challenge list)

1. **Kotlin reimplementation of RED naming / default heuristics**  
   `PlaybackAssistOptions.shortRedPresetName` / `defaultRedLutEntry` approximate core `RedPresetName` / `LUTLibraryIndex.defaultRedLUT`. **Risk:** drift. **Fix:** thin JNI to Swift core.

2. **`RedLutDownloadConfiguration.UNCONFIGURED` messaging**  
   Still implies a private authorized endpoint; iOS uses the **public** RED page. Gateway no longer blocks on that flag, but status strings in settings-dead code are misleading.

3. **Internet hop not wired for RED**  
   Frame.io owns `FrameioCameraApHop`. RED gateway has a stub hop. **Fix:** extract shared `CameraApInternetHop` used by Frame.io and RED (docs/flows/internet-hop.md).

4. **Live-view stall escalate reuses USB terminal path**  
   `markLiveViewStreamExhausted` calls `markTerminalEventChannelEnded`, which sets Connecting then Disconnected. Works for recovery but logs “event channel” semantics. **Fix:** rename/generalize to `markSessionTerminal(reason)`.

5. **Compose + SurfaceView glass ordering**  
   FULL glass forces Compose present — correct. Mid-tier FULL + AGSL may jank; demote policy exists. Document that FLAT + GPU is the production floor path.

6. **Media library sample clips**  
   `samples/*.mp4` stages for **demo live feed**, not media browse. Operators/tests must seed cache or camera listing. Document in DemoHarness comments (already partially true).

7. **Playback transport still not true SF Symbol vectors**  
   Unicode glyphs are better than MUTED/AUDIO words but not asset-parity with iOS. Prefer vector drawables.

8. **MonitorSessionRecovery + property poll mutex**  
   Disconnect still waits the command mutex if a property read is in flight (bounded better now). Consider generation-cancelled property refresh that never blocks disconnect > 100ms.

9. **Scalability / multicam**  
   Single-session assumption remains. Production multicam needs session registry in core + multi-surface shells — out of scope but architecture should not bake “one global ActiveSessionSlot” forever without an ownership model.

10. **Reliability on large sets**  
    - Need bounded I/O everywhere (done for teardown path; frame GetLiveView still ~10s poll without whole-tx deadline on Android facade).  
    - Prefer iOS-style 6s frame deadline that **closes the command socket**.  
    - Link RECOVERING badge without action is cosmetic; escalate is better (now partially done).

## Performance notes (A12 floor)

| Path | Expectation |
| --- | --- |
| FLAT glass + GLES graded feed | Production path; keep |
| FULL glass force | Confirmed pretty, **not viable** on A12 (Mali SIGSEGV under load) |
| Settings over live feed | Feed paused while overlay open — required on floor devices |
| Disconnect dead link | Should leave UI in **ms**; native ≤ ~2–4s background |

## Recommended next commits (priority)

1. Wire RED hop to shared camera-AP internet hop.  
2. JNI `defaultRedLUT` + `RedPresetName.short`.  
3. Whole-transaction live-frame deadline (6s) in `PTPIPClientSession`.  
4. Media: progressive listing count, filter-empty copy, density control on rail bottom, grid spacing 16.  
5. Playback: buffer underlay scrubber, share/deliver chrome map, spring chrome hide.  
6. Delete dead settings LUT composables.  
7. Architecture doc: single session → multi-session roadmap.

## Commits on this branch (session)

- `fix(android): pause live feed under settings; glass samples Compose feed`
- `fix(android): clear monitor UI before session teardown on disconnect`
- `fix(android): match iOS launch splash landscape layout and logo corner`
- `feat(android): bound disconnect, escalate LV stalls, RED LUT download flow`
- `feat(android): glass media filters and compact playback transport glyphs`

## Verification

```sh
just android-install R58R92BL76K
# Manual: disconnect while live; LUT picker Built-in/RED/Custom; splash landscape;
# media FILTER glass; playback transport landscape.
just android-check   # before PR
just check
```
