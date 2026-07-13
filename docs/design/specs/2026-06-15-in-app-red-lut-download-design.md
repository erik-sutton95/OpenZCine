# In-App RED LUT Download — Design

**Date:** 2026-06-15
**Status:** Approved (verbal), implementation in progress
**Author:** Claude Code (with Erik Sutton)
**Production-stack note:** This Flutter/Dart design remains the prototype reference. Production should
port pure LUT parsing/storage decisions into the shared Swift core where portable, while WebView,
download, file storage, and GPU preview stay platform-native in SwiftUI/iOS services and
Jetpack/Android services.

## Goal

Let a user obtain RED's IPP2 Output Presets (3D LUTs) **inside the app**, legally, by
presenting RED's real download page in an embedded WebView. The user reads and accepts
RED's terms and taps RED's own Download button; the app intercepts the resulting `.zip`,
unzips it, stores the `.cube` files in the app's private storage, and exposes them through
a LUT picker that feeds the existing GPU LUT pipeline.

## Why (compliance)

RED's IPP2 presets are proprietary; redistribution (bundling them in the app or serving
them from our own CDN) is **not** permitted. The compliant model is **runtime user import**:
the bytes come from RED, and the *user* accepts RED's terms. This feature automates none of
that — it **presents, it does not bypass**:

- The WebView loads **RED's actual page** (`https://www.reddigitalcinema.com/download/ipp2-output-presets`).
- We do **not** auto-accept the terms, scrape the catalog, or construct a deep link to the asset.
- We intercept **only** the download the user themselves triggers after agreeing.
- Downloaded cubes live in the app's private documents directory and are never redistributed.

## Architecture

A small, testable LUT-storage layer plus a thin WebView screen, plugged into the existing
`cube_lut.dart → lut_atlas.dart → shaders/lut3d.frag` pipeline. The pure logic (unzip,
storage layout, default-cube selection) is isolated from the platform plumbing (WebView,
network) so it can be unit-tested without a device.

**New dependencies:**

- `flutter_inappwebview` (`^6.0.0`) — embedded WebView + download interception
  (`useOnDownloadStart` / `onDownloadStartRequest`).
- `archive` (`^3.6.0`) — pure-Dart zip decoding.
- `path_provider` (`^2.1.0`) — app documents directory.

`file_picker` (already a dependency) is retained for "import your own `.cube`". We fetch the
download ourselves with `dart:io HttpClient` (no `flutter_downloader` — fewer dependencies,
no notification permissions, save straight to app-internal storage).

## Components

### `lib/lut/zip_extract.dart` (pure)

```text
class CubeEntry { final String path; final Uint8List bytes; }
List<CubeEntry> extractCubeEntries(Uint8List zipBytes)
```

Decodes the zip, returns entries whose name ends in `.cube` (case-insensitive), skipping
directories and `__MACOSX/` metadata. Throws `FormatException` if the archive contains no
`.cube` files. No filesystem, no Flutter — directly unit-testable with an in-memory zip.

### `lib/lut/lut_library.dart`

Manages the on-disk LUT store and the default-cube heuristic.

```text
class StoredLut {
  final String fileName;     // e.g. "REC709__RWG_Log3G10_to_REC709..._MEDIUM_CONTRAST...cube"
  final String displayName;  // human label derived from fileName
  final String category;     // leading zip folder (e.g. "REC709"), or "Imported"
  final String path;         // absolute path on disk
}

class LutLibrary {
  LutLibrary(this.root);          // root Directory injected (tests pass a temp dir)
  Future<List<StoredLut>> list();                       // *.cube in root, sorted
  Future<List<StoredLut>> importZipBytes(Uint8List);    // extract + write, return stored
  Future<StoredLut> importCubeFile(String sourcePath);  // copy external .cube in
  Future<void> delete(StoredLut);
}

// Pure, top-level:
StoredLut? pickDefaultRec709(List<StoredLut> luts);
```

Storage layout: cubes are written into `root` with a flattened filename that prefixes the
zip category folder, e.g. `REC709/Foo.cube` → `REC709__Foo.cube`. `displayName` and
`category` are derived from that filename by splitting on the `__` separator and tidying
underscores. `importZipBytes` overwrites existing files of the same name (re-download is
idempotent).

`pickDefaultRec709` selects the auto-apply target: a cube whose name contains both `REC709`
and `MEDIUM_CONTRAST` (case-insensitive), preferring one that also contains `R_3` or `SOFT`;
falls back to the first `REC709` match; returns `null` if none match (caller then leaves the
LUT off and the user picks manually).

### `lib/lut/lut_downloader.dart`

```text
Future<Uint8List> downloadBytes(Uri url, {String? cookieHeader, String? userAgent})
```

Fetches the asset with `dart:io HttpClient`, sending the WebView's cookies and user-agent so
session-gated CDN links resolve. Follows redirects. Throws on a non-2xx status. Thin and
`dart:io`-only (no Flutter import).

### `lib/lut/red_download_page.dart`

`RedDownloadPage` (StatefulWidget). Hosts an `InAppWebView` that loads RED's real URL with
`InAppWebViewSettings(useOnDownloadStart: true)`. On `onDownloadStartRequest`:

1. Read cookies for the URL via `CookieManager` and build a `Cookie` header.
2. `downloadBytes(url, cookieHeader: ..., userAgent: ...)`.
3. `library.importZipBytes(bytes)` (or `.cube` directly if the download is a single cube).
4. `Navigator.pop(context, importedLuts)`.

UI: a one-line banner ("Read and accept RED's terms below, then tap Download") and a
progress overlay shown while downloading/extracting. A back button returns without importing.

### `lib/lut/lut_picker_sheet.dart`

```text
Future<StoredLut?> showLutPickerSheet(BuildContext, LutLibrary, {String? currentFileName})
```

A modal bottom sheet:

- Header actions: **Download from RED** (pushes `RedDownloadPage`), **Import file**
  (`file_picker`), **None** (returns a sentinel that turns the LUT off).
- Body: the stored cubes from `library.list()` as a flat, tappable list (the selected one is
  marked); each row has a delete affordance.
- Returns the chosen `StoredLut`, or `null` if dismissed, or the "None" sentinel.

After a successful RED download the sheet auto-selects `pickDefaultRec709(...)` so the user
immediately sees the standard REC709 medium-contrast look, while still being able to browse
all 32 cubes.

### `lib/live_view_page.dart` (integration)

The existing "Load LUT" button becomes a LUT button that opens the picker sheet. The chosen
`StoredLut` flows through the unchanged path: `parseCubeLut(File(path).readAsString())` →
`decodeLutAtlas(...)` → `setState`. A `LutLibrary` rooted at
`getApplicationDocumentsDirectory()/luts` is created once on init. The ON/OFF toggle and the
fps/jitter overlay are unchanged.

## Data flow

```text
LUT button → picker sheet → "Download from RED"
  → RedDownloadPage (WebView shows RED's page)
  → user reads + accepts T&C + taps RED's Download
  → onDownloadStartRequest(url) → read cookies → downloadBytes(url)
  → extractCubeEntries → importZipBytes writes N cubes to <docs>/luts/
  → pop(importedLuts) → auto-apply pickDefaultRec709
  → parseCubeLut → decodeLutAtlas → lut3d.frag renders
Later: picker sheet lists all stored cubes; tap any to apply, delete to remove.
```

## Error handling

| Failure | Handling |
| --- | --- |
| WebView fails to load | In-page message + back button; live view unaffected |
| Download non-2xx / network error | Snackbar in the page; stay on the page to retry |
| Download is neither zip nor `.cube` | `FormatException` → snackbar |
| Zip contains no `.cube` files | `FormatException("no .cube files in archive")` → snackbar |
| `.cube` parse fails on apply | Existing snackbar path in `live_view_page` |
| Storage write fails | Surfaced via snackbar |

## Testing

- `test/lut/zip_extract_test.dart` — build an in-memory zip (nested `.cube` files + a
  non-cube + a `__MACOSX/` entry) with `archive`'s encoder; assert only `.cube` entries are
  returned with correct paths and bytes; assert it throws when the archive has no cubes.
- `test/lut/lut_library_test.dart` — point `root` at a temp dir: `importZipBytes` writes the
  expected files; `list()` returns them sorted with derived `displayName`/`category`;
  `importCubeFile` copies an external cube in; `delete` removes; `pickDefaultRec709` selects
  the REC709 medium-contrast cube from a representative name set (and returns `null` when no
  REC709 cube is present).
- Existing `cube_lut_test.dart` / `lut_atlas_test.dart` unchanged.
- **Not unit-tested (explicit gap):** `red_download_page.dart` (platform WebView) and
  `lut_downloader.dart` (live network) — covered by on-device validation, not hidden behind
  a green suite.

## Risks / verify-on-device

1. **iOS minimum deployment target.** WKWebView's download delegate
   (`onDownloadStartRequest`) requires **iOS 14.5+**. Bump the Runner target and Podfile from
   13.0 → 14.5 (harmless on a modern test device).
2. **RED download shape** `[VERIFY-ON-DEVICE]`. We handle a GET to a (possibly redirected,
   cookie-gated) CDN URL. If RED triggers the download via a POST form submission,
   `onDownloadStartRequest` may not carry the request body; the fallback is to let the
   WebView's native download complete and read the resulting file. Flagged, not assumed away.
3. **Android.** Saving to the app-internal documents dir needs no storage permission;
   `INTERNET` is granted by default.

## Out of scope (YAGNI)

- Background/resumable downloads, progress percentage (a spinner is enough for an ~12 MB zip).
- Cloud sync or sharing of stored LUTs.
- Editing/normalizing cubes beyond what the existing parser does.
