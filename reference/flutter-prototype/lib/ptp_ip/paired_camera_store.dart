import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remembers camera addresses for which this app's stable GUID has already
/// been accepted on the camera.
abstract class PairedCameraStore {
  Future<bool> isPaired(String host);

  Future<void> markPaired(String host);

  Future<void> forget(String host);
}

class MemoryPairedCameraStore implements PairedCameraStore {
  MemoryPairedCameraStore([Iterable<String> hosts = const []])
      : _hosts =
            hosts.map(_normalizeHost).where((host) => host.isNotEmpty).toSet();

  final Set<String> _hosts;

  @override
  Future<bool> isPaired(String host) async =>
      _hosts.contains(_normalizeHost(host));

  @override
  Future<void> markPaired(String host) async {
    final normalized = _normalizeHost(host);
    if (normalized.isNotEmpty) _hosts.add(normalized);
  }

  @override
  Future<void> forget(String host) async {
    _hosts.remove(_normalizeHost(host));
  }
}

class FilePairedCameraStore implements PairedCameraStore {
  FilePairedCameraStore({
    required this.directoryProvider,
    this.fileName = 'paired-cameras.json',
  });

  final Future<Directory> Function() directoryProvider;
  final String fileName;

  @override
  Future<bool> isPaired(String host) async {
    final hosts = await _readHosts();
    return hosts.contains(_normalizeHost(host));
  }

  @override
  Future<void> markPaired(String host) async {
    final normalized = _normalizeHost(host);
    if (normalized.isEmpty) return;
    final hosts = await _readHosts();
    hosts.add(normalized);
    await _writeHosts(hosts);
  }

  @override
  Future<void> forget(String host) async {
    final hosts = await _readHosts();
    hosts.remove(_normalizeHost(host));
    await _writeHosts(hosts);
  }

  Future<File> _file() async {
    final dir = await directoryProvider();
    await dir.create(recursive: true);
    return File('${dir.path}/$fileName');
  }

  Future<Set<String>> _readHosts() async {
    final file = await _file();
    if (!await file.exists()) return <String>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      final values = switch (decoded) {
        {'hosts': final List<dynamic> hosts} => hosts,
        final List<dynamic> hosts => hosts,
        _ => const <dynamic>[],
      };
      return values
          .whereType<String>()
          .map(_normalizeHost)
          .where((host) => host.isNotEmpty)
          .toSet();
    } on Object {
      return <String>{};
    }
  }

  Future<void> _writeHosts(Set<String> hosts) async {
    final file = await _file();
    final sorted = hosts.toList()..sort();
    await file.writeAsString(jsonEncode({'hosts': sorted}));
  }
}

PairedCameraStore createDefaultPairedCameraStore() => FilePairedCameraStore(
      directoryProvider: getApplicationSupportDirectory,
    );

String _normalizeHost(String host) => host.trim().toLowerCase();
