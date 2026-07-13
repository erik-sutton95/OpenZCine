import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/lut/lut_library.dart';

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory tmp;
  late LutLibrary library;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lut_lib_test');
    library = LutLibrary(Directory('${tmp.path}/luts'));
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('importZipBytes writes one file per cube and derives metadata',
      () async {
    final zip = _zip(<String, List<int>>{
      'REC709/Look A.cube': <int>[1, 2, 3],
      'REC2020/Look B.cube': <int>[4],
      'readme.txt': <int>[9],
    });

    final stored = await library.importZipBytes(zip);

    expect(stored.length, 2);
    expect(File('${library.root.path}/REC709__Look A.cube').existsSync(), true);
    expect(
      File('${library.root.path}/REC2020__Look B.cube').existsSync(),
      true,
    );

    final a = stored.firstWhere((l) => l.category == 'REC709');
    expect(a.displayName, 'Look A');
    expect(a.fileName, 'REC709__Look A.cube');
  });

  test('list returns stored cubes sorted by file name', () async {
    await library.importZipBytes(
      _zip(<String, List<int>>{
        'REC2020/Z.cube': <int>[1],
        'REC709/A.cube': <int>[1],
      }),
    );

    final luts = await library.list();
    expect(luts.map((l) => l.fileName).toList(), <String>[
      'REC2020__Z.cube',
      'REC709__A.cube',
    ]);
  });

  test('list returns empty when the store does not exist', () async {
    expect(await library.list(), isEmpty);
  });

  test('importCubeFile copies an external cube in as Imported', () async {
    final src = File('${tmp.path}/MyLook.cube')..writeAsStringSync('TITLE "x"');

    final lut = await library.importCubeFile(src.path);

    expect(lut.category, 'Imported');
    expect(lut.fileName, 'Imported__MyLook.cube');
    expect(lut.displayName, 'MyLook');
    expect(File(lut.path).readAsStringSync(), 'TITLE "x"');
  });

  test('delete removes a stored cube', () async {
    final stored = await library.importZipBytes(
      _zip(<String, List<int>>{
        'REC709/A.cube': <int>[1],
      }),
    );
    await library.delete(stored.single);

    expect(File(stored.single.path).existsSync(), false);
    expect(await library.list(), isEmpty);
  });

  group('pickDefaultRec709', () {
    StoredLut lut(String fileName) => StoredLut(
          fileName: fileName,
          displayName: fileName,
          category: fileName.split('__').first,
          path: '/tmp/$fileName',
        );

    test('prefers REC709 + MEDIUM_CONTRAST + R_3/Soft', () {
      final luts = <StoredLut>[
        lut('REC2020__RWG to REC2020 size_33.cube'),
        lut('REC709__RWG_Log3G10 to REC709_BT1886 with HIGH_CONTRAST.cube'),
        lut('REC709__RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and '
            'R_3_Soft size_33 v1.13.cube'),
      ];
      expect(pickDefaultRec709(luts), luts[2]);
    });

    test('falls back to first REC709 when no MEDIUM_CONTRAST', () {
      final luts = <StoredLut>[
        lut('REC2020__A.cube'),
        lut('REC709__HIGH_CONTRAST.cube'),
      ];
      expect(pickDefaultRec709(luts), luts[1]);
    });

    test('returns null when no REC709 cube exists', () {
      expect(pickDefaultRec709(<StoredLut>[lut('REC2020__A.cube')]), isNull);
    });
  });
}
