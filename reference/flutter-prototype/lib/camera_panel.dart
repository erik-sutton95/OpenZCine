import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'ptp_ip/camera_props.dart';
import 'ptp_ip/live_view_stream.dart';
import 'ptp_ip/ptp_constants.dart';

/// A settable camera property: how to encode a chosen raw value, label it, and a
/// fallback option set used when the camera doesn't enumerate supported values.
class _Editable {
  const _Editable({
    required this.title,
    required this.code,
    required this.valueBytes,
    required this.encode,
    required this.label,
    required this.fallback,
  });

  final String title;
  final int code;
  final int valueBytes;
  final Uint8List Function(int raw) encode;
  final String Function(int raw) label;
  final List<int> fallback;
}

// Real ZR MovieRecordScreenSize (0xD0A0) values: 6048×3402 (6K) / 3840×2160 /
// 1920×1080 at 24/25/30/50/60. fps is the nominal rate (the camera applies the
// NTSC fractional variant — 23.976/29.97/59.94 — by region; 0xD0A0 has no flag).
const List<int> _recValues = [
  0x17A00D4A00180000,
  0x17A00D4A00190000,
  0x17A00D4A001E0000,
  0x17A00D4A00320000,
  0x17A00D4A003C0000,
  0x0F00087000180000,
  0x0F00087000190000,
  0x0F000870001E0000,
  0x0F00087000320000,
  0x0F000870003C0000,
  0x0780043800180000,
  0x0780043800190000,
  0x07800438001E0000,
  0x0780043800320000,
  0x07800438003C0000,
];
const List<int> _formatValues = [
  0x00000801,
  0x00010800,
  0x00010A00,
  0x00100A00,
  0x00110C00,
  0x00310C03,
  0x00020C02,
];
const List<int> _isoLow = [
  200,
  250,
  320,
  400,
  500,
  640,
  800,
  1000,
  1250,
  1600,
  2000,
  2500,
  3200,
];
const List<int> _isoHigh = [
  1600,
  2000,
  2500,
  3200,
  4000,
  5000,
  6400,
  8000,
  10000,
  12800,
  16000,
  20000,
  25600,
];
const List<int> _angles = [
  1125,
  2250,
  4500,
  9000,
  14400,
  17280,
  18000,
  27000,
  36000,
];
const List<int> _apertures = [140, 200, 280, 400, 560, 800, 1100, 1600, 2200];
const List<int> _kelvins = [
  2500,
  3200,
  4000,
  4500,
  5000,
  5600,
  6500,
  7500,
  10000,
];
const List<int> _wbModes = [
  0x0002,
  0x0004,
  0x0005,
  0x0006,
  0x0007,
  0x8010,
  0x8011,
  0x8012,
  0x8013,
  0x8016,
];

/// Collapsible overlay showing the camera's live settings; settable rows open an
/// editor that writes back through the live-view loop's safe-point command queue.
/// A write the camera rejects (e.g. a setting locked on the body, or wrong mode)
/// marks that row locked rather than retrying.
class CameraPanel extends StatefulWidget {
  const CameraPanel({required this.stream, super.key});

  final LiveViewStream stream;

  @override
  State<CameraPanel> createState() => _CameraPanelState();
}

class _CameraPanelState extends State<CameraPanel> {
  String? _note; // last rejected-write message
  final Set<int> _locked = {}; // property codes the camera refused to set

  static const _baseIso = _Editable(
    title: 'Base ISO',
    code: PtpProp.movieBaseIso,
    valueBytes: 1,
    encode: encodeUint8,
    label: decodeBaseIso,
    fallback: [1, 2],
  );
  static const _aperture = _Editable(
    title: 'Aperture',
    code: PtpProp.movieFnumber,
    valueBytes: 2,
    encode: encodeUint16,
    label: decodeFnumber,
    fallback: _apertures,
  );
  static const _shutter = _Editable(
    title: 'Shutter',
    code: PtpProp.movieShutterAngle,
    valueBytes: 4,
    encode: encodeUint32,
    label: decodeShutterAngle,
    fallback: _angles,
  );
  static const _wbMode = _Editable(
    title: 'WB',
    code: PtpProp.movieWhiteBalance,
    valueBytes: 2,
    encode: encodeUint16,
    label: decodeWbMode,
    fallback: _wbModes,
  );
  static const _kelvin = _Editable(
    title: 'Temp',
    code: PtpProp.movieWbColorTemp,
    valueBytes: 2,
    encode: encodeUint16,
    label: _kelvinLabel,
    fallback: _kelvins,
  );
  static const _format = _Editable(
    title: 'Format',
    code: PtpProp.movieFileType,
    valueBytes: 4,
    encode: encodeUint32,
    label: decodeFileType,
    fallback: _formatValues,
  );
  static const _Editable _rec = _Editable(
    title: 'Rec',
    code: PtpProp.movieRecordScreenSize,
    valueBytes: 8,
    encode: encodeUint64,
    label: _recLabel,
    fallback: _recValues,
  );

  static String _kelvinLabel(int r) => '${r}K';
  static String _recLabel(int r) {
    final s = decodeScreenSize(r);
    return '${s.label} · ${s.fps}p';
  }

  Future<void> _openEditor(_Editable e, String? currentLabel) async {
    final raw =
        await widget.stream.describeEnum(e.code, valueBytes: e.valueBytes);
    final values = raw.isNotEmpty ? raw : e.fallback;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                e.title,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final v in values)
              ListTile(
                title: Text(e.label(v)),
                trailing:
                    e.label(v) == currentLabel ? const Icon(Icons.check) : null,
                onTap: () {
                  widget.stream.setCameraProperty(
                    e.code,
                    e.encode(v),
                    onError: (m) {
                      if (mounted) {
                        setState(() {
                          _locked.add(e.code);
                          _note = '${e.title}: locked / not settable now';
                        });
                      }
                    },
                  );
                  if (mounted) setState(() => _note = null);
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  // The ISO option set follows the active base (Low 200–3200 / High 1600–25600).
  _Editable _isoEditable(CameraState s) => _Editable(
        title: 'ISO',
        code: PtpProp.movieIsoSensitivity,
        valueBytes: 4,
        encode: encodeUint32,
        label: (r) => r.toString(),
        fallback: s.baseIso == 'High' ? _isoHigh : _isoLow,
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraState>(
      valueListenable: widget.stream.cameraState,
      builder: (context, s, _) {
        final shutter = s.shutterAngle ?? s.shutterSpeed;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('TC', s.timecode?.on == true ? s.timecode!.label : '—'),
                _row(
                  'Base',
                  s.baseIso ?? '—',
                  code: _baseIso.code,
                  onTap: () => _openEditor(_baseIso, s.baseIso),
                ),
                _row(
                  'ISO',
                  s.iso?.toString() ?? '—',
                  code: PtpProp.movieIsoSensitivity,
                  onTap: () => _openEditor(_isoEditable(s), s.iso?.toString()),
                ),
                _row(
                  'Shutter',
                  shutter ?? '—',
                  code: _shutter.code,
                  onTap: () => _openEditor(_shutter, shutter),
                ),
                _row(
                  'Aperture',
                  s.fnumber ?? '—',
                  code: _aperture.code,
                  onTap: () => _openEditor(_aperture, s.fnumber),
                ),
                _row(
                  'WB',
                  s.wbMode ?? '—',
                  code: _wbMode.code,
                  onTap: () => _openEditor(_wbMode, s.wbMode),
                ),
                _row(
                  'Temp',
                  s.wbKelvin != null ? '${s.wbKelvin}K' : '—',
                  code: _kelvin.code,
                  onTap: () => _openEditor(
                    _kelvin,
                    s.wbKelvin != null ? '${s.wbKelvin}K' : null,
                  ),
                ),
                _row('Lens', s.lens ?? '—'),
                _row('Focal', s.focalLength ?? '—'),
                _row(
                  'Rec',
                  _recRow(s),
                  code: _rec.code,
                  onTap: () => _openEditor(_rec, _recRow(s)),
                ),
                _row(
                  'Format',
                  s.fileType ?? '—',
                  code: _format.code,
                  onTap: () => _openEditor(_format, s.fileType),
                ),
                if (_note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      _note!,
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _recRow(CameraState s) {
    if (s.resolution == null) return '—';
    return s.fps != null ? '${s.resolution} · ${s.fps}p' : s.resolution!;
  }

  Widget _row(String label, String value, {int? code, VoidCallback? onTap}) {
    final locked = code != null && _locked.contains(code);
    final tap = locked ? null : onTap;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (locked) ...[
            const SizedBox(width: 6),
            const Icon(Icons.lock, size: 12, color: Colors.white38),
          ] else if (tap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.edit, size: 12, color: Colors.white38),
          ],
        ],
      ),
    );
    if (tap == null) return content;
    return InkWell(onTap: tap, child: content);
  }
}
