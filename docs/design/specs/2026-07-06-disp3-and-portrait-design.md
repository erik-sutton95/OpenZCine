# DISP 3 protocol fixes + app-wide portrait support — design

Branch: `ui/general-improvements` · Approved 2026-07-06

Two workstreams: (A) protocol-correctness fixes for the DISP 3 command monitor,
(B) portrait ("vertical") support for every screen, as a single adaptive-layout pass.
Portrait is **portrait UI around a landscape feed** — the live image stays 16:9 and
letterboxes as a full-width strip. Vertical *shooting* (camera rigged 90°, 9:16 feed)
is explicitly out of scope for this branch.

## A. DISP 3 command monitor fixes

Audit result: six of eight tiles already use the documented codes (ISO `0x0001D09E` +
base circuit `0x0001D09D`, shutter `0xD1A8`/`0x0001D075`/mode `0x0001D074`, iris
`0xD1A9`, WB `0xD23A` + `0xD21A`, resolution `0xD0A0`, codec `0xD0AF`). The
standard-op (`0x1015/0x1016`) vs extended-op (`0x943A–0x943C`) split is deliberate,
per `PTPOperation.swift:58` — 2-byte props use standard ops, 4-byte extended props
use the Ex ops.

### A1. IBIS tile rewiring

Today the tile synthesizes its label from `ElectronicVR 0xD314` +
`ElectronicFrontCurtainShutter 0xD20D`; eFCS is a stills-only setting and wrong on a
video monitor. Movie stabilization is `MovieVibrationReduction 0xD1F9`
(`PTP_DPC_NIKON_MovieVibrationReduction`, libgphoto2 ptp.h:2691), currently unused.

- Add `movieVibrationReduction = 0xD1F9` to `PTPPropertyCode`; add to the
  live-monitor poll order; runtime-enumerated decode (same pattern as existing
  pickers); new snapshot field.
- `stabilizationSummary` combines **VR (0xD1F9) + e-VR (0xD314)**; eFCS leaves the
  tile (property code stays in the codebase).
- The tile gets a picker with two segments — VR (mechanical/lens) and e-VR
  (electronic) — writing both as 2-byte props via standard `SetDevicePropValue
  0x1016` through the existing safe-point write queue. Rejections (`0xA0xx`) surface
  via the existing message path. Writes tagged verify-on-HW until tested on a real ZR.

### A2. Un-stub codec and resolution writes

Codes are correct; writes are stubbed (`request()` returns nil for `.codec`, and
resolution only patches the fps byte).

- Codec: pack the `0xD0AF` UINT32 (codec≪16 | depth≪8 | container), preserving the
  snapshot's current depth/container — mirror of the read decode.
- Resolution: write the full `0xD0A0` UINT64 selected from the camera's enumerated
  modes, replacing the fps-byte-only patch.
- Both through the safe-point queue with surfaced rejection. **On-device validation
  on the ZR is the acceptance gate for this item** — Nikon bodies commonly reject
  these mid-live-view; if the body always refuses, the surfaced message is the
  shipped behavior.

### A3. Internal protocol notes fix

The internal property-wire notes claim all props flow
through the Ex ops; correct them to match `PTPOperation.swift:58` (2-byte props →
standard `0x1015/0x1016`; Ex ops for 4-byte extended props only).

### A4. Tests

Swift Testing units for: `0xD1F9` decode (enumerated values → labels), the new
stabilization summary composition, codec UINT32 packing (depth/container
preservation), resolution UINT64 write encoding.

## B. Portrait support (big-bang adaptive pass)

### B1. Foundation

- **Unlock:** add `UIInterfaceOrientationPortrait` to both
  `UISupportedInterfaceOrientations` sets in `ios/Runner/Info.plist` (no
  upside-down).
- **One source of truth:** orientation is size-driven — portrait ⇔ height > width
  from geometry — exposed once through the SwiftUI environment. UIKit orientation
  queries remain only where physically needed (landscape-left/right mirroring).
  `MonitorDeviceOrientationReader` gains real portrait cases (today portrait maps to
  `.unknown`); `MonitorHorizontalLayoutDirection.resolve()` learns portrait.
- **Layout policy in core:** `MonitorLayoutPolicy` gains a portrait chrome layout —
  side rails become top/bottom decks, `chromeInsets` flip axis. Unit-tested in core,
  UI-free.
- Landscape behavior stays pixel-identical throughout.

### B2. Portrait monitor (live view)

Vertical zone stack on iPhone 390×844 pt (values are design targets, not constants):

| Zone | Height | Content |
| --- | --- | --- |
| Info bar | ~44 pt | timecode, clip/reel, media, battery |
| Live feed | 219 pt | full-width 16:9 strip |
| Scopes frame | ~150 pt | waveform / histogram / vectorscope; tap to swap scope |
| Paged controls | ~230 pt | 3 swipeable pages: **Control** (quick tiles: ISO, shutter, iris, WB, res/fps, codec), **Grid** (framing guides, grids, crosshair, level), **Assist** (peaking, zebra, LUT, desqueeze) |
| Record row | ~120 pt | record button + assist shortcuts, above home indicator |

DISP cycling in portrait: **live** = full stack; **clean** = scopes frame and pages
collapse, feed + record only; **command** = everything below the feed becomes the
command grid at 2 columns (side columns of the landscape dashboard stack above it).

### B3. Other screens

- **Startup/link:** `StartupContentLayout.fit()` gains a portrait branch — single
  column; wizard cards and saved-camera list stack full-width. Join popup unchanged
  (already a centered card).
- **Media browser:** the fixed 172 pt sidebar becomes a horizontal filter strip above
  the grid; thumbnail grid reflows via its existing adaptive columns; player and
  photo viewer center media with transport below (already portrait-shaped).
- **Settings:** vertical tab rail flips to a horizontally scrollable top tab strip,
  content below.
- **RED download:** web view reflows; verify the blocking cover in portrait.

### B4. Verification

Every screen screenshot-verified in **both** orientations in the simulator (portrait
shots don't need the `sips -r -90` rotation), all four edges checked per CLAUDE.md.
`just native-check` green. Core layout-policy changes covered by unit tests.

## Out of scope

- Vertical shooting (9:16 feed, camera rigged 90°).
- Upside-down portrait.
- iPad multitasking (`UIRequiresFullScreen` stays).
