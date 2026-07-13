import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ptp_constants.dart';
import 'ptp_ip_client.dart';
import 'ptp_ip_packet.dart';
import 'socket_reader.dart';

typedef CameraPortProbe = Future<bool> Function(
  String ip,
  int port,
  Duration timeout,
);

typedef CameraNameProbe = Future<String?> Function(
  String ip,
  int port,
  Duration timeout,
);

typedef CameraBonjourProbe = Future<List<DiscoveredCamera>> Function(
  Duration timeout,
);

/// A camera found on the local network by [scanForCameras].
class DiscoveredCamera {
  const DiscoveredCamera({required this.ip, this.name});

  /// The camera's IPv4 address.
  final String ip;

  /// The camera's PTP-IP friendly name (e.g. `ZR_6001234`), or null if it
  /// couldn't be read.
  final String? name;
}

/// The `a.b.c` prefix of a dotted-quad IPv4 address.
String subnetBase(String ipv4) {
  final parts = ipv4.split('.');
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

/// All host addresses `base.1`..`base.254`.
List<String> hostsInSubnet(String base) =>
    [for (var i = 1; i <= 254; i++) '$base.$i'];

/// Likely DHCP/static camera addresses first, then the rest of the /24.
List<String> fastHostsInSubnet(String base) {
  final orderedLastOctets = <int>[
    1,
    for (var i = 2; i <= 32; i++) i,
    for (var i = 33; i <= 254; i++) i,
  ];
  return [for (final host in orderedLastOctets) '$base.$host'];
}

/// Packs a dotted-quad into a comparable 32-bit int.
int ipToInt(String ip) {
  final p = ip.split('.').map(int.parse).toList();
  return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
}

/// Whether [ip] is in an RFC-1918 private range (10/8, 172.16/12, 192.168/16).
/// Used to keep scanning to local networks and never the cellular/public side.
bool isPrivateIpv4(String ip) {
  final p = ip.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]), b = int.tryParse(p[1]);
  if (a == null || b == null) return false;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

bool isDefaultScanIpv4(String ip) {
  final p = ip.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]), b = int.tryParse(p[1]);
  if (a == null || b == null) return false;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

/// Extracts the friendly name from an `Init_Command_Ack` payload
/// (`ConnectionNumber(4) + GUID(16) + name(UTF-16LE, NUL-terminated)`).
String? parseInitAckName(Uint8List payload) {
  const nameOffset = 20;
  if (payload.length < nameOffset + 2) return null;
  final out = StringBuffer();
  for (var i = nameOffset; i + 1 < payload.length; i += 2) {
    final unit = payload[i] | (payload[i + 1] << 8);
    if (unit == 0) break;
    out.writeCharCode(unit);
  }
  final name = out.toString();
  return name.isEmpty ? null : name;
}

/// Scans every local private IPv4 /24 for hosts with the PTP-IP port open, then
/// reads each one's friendly name (best-effort). Returns the cameras found,
/// sorted by address. Pure-Dart sockets only — no mDNS dependency.
Future<List<DiscoveredCamera>> scanForCameras({
  int port = ptpIpPort,
  Duration perHostTimeout = const Duration(milliseconds: 350),
  Duration preferredHostTimeout = const Duration(milliseconds: 450),
  int concurrency = 64,
  Iterable<String> preferredHosts = const [],
  bool returnAfterPreferredHit = false,
  Duration bonjourTimeout = const Duration(milliseconds: 900),
  int portOpenAttempts = 1,
  bool includeTenDotSubnets = false,
  Iterable<InternetAddress>? interfaceAddresses,
  CameraPortProbe? portProbe,
  CameraNameProbe? nameProbe,
  CameraBonjourProbe? bonjourProbe,
}) async {
  final checkPort = portProbe ?? _portOpen;
  final readName = nameProbe ?? _probeCameraNameForScan;
  if (bonjourProbe != null) {
    final bonjourFound = _dedupeAndSortCameras(
      await bonjourProbe(bonjourTimeout),
      includeTenDotSubnets: includeTenDotSubnets,
    );
    if (bonjourFound.isNotEmpty) return bonjourFound;
  }

  final own = <String>{};
  final bases = <String>{};
  final addresses = interfaceAddresses ?? await _localIpv4Addresses();
  for (final addr in addresses) {
    final address = addr.address;
    final shouldScan = includeTenDotSubnets
        ? isPrivateIpv4(address)
        : isDefaultScanIpv4(address);
    if (!shouldScan) continue; // skip cellular/public/LL/uncommon ranges
    own.add(address);
    bases.add(subnetBase(address));
  }

  final foundByIp = <String, DiscoveredCamera>{};
  Future<bool> tryHost(String ip, Duration timeout) async {
    if (own.contains(ip) || foundByIp.containsKey(ip)) return false;
    final open = await _portOpenWithRetries(
      ip,
      port,
      timeout,
      portOpenAttempts,
      checkPort,
    );
    if (!open) return false;
    final name = await readName(ip, port, timeout);
    foundByIp[ip] = DiscoveredCamera(ip: ip, name: name);
    return true;
  }

  final preferred = preferredHosts
      .map((host) => host.trim())
      .where(includeTenDotSubnets ? isPrivateIpv4 : isDefaultScanIpv4)
      .toSet()
      .toList()
    ..sort((a, b) => ipToInt(a).compareTo(ipToInt(b)));
  for (final host in preferred) {
    final found = await tryHost(host, preferredHostTimeout);
    if (found && returnAfterPreferredHit) {
      return foundByIp.values.toList();
    }
  }

  final candidates = <String>[
    for (final base in bases)
      for (final host in fastHostsInSubnet(base))
        if (!own.contains(host) && !foundByIp.containsKey(host)) host,
  ];

  final likelyCandidates = candidates.take(32).toList();
  final foundLikely = await _scanUntilFirstHit(
    likelyCandidates,
    concurrency: likelyCandidates.length,
    tryHost: (host) => tryHost(host, preferredHostTimeout),
  );
  if (foundLikely) {
    return foundByIp.values.toList()
      ..sort((a, b) => ipToInt(a.ip).compareTo(ipToInt(b.ip)));
  }

  final remainingCandidates = candidates.skip(32).toList();
  await _scanUntilFirstHit(
    remainingCandidates,
    concurrency: concurrency,
    tryHost: (host) => tryHost(host, perHostTimeout),
  );

  return foundByIp.values.toList()
    ..sort((a, b) => ipToInt(a.ip).compareTo(ipToInt(b.ip)));
}

Future<bool> _scanUntilFirstHit(
  List<String> hosts, {
  required int concurrency,
  required Future<bool> Function(String host) tryHost,
}) async {
  if (hosts.isEmpty) return false;

  final done = Completer<bool>();
  final workerCount = concurrency <= 0
      ? 1
      : concurrency > hosts.length
          ? hosts.length
          : concurrency;
  var next = 0;
  var active = 0;
  var stopped = false;

  void launchNext() {
    if (stopped) return;
    if (next >= hosts.length) {
      if (active == 0 && !done.isCompleted) done.complete(false);
      return;
    }

    final host = hosts[next++];
    active++;
    unawaited(() async {
      try {
        final hit = await tryHost(host);
        if (hit && !done.isCompleted) {
          stopped = true;
          done.complete(true);
        }
      } finally {
        active--;
        if (!stopped) launchNext();
        if (!stopped && next >= hosts.length && active == 0) {
          if (!done.isCompleted) done.complete(false);
        }
      }
    }());
  }

  for (var i = 0; i < workerCount; i++) {
    launchNext();
  }

  return done.future;
}

List<DiscoveredCamera> _dedupeAndSortCameras(
  Iterable<DiscoveredCamera> cameras, {
  required bool includeTenDotSubnets,
}) {
  final byIp = <String, DiscoveredCamera>{};
  for (final camera in cameras) {
    final ip = camera.ip.trim();
    final shouldScan =
        includeTenDotSubnets ? isPrivateIpv4(ip) : isDefaultScanIpv4(ip);
    if (!shouldScan) continue;
    byIp.putIfAbsent(ip, () => DiscoveredCamera(ip: ip, name: camera.name));
  }
  return byIp.values.toList()
    ..sort((a, b) => ipToInt(a.ip).compareTo(ipToInt(b.ip)));
}

/// Opens a PTP-IP connection, reads the camera's friendly name from the
/// `Init_Command_Ack`, and closes. Returns null on any failure.
Future<String?> probeCameraName(
  String ip, {
  int port = ptpIpPort,
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, port, timeout: timeout);
    final reader = SocketReader(socket);
    socket.add(
      PtpIpPacket(
        PtpIpType.initCommandRequest,
        buildInitCommandPayload(zcineControllerGuid(), 'WTU-iPhone'),
      ).toBytes(),
    );
    final header = await reader.readExact(8).timeout(timeout);
    final bd = ByteData.sublistView(header);
    final length = bd.getUint32(0, Endian.little);
    final type = bd.getUint32(4, Endian.little);
    final payload = length > 8
        ? await reader.readExact(length - 8).timeout(timeout)
        : Uint8List(0);
    if (type != PtpIpType.initCommandAck) return null;
    return parseInitAckName(payload);
  } on Object catch (_) {
    return null;
  } finally {
    await socket?.close();
  }
}

Future<List<InternetAddress>> _localIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  return [
    for (final iface in interfaces)
      for (final addr in iface.addresses) addr,
  ];
}

Future<String?> _probeCameraNameForScan(
  String ip,
  int port,
  Duration timeout,
) =>
    probeCameraName(ip, port: port, timeout: timeout);

Future<bool> _portOpenWithRetries(
  String ip,
  int port,
  Duration timeout,
  int attempts,
  CameraPortProbe portProbe,
) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (await portProbe(ip, port, timeout)) return true;
  }
  return false;
}

Future<bool> _portOpen(String ip, int port, Duration timeout) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, port, timeout: timeout);
    return true;
  } on Object {
    return false;
  } finally {
    await socket?.close();
  }
}
