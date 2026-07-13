import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_panel.dart';
import 'lut/cube_lut.dart';
import 'lut/lut_atlas.dart';
import 'lut/lut_library.dart';
import 'lut/lut_painter.dart';
import 'lut/lut_picker_sheet.dart';
import 'ptp_ip/live_view_stats.dart';
import 'ptp_ip/live_view_stream.dart';
import 'ptp_ip/ptp_ip_client.dart';

/// Live-view resolution, shown as pixel dimensions. Maps to the camera's
/// `LiveViewImageSize` (0xD1AC): 1=QVGA, 2=VGA, 3=XGA.
enum LiveResolution {
  qvga('320 × 240', 1),
  vga('640 × 480', 2),
  xga('1024 × 768', 3);

  const LiveResolution(this.label, this.value);

  /// Menu label (pixel dimensions).
  final String label;

  /// LiveViewImageSize on-wire value.
  final int value;
}

/// Live-view image quality. Maps to the quality-biased levels of the camera's
/// `LiveViewImageCompression` (0xD1BC): Low=Basic, Medium=Normal, High=Fine.
enum LiveQuality {
  low('Low', 1),
  medium('Medium', 3),
  high('High', 5);

  const LiveQuality(this.label, this.value);

  /// Menu label.
  final String label;

  /// LiveViewImageCompression on-wire value.
  final int value;
}

/// Full-screen live-view stream rendered from a [LiveViewStream] via vsync-paced
/// [RawImage], with an fps + jitter readout, an overlay back button, and an
/// optional runtime-loaded 3D LUT applied on the GPU.
class LiveViewPage extends StatefulWidget {
  const LiveViewPage({required this.client, super.key});

  /// An already-paired, open session to stream from.
  final PtpIpClient client;

  @override
  State<LiveViewPage> createState() => _LiveViewPageState();
}

class _LiveViewPageState extends State<LiveViewPage> {
  late final LiveViewStream _stream;
  LutLibrary? _library;
  ui.FragmentShader? _lutShader;
  ui.Image? _lutAtlas;
  double _lutSize = 0;
  bool _lutOn = false;
  bool _showInfo = false;
  String? _lutName;
  String? _currentFileName;
  LiveResolution _resolution = LiveResolution.vga;
  LiveQuality _quality = LiveQuality.medium;

  @override
  void initState() {
    super.initState();
    _stream = LiveViewStream(widget.client);
    _stream.disconnected.addListener(_handleDisconnect);
    unawaited(
      _stream.start(size: _resolution.value, compression: _quality.value),
    );
    unawaited(_loadShader());
    unawaited(_initLibrary());
  }

  void _handleDisconnect() {
    if (!_stream.disconnected.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_stream.error.value ?? 'Camera disconnected')),
      );
      Navigator.of(context).maybePop();
    });
  }

  Future<void> _initLibrary() async {
    final docs = await getApplicationDocumentsDirectory();
    final library = LutLibrary(Directory('${docs.path}/luts'));
    if (mounted) setState(() => _library = library);
  }

  void _setResolution(LiveResolution resolution) {
    if (resolution == _resolution) return;
    setState(() => _resolution = resolution);
    _stream.setQuality(size: resolution.value, compression: _quality.value);
  }

  void _setQuality(LiveQuality quality) {
    if (quality == _quality) return;
    setState(() => _quality = quality);
    _stream.setQuality(size: _resolution.value, compression: quality.value);
  }

  Widget _overlayDropdown<T>({
    required T value,
    required List<T> values,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            dropdownColor: Colors.black87,
            iconEnabledColor: Colors.white,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            items: [
              for (final v in values)
                DropdownMenuItem<T>(value: v, child: Text(label(v))),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/lut3d.frag');
      if (mounted) setState(() => _lutShader = program.fragmentShader());
    } on Object {
      // LUT just stays unavailable; live view is unaffected.
    }
  }

  Future<void> _openLutPicker() async {
    final library = _library;
    if (library == null) return;
    final result = await showLutPickerSheet(
      context,
      library,
      currentFileName: _currentFileName,
    );
    if (!mounted || result == null) return;
    switch (result) {
      case LutCleared():
        setState(() => _lutOn = false);
      case LutSelected(:final lut):
        await _applyStoredLut(lut);
    }
  }

  Future<void> _applyStoredLut(StoredLut lut) async {
    try {
      final parsed = parseCubeLut(await File(lut.path).readAsString());
      final atlas = await decodeLutAtlas(parsed);
      if (!mounted) {
        atlas.dispose();
        return;
      }
      setState(() {
        _lutAtlas?.dispose();
        _lutAtlas = atlas;
        _lutSize = parsed.size.toDouble();
        _lutOn = true;
        _lutName = lut.displayName;
        _currentFileName = lut.fileName;
      });
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LUT load failed: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _stream.disconnected.removeListener(_handleDisconnect);
    unawaited(_stream.stop());
    _lutAtlas?.dispose();
    _lutShader?.dispose();
    super.dispose();
  }

  Widget _frameView(ui.Image image) {
    final useLut = _lutOn && _lutShader != null && _lutAtlas != null;
    if (!useLut) {
      return RawImage(image: image, fit: BoxFit.contain);
    }
    return Center(
      child: AspectRatio(
        aspectRatio: image.width / image.height,
        child: CustomPaint(
          painter: LutPainter(
            image: image,
            shader: _lutShader!,
            atlas: _lutAtlas!,
            lutSize: _lutSize,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: ValueListenableBuilder<ui.Image?>(
                valueListenable: _stream.frame,
                builder: (context, image, _) {
                  if (image != null) {
                    return RepaintBoundary(child: _frameView(image));
                  }
                  return ValueListenableBuilder<String?>(
                    valueListenable: _stream.error,
                    builder: (context, err, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        err ?? 'Starting live view…',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Material(
                      color: Colors.black38,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: Icon(
                            _showInfo ? Icons.info : Icons.info_outline,
                            color: Colors.white,
                          ),
                          tooltip: 'Camera info',
                          onPressed: () =>
                              setState(() => _showInfo = !_showInfo),
                        ),
                        _overlayDropdown<LiveResolution>(
                          value: _resolution,
                          values: LiveResolution.values,
                          label: (r) => r.label,
                          onChanged: _setResolution,
                        ),
                        const SizedBox(height: 4),
                        _overlayDropdown<LiveQuality>(
                          value: _quality,
                          values: LiveQuality.values,
                          label: (q) => q.label,
                          onChanged: _setQuality,
                        ),
                        const SizedBox(height: 4),
                        FilledButton.tonalIcon(
                          onPressed: (_lutShader == null || _library == null)
                              ? null
                              : _openLutPicker,
                          icon: const Icon(Icons.photo_filter, size: 18),
                          label: const Text('LUT'),
                        ),
                        if (_lutAtlas != null)
                          TextButton(
                            onPressed: () => setState(() => _lutOn = !_lutOn),
                            child: Text(
                              'LUT ${_lutOn ? 'ON' : 'OFF'}'
                              '${_lutName != null ? ' · $_lutName' : ''}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ValueListenableBuilder<LiveViewStats>(
                      valueListenable: _stream.stats,
                      builder: (context, s, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            '${s.fps} fps · ${s.jitterMs.toStringAsFixed(1)} ms',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_showInfo)
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: CameraPanel(stream: _stream),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
