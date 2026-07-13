import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/ptp_ip_packet.dart';

void main() {
  test('toBytes writes little-endian Length then Type, then payload', () {
    final pkt = PtpIpPacket(1, Uint8List.fromList([0xAA, 0xBB]));
    expect(pkt.toBytes(), [10, 0, 0, 0, 1, 0, 0, 0, 0xAA, 0xBB]);
  });

  test('fromBytes round-trips type and payload', () {
    final original = PtpIpPacket(5, Uint8List.fromList([1, 0, 0, 0]));
    final parsed = PtpIpPacket.fromBytes(original.toBytes());
    expect(parsed.type, 5);
    expect(parsed.payload, [1, 0, 0, 0]);
  });

  test('fromBytes throws on a header shorter than 8 bytes', () {
    expect(() => PtpIpPacket.fromBytes(Uint8List(4)), throwsFormatException);
  });
}
