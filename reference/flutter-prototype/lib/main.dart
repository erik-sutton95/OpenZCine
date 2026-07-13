import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'live_view_page.dart';
import 'ptp_ip/camera_bonjour_discovery.dart';
import 'ptp_ip/camera_discovery.dart';
import 'ptp_ip/device_info.dart';
import 'ptp_ip/paired_camera_store.dart';
import 'ptp_ip/pairing_challenge.dart';
import 'ptp_ip/pairing_probe.dart';
import 'ptp_ip/ptp_constants.dart';
import 'ptp_ip/ptp_ip_client.dart';

void main() => runApp(const ZCineApp());

typedef PtpIpClientFactory = PtpIpClient Function(String host);

PtpIpClient _defaultClientFactory(String host) =>
    PtpIpClient(host: host, guid: zcineControllerGuid());

class ZCineApp extends StatelessWidget {
  const ZCineApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'OpenZCine',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const PairPage(),
      );
}

class PairPage extends StatefulWidget {
  const PairPage({
    super.key,
    this.clientFactory = _defaultClientFactory,
    this.pairedCameraStore,
  });

  final PtpIpClientFactory clientFactory;
  final PairedCameraStore? pairedCameraStore;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final TextEditingController _ip = TextEditingController(text: '192.168.1.1');
  bool _busy = false;
  String _status = "Join the camera's Wi-Fi (Connect to PC), then tap Pair.";
  DeviceInfo? _camera;
  PtpIpClient? _client; // non-null while a session is held open
  bool _probing = false;
  String? _report; // last read-only pairing-probe report (copyable)
  bool _scanning = false;
  List<DiscoveredCamera> _cameras = const [];
  bool _selectedHostIsPaired = false;
  int _pairedLookupGeneration = 0;
  late final PairedCameraStore _pairedCameraStore =
      widget.pairedCameraStore ?? createDefaultPairedCameraStore();

  @override
  void initState() {
    super.initState();
    _ip.addListener(_refreshSelectedHostPaired);
    unawaited(_refreshSelectedHostPaired());
  }

  Future<void> _refreshSelectedHostPaired() async {
    final generation = ++_pairedLookupGeneration;
    final host = _ip.text.trim();
    final paired = host.isNotEmpty && await _pairedCameraStore.isPaired(host);
    if (!mounted || generation != _pairedLookupGeneration) return;
    setState(() => _selectedHostIsPaired = paired);
  }

  Future<void> _scan() async {
    final preferredHost = _ip.text.trim();
    setState(() {
      _scanning = true;
      _cameras = const [];
      _status = preferredHost.isEmpty
          ? 'Scanning the network for cameras…'
          : 'Checking $preferredHost, then scanning the local network…';
    });
    try {
      final found = await scanForCameras(
        bonjourProbe: discoverBonjourCameras,
        preferredHosts: preferredHost.isEmpty ? const [] : [preferredHost],
        returnAfterPreferredHit: true,
      );
      setState(() {
        _cameras = found;
        _status = found.isEmpty
            ? 'No cameras found. Make sure the phone and camera share a network.'
            : 'Found ${found.length} camera(s) — tap one to select it.';
      });
    } on Exception catch (e) {
      setState(() => _status = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pair() async {
    final host = _ip.text.trim();
    setState(() {
      _busy = true;
      _camera = null;
      _status = 'Preparing connection to $host…';
    });
    PtpIpClient? client;
    try {
      final requestPairing = !await _pairedCameraStore.isPaired(host);
      var pairingAccepted = false;
      if (!mounted) return;
      if (_selectedHostIsPaired != !requestPairing) {
        setState(() => _selectedHostIsPaired = !requestPairing);
      }
      setState(() {
        _status = requestPairing
            ? 'Pairing with $host…'
            : 'Connecting to $host with saved pairing profile…';
      });
      final activeClient = widget.clientFactory(host);
      client = activeClient;
      final info = await activeClient.pairAndIdentify(
        requestPairing: requestPairing,
        onPairingChallenge: (challenge) async {
          final accepted = await _confirmPairingChallenge(challenge);
          pairingAccepted = accepted;
          if (accepted) {
            await _pairedCameraStore.markPaired(host);
            if (mounted) setState(() => _selectedHostIsPaired = true);
          }
          return accepted;
        },
      );
      if (requestPairing && pairingAccepted) {
        await _pairedCameraStore.markPaired(host);
      }
      _client =
          activeClient; // keep the session OPEN so the camera stays connected
      setState(() {
        _camera = info;
        _status = 'Connected ✓ — holding the session. '
            '[${activeClient.establishmentSummary.trim()}] '
            '${requestPairing ? 'Pairing profile saved.' : 'Saved profile used.'}';
      });
    } on Exception catch (e) {
      await client?.close();
      setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmPairingChallenge(PairingChallenge challenge) async {
    if (!mounted) return false;
    setState(() {
      _status = challenge.pin != null
          ? 'Confirm pairing PIN ${challenge.pin} on the camera.'
          : 'Confirm pairing challenge from the camera.';
    });
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pair camera'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              challenge.cameraName ?? 'Nikon camera',
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              "Confirm this PIN matches your camera's screen.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Text(
              challenge.pin ?? challenge.rawHex,
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              'Raw: ${challenge.rawHex}',
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            if (challenge.pin == null) ...[
              const SizedBox(height: 12),
              const Text(
                'PIN could not be decoded yet; raw challenge bytes are shown for hardware validation.',
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  Future<void> _forgetPairing() async {
    final host = _ip.text.trim();
    if (host.isEmpty) return;
    await _pairedCameraStore.forget(host);
    if (!mounted) return;
    setState(() {
      _selectedHostIsPaired = false;
      _status =
          'Forgot saved pairing for $host. Tap Pair to create a new camera profile.';
    });
  }

  Future<void> _disconnect() async {
    await _client?.close();
    _client = null;
    setState(() {
      _camera = null;
      _report = null;
      _status = 'Disconnected.';
    });
  }

  Future<void> _probe() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _probing = true;
      _report = null;
    });
    try {
      final steps = await client.probePairingSurface();
      setState(() => _report = formatProbeReport(steps));
    } on Exception catch (e) {
      setState(() => _report = 'Probe failed: $e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _invoke() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _probing = true;
      _report = null;
    });
    try {
      final steps = await client.probeInvoke();
      setState(() => _report = formatProbeReport(steps));
    } on Exception catch (e) {
      setState(() => _report = 'Invoke failed: $e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Probe report copied to clipboard')),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_client?.close() ?? Future<void>.value());
    _ip.removeListener(_refreshSelectedHostPaired);
    _ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final connected = _client != null;
    return Scaffold(
      appBar: AppBar(title: const Text('OpenZCine — Pair')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ip,
            enabled: !_busy && !connected,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Camera IP (or use Scan)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          if (!connected)
            OutlinedButton.icon(
              onPressed: (_busy || _scanning) ? null : _scan,
              icon: _scanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find),
              label: const Text('Scan for cameras'),
            ),
          if (_cameras.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final cam in _cameras)
                    ListTile(
                      leading: const Icon(Icons.photo_camera_outlined),
                      title: Text(cam.name ?? cam.ip),
                      subtitle: cam.name != null ? Text(cam.ip) : null,
                      onTap: () => setState(() {
                        _ip.text = cam.ip;
                        _cameras = const [];
                        _status = 'Selected ${cam.ip}.';
                      }),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (_busy || connected) ? null : _pair,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: Text(_selectedHostIsPaired ? 'Connect' : 'Pair'),
          ),
          if (!connected && _selectedHostIsPaired) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _forgetPairing,
              icon: const Icon(Icons.link_off),
              label: const Text('Forget pairing'),
            ),
          ],
          if (connected) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => LiveViewPage(client: _client!),
                        ),
                      ),
              icon: const Icon(Icons.videocam),
              label: const Text('Live view'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: (_busy || _probing) ? null : _probe,
              icon: _probing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore),
              label: const Text('Probe pairing surface'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: (_busy || _probing) ? null : _invoke,
              icon: const Icon(Icons.bolt),
              label: const Text('Invoke 0x935a / 0x952b (watch camera)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: (_busy || _probing) ? null : _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect'),
            ),
          ],
          const SizedBox(height: 24),
          Text(_status, style: Theme.of(context).textTheme.bodyLarge),
          if (camera != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Manufacturer: ${camera.manufacturer}'),
                    Text('Model: ${camera.model}'),
                    Text('Version: ${camera.deviceVersion}'),
                    Text('Serial: ${camera.serialNumber}'),
                  ],
                ),
              ),
            ),
          ],
          if (_report != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Probe report',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _copyReport,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: SingleChildScrollView(
                child: SelectableText(
                  _report!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['Menlo', 'Courier New'],
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
