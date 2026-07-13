import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/camera_discovery.dart';

void main() {
  test('subnetBase keeps the first three octets', () {
    expect(subnetBase('172.20.10.5'), '172.20.10');
    expect(subnetBase('192.168.1.1'), '192.168.1');
  });

  test('hostsInSubnet enumerates .1 through .254', () {
    final hosts = hostsInSubnet('192.168.1');
    expect(hosts.length, 254);
    expect(hosts.first, '192.168.1.1');
    expect(hosts.last, '192.168.1.254');
  });

  test('ipToInt orders addresses numerically, not lexically', () {
    expect(ipToInt('192.168.1.2') < ipToInt('192.168.1.10'), isTrue);
  });

  test('isPrivateIpv4 accepts RFC-1918 ranges and rejects others', () {
    expect(isPrivateIpv4('10.0.0.5'), isTrue);
    expect(isPrivateIpv4('172.20.10.3'), isTrue); // iPhone hotspot range
    expect(isPrivateIpv4('192.168.1.1'), isTrue);
    expect(isPrivateIpv4('169.254.1.1'), isFalse); // link-local
    expect(isPrivateIpv4('8.8.8.8'), isFalse); // public
    expect(isPrivateIpv4('172.32.0.1'), isFalse); // just outside 172.16/12
  });

  test('parseInitAckName reads the UTF-16LE name after connNum+GUID', () {
    final payload = Uint8List.fromList(<int>[
      ...List<int>.filled(20, 0), // ConnectionNumber(4) + GUID(16)
      0x5a, 0x00, 0x52, 0x00, // "ZR"
      0x00, 0x00, // NUL terminator
    ]);
    expect(parseInitAckName(payload), 'ZR');
  });

  test('parseInitAckName returns null when there is no name', () {
    expect(parseInitAckName(Uint8List(20)), isNull);
  });

  test('scan checks preferred hosts before sweeping the subnet', () async {
    final probed = <String>[];

    final found = await scanForCameras(
      preferredHosts: const ['172.20.10.42'],
      returnAfterPreferredHit: true,
      interfaceAddresses: [InternetAddress('172.20.10.5')],
      portProbe: (ip, port, timeout) async {
        probed.add(ip);
        return ip == '172.20.10.42';
      },
      nameProbe: (ip, port, timeout) async =>
          ip == '172.20.10.42' ? 'ZR_42' : null,
    );

    expect(found, hasLength(1));
    expect(found.single.ip, '172.20.10.42');
    expect(found.single.name, 'ZR_42');
    expect(probed, ['172.20.10.42']);
  });

  test('scan returns Bonjour PTP cameras before subnet probing', () async {
    final probed = <String>[];

    final found = await scanForCameras(
      bonjourProbe: (timeout) async => const [
        DiscoveredCamera(ip: '172.20.10.8', name: 'ZR_6001234'),
      ],
      preferredHosts: const ['172.20.10.42'],
      returnAfterPreferredHit: true,
      interfaceAddresses: [InternetAddress('172.20.10.5')],
      portProbe: (ip, port, timeout) async {
        probed.add(ip);
        return true;
      },
      nameProbe: (ip, port, timeout) async => 'unexpected',
    );

    expect(found, hasLength(1));
    expect(found.single.ip, '172.20.10.8');
    expect(found.single.name, 'ZR_6001234');
    expect(probed, isEmpty);
  });

  test('scan retries a flaky preferred host probe', () async {
    var attempts = 0;

    final found = await scanForCameras(
      preferredHosts: const ['172.20.10.42'],
      returnAfterPreferredHit: true,
      portOpenAttempts: 2,
      interfaceAddresses: [InternetAddress('172.20.10.5')],
      portProbe: (ip, port, timeout) async {
        attempts++;
        return attempts == 2;
      },
      nameProbe: (ip, port, timeout) async => 'ZR_42',
    );

    expect(found.single.ip, '172.20.10.42');
    expect(attempts, 2);
  });

  test('scan skips 10.x interfaces by default', () async {
    final probed = <String>[];

    final found = await scanForCameras(
      interfaceAddresses: [InternetAddress('10.0.0.5')],
      portProbe: (ip, port, timeout) async {
        probed.add(ip);
        return true;
      },
      nameProbe: (ip, port, timeout) async => 'ZR',
    );

    expect(found, isEmpty);
    expect(probed, isEmpty);
  });

  test('scan skips 10.x preferred hosts by default', () async {
    final probed = <String>[];

    final found = await scanForCameras(
      preferredHosts: const ['10.0.0.42'],
      returnAfterPreferredHit: true,
      interfaceAddresses: [InternetAddress('172.20.10.5')],
      portProbe: (ip, port, timeout) async {
        probed.add(ip);
        return ip == '10.0.0.42';
      },
      nameProbe: (ip, port, timeout) async => 'ZR',
    );

    expect(found, isEmpty);
    expect(probed, isNot(contains('10.0.0.42')));
  });

  test('scan tries likely hotspot addresses before the rest of the subnet',
      () async {
    final probed = <String>[];

    final found = await scanForCameras(
      portOpenAttempts: 1,
      interfaceAddresses: [InternetAddress('192.168.7.99')],
      portProbe: (ip, port, timeout) async {
        probed.add(ip);
        return ip == '192.168.7.2';
      },
      nameProbe: (ip, port, timeout) async => 'ZR_2',
    );

    expect(found.single.ip, '192.168.7.2');
    expect(probed, contains('192.168.7.1'));
    expect(probed, contains('192.168.7.2'));
    expect(probed, isNot(contains('192.168.7.33')));
  });

  test('scan bursts likely hosts without waiting on a slow earlier address',
      () async {
    final probed = <String>[];

    final found = await scanForCameras(
      portOpenAttempts: 1,
      interfaceAddresses: [InternetAddress('192.168.7.99')],
      portProbe: (ip, port, timeout) async {
        probed.add(ip);
        if (ip == '192.168.7.1') {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return false;
        }
        return ip == '192.168.7.2';
      },
      nameProbe: (ip, port, timeout) async => 'ZR_2',
    ).timeout(const Duration(milliseconds: 150));

    expect(found.single.ip, '192.168.7.2');
    expect(probed, contains('192.168.7.1'));
    expect(probed, contains('192.168.7.2'));
  });
}
