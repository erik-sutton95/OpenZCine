import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import 'camera_discovery.dart';

const String ptpBonjourServiceType = '_ptp._tcp';

Future<List<DiscoveredCamera>> discoverBonjourCameras(Duration timeout) async {
  final discovery = BonsoirDiscovery(type: ptpBonjourServiceType);
  final foundByIp = <String, DiscoveredCamera>{};
  StreamSubscription<BonsoirDiscoveryEvent>? subscription;

  try {
    await discovery.initialize();
    subscription = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          event.service.resolve(discovery.serviceResolver);
        case BonsoirDiscoveryServiceResolvedEvent():
          final service = event.service;
          for (final address in service.hostAddresses) {
            if (isPrivateIpv4(address)) {
              foundByIp[address] = DiscoveredCamera(
                ip: address,
                name: service.name,
              );
            }
          }
        default:
          break;
      }
    });
    await discovery.start();
    await Future<void>.delayed(timeout);
  } on Object {
    // Bonjour is a fast-path; socket scanning remains the fallback.
  } finally {
    await subscription?.cancel();
    try {
      await discovery.stop();
    } on Object {
      // Already stopped or never started.
    }
  }

  return foundByIp.values.toList()
    ..sort((a, b) => ipToInt(a.ip).compareTo(ipToInt(b.ip)));
}
