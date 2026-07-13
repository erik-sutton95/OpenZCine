# In-App RED LUT Download — Implementation Plan

**Goal:** Let the user download RED's IPP2 LUT `.zip` from RED's real page inside an embedded
WebView, unzip + store the cubes locally, and apply them through the existing GPU LUT pipeline.

**Architecture:** A pure unzip helper + a file-backed `LutLibrary` (testable), a `dart:io`
downloader, a WebView screen that intercepts RED's download, and a picker sheet — wired into
`live_view_page.dart`. Compliance: present RED's page, never bypass it.

**Tech Stack:** Flutter/Dart, `flutter_inappwebview`, `archive`, `path_provider`, `dart:io`.

**Production-stack note:** Treat this as the Flutter prototype plan. Production should keep the legal
runtime-import model, port pure LUT logic where useful, and implement WebView/download/storage/GPU
preview through native iOS and Android services.

---

### Task 1: Dependencies + iOS deployment target

**Files:** Modify `pubspec.yaml`, `ios/Podfile`, `ios/Runner.xcodeproj/project.pbxproj`.

- [ ] Add to `pubspec.yaml` dependencies: `flutter_inappwebview: ^6.0.0`, `archive: ^3.6.0`,
  `path_provider: ^2.1.0`.
- [ ] `flutter pub get`.
- [ ] Bump `platform :ios, '13.0'` → `'14.5'` in `ios/Podfile`.
- [ ] Bump all three `IPHONEOS_DEPLOYMENT_TARGET = 13.0;` → `14.5;` in `project.pbxproj`.

### Task 2: `lib/lut/zip_extract.dart` (pure) + test

**Files:** Create `lib/lut/zip_extract.dart`, `test/lut/zip_extract_test.dart`.

- [ ] Write failing test: build an in-memory zip with `ZipEncoder`/`Archive` containing
  `REC709/a.cube`, `REC2020/b.CUBE`, `notes.txt`, and `__MACOSX/._a.cube`; assert
  `extractCubeEntries` returns exactly the two cubes with correct `path` + `bytes`; a zip with
  no cubes throws `FormatException`.
- [ ] Implement `CubeEntry{path, bytes}` and `extractCubeEntries(Uint8List)` using
  `ZipDecoder().decodeBytes`, filtering `isFile && name.toLowerCase().endsWith('.cube')` and
  excluding paths containing `__MACOSX/`.
- [ ] Test passes.

### Task 3: `lib/lut/lut_library.dart` + test

**Files:** Create `lib/lut/lut_library.dart`, `test/lut/lut_library_test.dart`.

- [ ] Write failing tests against a temp-dir `root`: `importZipBytes` writes one file per cube
  named `<category>__<base>.cube`; `list()` returns them sorted with derived `displayName`
  (underscores → spaces) and `category`; `importCubeFile` copies an external `.cube` in with
  category `Imported`; `delete` removes the file; `pickDefaultRec709` returns the
  `REC709`+`MEDIUM_CONTRAST` cube (preferring `R_3`/`Soft`) and `null` when none match.
- [ ] Implement `StoredLut`, `LutLibrary(root)`, and pure `pickDefaultRec709`. Sanitize zip
  paths into flat filenames; derive `displayName`/`category` by splitting on `__`.
- [ ] Tests pass.

### Task 4: `lib/lut/lut_downloader.dart`

**Files:** Create `lib/lut/lut_downloader.dart`.

- [ ] Implement `downloadBytes(Uri, {String? cookieHeader, String? userAgent})` with
  `HttpClient`: set `Cookie`/`User-Agent` headers when provided, follow redirects, throw
  `HttpException` on non-2xx, collect and return `Uint8List`.

### Task 5: `lib/lut/red_download_page.dart`

**Files:** Create `lib/lut/red_download_page.dart`.

- [ ] `RedDownloadPage(library)`: `InAppWebView` loads
  `https://www.reddigitalcinema.com/download/ipp2-output-presets` with
  `InAppWebViewSettings(useOnDownloadStart: true)`. Compliance banner + back button.
- [ ] `onDownloadStartRequest`: read cookies via `CookieManager`, build cookie header,
  `downloadBytes`, then `importZipBytes` (or treat a lone `.cube` as one entry), show a
  progress overlay, `Navigator.pop(importedLuts)`. Snackbar on failure, stay on page.

### Task 6: `lib/lut/lut_picker_sheet.dart`

**Files:** Create `lib/lut/lut_picker_sheet.dart`.

- [ ] `showLutPickerSheet(context, library, {currentFileName})`: modal sheet with header
  actions (Download from RED → push `RedDownloadPage`; Import file → `file_picker` →
  `importCubeFile`; None → sentinel), and a flat list of `library.list()` cubes (tap to
  return, delete icon to remove + refresh). Returns chosen `StoredLut`, the None sentinel, or
  `null`.

### Task 7: Integrate into `lib/live_view_page.dart`

**Files:** Modify `lib/live_view_page.dart`.

- [ ] Create a `LutLibrary` rooted at `getApplicationDocumentsDirectory()/luts` on init.
- [ ] Replace `_loadLut` (direct `file_picker`) with `_openLutPicker` → sheet → apply chosen
  `StoredLut` via existing `parseCubeLut`/`decodeLutAtlas`/`setState`. None sentinel turns the
  LUT off. After a RED download, auto-apply `pickDefaultRec709`.
- [ ] Keep the ON/OFF toggle, fps/jitter overlay, and shader path unchanged.

### Task 8: Verify

- [ ] `dart format .`, `flutter analyze` (0 issues), `flutter test` (all green), `just check`.
