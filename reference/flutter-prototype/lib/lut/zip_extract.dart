import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A single `.cube` file pulled from a downloaded archive: its [path] within the
/// zip (folder structure preserved) and raw [bytes].
class CubeEntry {
  const CubeEntry({required this.path, required this.bytes});

  /// The entry's path inside the archive, e.g. `REC709/Foo.cube`.
  final String path;

  /// The file's raw bytes.
  final Uint8List bytes;
}

/// Extracts every `.cube` file from a zip archive, preserving folder paths.
///
/// Skips directories and `__MACOSX/` resource-fork metadata. Matching is
/// case-insensitive on the `.cube` extension. Throws a [FormatException] if the
/// archive contains no `.cube` files.
List<CubeEntry> extractCubeEntries(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final entries = <CubeEntry>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    if (name.contains('__MACOSX/')) continue;
    if (!name.toLowerCase().endsWith('.cube')) continue;
    final content = file.content as List<int>;
    entries.add(CubeEntry(path: name, bytes: Uint8List.fromList(content)));
  }
  if (entries.isEmpty) {
    throw const FormatException('no .cube files in archive');
  }
  return entries;
}
