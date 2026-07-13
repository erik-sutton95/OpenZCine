import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/socket_reader.dart';

void main() {
  test('readExact reassembles across chunk boundaries', () async {
    final controller = StreamController<Uint8List>();
    final reader = SocketReader(controller.stream);

    final first = reader.readExact(5);
    controller.add(Uint8List.fromList([1, 2]));
    controller.add(Uint8List.fromList([3, 4, 5, 6]));
    expect(await first, [1, 2, 3, 4, 5]);
    expect(await reader.readExact(1), [6]);

    await controller.close();
    await reader.close();
  });

  test('readExact errors if the stream closes before enough bytes', () async {
    final controller = StreamController<Uint8List>();
    final reader = SocketReader(controller.stream);
    final pending = reader.readExact(10);
    controller.add(Uint8List.fromList([1, 2, 3]));
    await controller.close();
    await expectLater(pending, throwsA(isA<Exception>()));
    await reader.close();
  });
}
