import 'dart:io';
import 'dart:typed_data';

import 'zip_extract.dart';

/// Separator embedded in stored filenames between the category and base name,
/// e.g. `REC709__Foo.cube`. Categories are single zip folder names, so this is
/// unambiguous on the first occurrence.
const String _categorySep = '__';

/// A `.cube` LUT persisted in the app's private LUT store.
class StoredLut {
  const StoredLut({
    required this.fileName,
    required this.displayName,
    required this.category,
    required this.path,
  });

  /// On-disk filename, e.g. `REC709__Foo.cube`.
  final String fileName;

  /// Human-readable label (base name without the `.cube` extension).
  final String displayName;

  /// Source category — the cube's zip folder, or `Imported` for file imports.
  final String category;

  /// Absolute path to the stored `.cube` file.
  final String path;
}

/// File-backed store of downloaded/imported `.cube` LUTs under [root].
///
/// [root] is injected so tests can point at a temporary directory; production
/// passes `<app documents>/luts`. The directory is created on demand.
class LutLibrary {
  LutLibrary(this.root);

  /// Directory that holds the stored `.cube` files.
  final Directory root;

  /// Lists stored cubes sorted by filename. Returns empty if the store is absent.
  Future<List<StoredLut>> list() async {
    if (!root.existsSync()) return <StoredLut>[];
    final luts = root
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.cube'))
        .map((f) => _fromStoredPath(f.path))
        .toList()
      ..sort(
        (a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()),
      );
    return luts;
  }

  /// Extracts every `.cube` from [zipBytes] and writes it into the store,
  /// overwriting same-named files. Returns the stored cubes (sorted).
  Future<List<StoredLut>> importZipBytes(Uint8List zipBytes) async {
    final entries = extractCubeEntries(zipBytes);
    await root.create(recursive: true);
    final stored = <StoredLut>[];
    for (final entry in entries) {
      final fileName = _storedNameForZipPath(entry.path);
      final dest = File('${root.path}/$fileName');
      await dest.writeAsBytes(entry.bytes, flush: true);
      stored.add(_fromStoredPath(dest.path));
    }
    stored.sort(
      (a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()),
    );
    return stored;
  }

  /// Copies an external `.cube` file into the store under the `Imported`
  /// category. Returns the stored cube.
  Future<StoredLut> importCubeFile(String sourcePath) async {
    await root.create(recursive: true);
    final fileName = 'Imported$_categorySep${_baseName(sourcePath)}';
    final dest = File('${root.path}/$fileName');
    await File(sourcePath).copy(dest.path);
    return _fromStoredPath(dest.path);
  }

  /// Removes a stored cube (no-op if already gone).
  Future<void> delete(StoredLut lut) async {
    final file = File(lut.path);
    if (file.existsSync()) await file.delete();
  }
}

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

String _storedNameForZipPath(String zipPath) {
  final segments = zipPath.split('/').where((s) => s.isNotEmpty).toList();
  final base = segments.last;
  final category =
      segments.length >= 2 ? segments[segments.length - 2] : 'Uncategorized';
  return '$category$_categorySep$base';
}

StoredLut _fromStoredPath(String filePath) {
  final fileName = _baseName(filePath);
  final sep = fileName.indexOf(_categorySep);
  final category = sep >= 0 ? fileName.substring(0, sep) : 'Imported';
  final base =
      sep >= 0 ? fileName.substring(sep + _categorySep.length) : fileName;
  final displayName = base.toLowerCase().endsWith('.cube')
      ? base.substring(0, base.length - '.cube'.length)
      : base;
  return StoredLut(
    fileName: fileName,
    displayName: displayName,
    category: category,
    path: filePath,
  );
}

/// Selects the cube to auto-apply after a RED download: a REC709
/// medium-contrast cube (preferring the `R_3`/`Soft` rolloff), falling back to
/// any REC709 cube, or `null` if none is present.
StoredLut? pickDefaultRec709(List<StoredLut> luts) {
  bool has(StoredLut lut, String needle) =>
      lut.fileName.toUpperCase().contains(needle);

  final rec709 = luts.where((l) => has(l, 'REC709')).toList();
  if (rec709.isEmpty) return null;

  final medium = rec709
      .where((l) => has(l, 'MEDIUM_CONTRAST') || has(l, 'MEDIUM CONTRAST'))
      .toList();
  if (medium.isEmpty) return rec709.first;

  for (final lut in medium) {
    if (has(lut, 'R_3') || has(lut, 'SOFT')) return lut;
  }
  return medium.first;
}
