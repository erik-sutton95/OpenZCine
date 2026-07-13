import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/main.dart';
import 'package:zcinecontroller/ptp_ip/device_info.dart';
import 'package:zcinecontroller/ptp_ip/paired_camera_store.dart';
import 'package:zcinecontroller/ptp_ip/pairing_challenge.dart';
import 'package:zcinecontroller/ptp_ip/ptp_ip_client.dart';

void main() {
  testWidgets('renders the IP field and Pair button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(pairedCameraStore: MemoryPairedCameraStore()),
      ),
    );
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('shows pairing challenge before completing connection',
      (tester) async {
    final client = _ChallengeClient();
    final store = MemoryPairedCameraStore();
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          clientFactory: (_) => client,
          pairedCameraStore: store,
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('ZR_6001234'), findsOneWidget);
    expect(find.text('6794'), findsOneWidget);
    expect(find.text('Raw: 67 94'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reject'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
    expect(client.accepted, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();

    expect(client.accepted, true);
    expect(client.requestPairingValues, [true]);
    expect(await store.isPaired('192.168.1.1'), true);
    expect(find.textContaining('Connected'), findsOneWidget);
  });

  testWidgets('uses saved profile on reconnect without pairing challenge',
      (tester) async {
    final client = _ChallengeClient();
    final store = MemoryPairedCameraStore();
    await store.markPaired('192.168.1.1');
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          clientFactory: (_) => client,
          pairedCameraStore: store,
        ),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(client.requestPairingValues, [false]);
    expect(client.accepted, isNull);
    expect(find.text('ZR_6001234'), findsNothing);
    expect(find.textContaining('Connected'), findsOneWidget);
  });

  testWidgets('forgets stale local pairing so the camera can be paired again',
      (tester) async {
    final client = _ChallengeClient();
    final store = MemoryPairedCameraStore();
    await store.markPaired('192.168.1.1');
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          clientFactory: (_) => client,
          pairedCameraStore: store,
        ),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Forget pairing'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Forget pairing'));
    await tester.pumpAndSettle();

    expect(await store.isPaired('192.168.1.1'), false);
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();

    expect(client.requestPairingValues, [true]);
    expect(await store.isPaired('192.168.1.1'), true);
    expect(find.textContaining('Connected'), findsOneWidget);
  });

  testWidgets('remembers accepted pairing if connection closes before identity',
      (tester) async {
    final client = _DropsAfterAcceptClient();
    final store = MemoryPairedCameraStore();
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          clientFactory: (_) => client,
          pairedCameraStore: store,
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();

    expect(client.requestPairingValues, [true]);
    expect(await store.isPaired('192.168.1.1'), true);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.textContaining('Failed:'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(client.requestPairingValues, [true, false]);
    expect(find.text('ZR_6001234'), findsNothing);
    expect(find.textContaining('Connected'), findsOneWidget);
  });
}

class _ChallengeClient extends PtpIpClient {
  _ChallengeClient()
      : super(host: 'fake', guid: Uint8List.fromList(List<int>.filled(16, 0)));

  bool? accepted;
  final List<bool> requestPairingValues = [];

  @override
  Future<DeviceInfo> pairAndIdentify({
    PairingChallengeHandler? onPairingChallenge,
    bool requestPairing = true,
  }) async {
    requestPairingValues.add(requestPairing);
    if (requestPairing) {
      accepted = await onPairingChallenge?.call(
        PairingChallenge.parse(
          Uint8List.fromList(<int>[0x67, 0x94]),
          cameraName: 'ZR_6001234',
        ),
      );
      if (accepted != true) {
        throw Exception('pairing rejected');
      }
    }
    return const DeviceInfo(
      manufacturer: 'Nikon',
      model: 'ZR',
      deviceVersion: '1.00',
      serialNumber: '6001234',
    );
  }

  @override
  Future<void> close() async {}
}

class _DropsAfterAcceptClient extends PtpIpClient {
  _DropsAfterAcceptClient()
      : super(host: 'fake', guid: Uint8List.fromList(List<int>.filled(16, 0)));

  final List<bool> requestPairingValues = [];

  @override
  Future<DeviceInfo> pairAndIdentify({
    PairingChallengeHandler? onPairingChallenge,
    bool requestPairing = true,
  }) async {
    requestPairingValues.add(requestPairing);
    if (requestPairing) {
      final accepted = await onPairingChallenge?.call(
        PairingChallenge.parse(
          Uint8List.fromList(<int>[0x67, 0x94]),
          cameraName: 'ZR_6001234',
        ),
      );
      if (accepted == true) {
        throw Exception('connection closed after pairing');
      }
      throw Exception('pairing rejected');
    }
    return const DeviceInfo(
      manufacturer: 'Nikon',
      model: 'ZR',
      deviceVersion: '1.00',
      serialNumber: '6001234',
    );
  }

  @override
  Future<void> close() async {}
}
