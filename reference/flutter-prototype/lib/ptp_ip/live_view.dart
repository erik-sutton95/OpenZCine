import 'dart:typed_data';

/// LiveViewObject layout: a fixed display-info header followed by a complete,
/// standalone JPEG (`GetLiveViewImageEx 0x9428`).
const int liveViewHeaderLength = 1024;

/// Extracts the JPEG image from a `GetLiveViewImageEx` LiveViewObject: skip the
/// 1024-byte header, then trust the "live view image area size" length at header
/// offset 12 when it is sane (else take everything to the end). Throws
/// [FormatException] when the object is too short or lacks a JPEG SOI marker.
Uint8List extractLiveViewJpeg(Uint8List liveViewObject) {
  if (liveViewObject.length < liveViewHeaderLength + 3) {
    throw FormatException(
      'live-view object too short: ${liveViewObject.length} bytes',
    );
  }
  final declaredLength =
      ByteData.sublistView(liveViewObject).getUint32(12, Endian.little);
  final end = (declaredLength > 0 &&
          liveViewHeaderLength + declaredLength <= liveViewObject.length)
      ? liveViewHeaderLength + declaredLength
      : liveViewObject.length;
  final jpeg = Uint8List.sublistView(liveViewObject, liveViewHeaderLength, end);
  if (jpeg.length < 3 ||
      jpeg[0] != 0xff ||
      jpeg[1] != 0xd8 ||
      jpeg[2] != 0xff) {
    throw const FormatException('no JPEG SOI at offset $liveViewHeaderLength');
  }
  return jpeg;
}

/// Movie timecode decoded from a LiveViewObject header.
class Timecode {
  const Timecode({
    required this.on,
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
    this.frame = 0,
  });

  /// Whether the camera reports timecode active.
  final bool on;
  final int hour;
  final int minute;
  final int second;
  final int frame;

  /// `HH:MM:SS:FF`.
  String get label => '${_p(hour)}:${_p(minute)}:${_p(second)}:${_p(frame)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}

/// A fetched LiveViewObject split into its header-derived data and JPEG.
class LiveViewFrame {
  const LiveViewFrame({required this.jpeg, required this.timecode});
  final Uint8List jpeg;
  final Timecode timecode;
}

/// Parses the movie [Timecode] from a LiveViewObject header (offsets 831–835).
/// Tolerant: returns an off timecode if the object is too short.
Timecode parseTimecode(Uint8List liveViewObject) {
  if (liveViewObject.length < 836) return const Timecode(on: false);
  return Timecode(
    on: liveViewObject[831] == 1,
    hour: liveViewObject[832],
    minute: liveViewObject[833],
    second: liveViewObject[834],
    frame: liveViewObject[835],
  );
}
