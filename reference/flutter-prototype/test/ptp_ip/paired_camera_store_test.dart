import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/paired_camera_store.dart';

void main() {
  test('memory store remembers and forgets normalized hosts', () async {
    final store = MemoryPairedCameraStore();

    await store.markPaired(' 192.168.1.1 ');

    expect(await store.isPaired('192.168.1.1'), true);
    await store.forget('192.168.1.1');
    expect(await store.isPaired('192.168.1.1'), false);
  });

  test('file store persists paired hosts across instances', () async {
    final dir = await Directory.systemTemp.createTemp(
      'zcine_paired_store_test_',
    );
    try {
      final first = FilePairedCameraStore(directoryProvider: () async => dir);
      await first.markPaired('192.168.1.1');

      final second = FilePairedCameraStore(directoryProvider: () async => dir);
      expect(await second.isPaired('192.168.1.1'), true);

      await second.forget('192.168.1.1');
      expect(await first.isPaired('192.168.1.1'), false);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
