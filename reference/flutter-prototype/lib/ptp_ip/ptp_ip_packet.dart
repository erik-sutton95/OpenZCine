import 'dart:typed_data';

/// A PTP-IP packet: an 8-byte header (Length, Type — both UINT32 LE) followed by
/// a type-specific payload. `Length` counts the whole packet including the header.
class PtpIpPacket {
  PtpIpPacket(this.type, this.payload);

  /// PTP-IP packet type code (see PtpIpType).
  final int type;

  /// Bytes after the 8-byte header.
  final Uint8List payload;

  /// Serializes to `Length(4 LE) + Type(4 LE) + payload`.
  Uint8List toBytes() {
    final length = 8 + payload.length;
    final bytes = Uint8List(length);
    final bd = ByteData.sublistView(bytes);
    bd.setUint32(0, length, Endian.little);
    bd.setUint32(4, type, Endian.little);
    bytes.setRange(8, length, payload);
    return bytes;
  }

  /// Parses a complete, length-prefixed packet from [bytes].
  static PtpIpPacket fromBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException(
        'PTP-IP packet shorter than its 8-byte header',
      );
    }
    final bd = ByteData.sublistView(bytes);
    final length = bd.getUint32(0, Endian.little);
    final type = bd.getUint32(4, Endian.little);
    if (bytes.length < length) {
      throw const FormatException('PTP-IP packet truncated');
    }
    return PtpIpPacket(type, Uint8List.sublistView(bytes, 8, length));
  }
}
