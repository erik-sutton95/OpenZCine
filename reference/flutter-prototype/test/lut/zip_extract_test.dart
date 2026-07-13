import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/lut/zip_extract.dart';

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  group('extractCubeEntries', () {
    test('returns only .cube files, ignoring other files and __MACOSX', () {
      final zip = _zip(<String, List<int>>{
        'REC709/a.cube': <int>[1, 2, 3],
        'REC2020/b.CUBE': <int>[4, 5],
        'readme.txt': <int>[9, 9, 9],
        '__MACOSX/._a.cube': <int>[0, 0],
      });

      final entries = extractCubeEntries(zip);
      final byPath = <String, Uint8List>{
        for (final e in entries) e.path: e.bytes,
      };

      expect(byPath.keys.toSet(), <String>{'REC709/a.cube', 'REC2020/b.CUBE'});
      expect(byPath['REC709/a.cube'], <int>[1, 2, 3]);
      expect(byPath['REC2020/b.CUBE'], <int>[4, 5]);
    });

    test('matches .cube case-insensitively', () {
      final zip = _zip(<String, List<int>>{
        'Foo.Cube': <int>[7],
      });
      expect(extractCubeEntries(zip).single.path, 'Foo.Cube');
    });

    test('throws FormatException when the archive has no .cube files', () {
      final zip = _zip(<String, List<int>>{
        'notes.txt': <int>[1],
      });
      expect(() => extractCubeEntries(zip), throwsFormatException);
    });
  });
}
