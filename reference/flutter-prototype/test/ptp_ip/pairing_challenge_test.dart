import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/pairing_challenge.dart';

void main() {
  test('preserves raw challenge bytes as lowercase hex', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[0x01, 0xab, 0x00, 0xff]),
    );

    expect(challenge.rawHex, '01 ab 00 ff');
  });

  test('extracts a 4 digit ASCII PIN from the payload', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList('pin=6794'.codeUnits),
    );

    expect(challenge.pin, '6794');
  });

  test('extracts a 4 digit UTF-16LE PIN from the payload', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[
        0x36, 0x00, // 6
        0x37, 0x00, // 7
        0x39, 0x00, // 9
        0x34, 0x00, // 4
      ]),
    );

    expect(challenge.pin, '6794');
  });

  test('extracts a 4 digit BCD PIN from consecutive bytes', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[0x67, 0x94]),
    );

    expect(challenge.pin, '6794');
  });

  test('extracts a little-endian numeric PIN after a binary length field', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[
        0x04, 0x00, // 4-digit auth code follows.
        0x7f, 0x07, // 1919, little-endian UInt16.
      ]),
    );

    expect(challenge.pin, '1919');
  });

  test('extracts a BCD PIN after a binary length field', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[
        0x04, 0x00, // 4-digit auth code follows.
        0x19, 0x19, // 1919, packed BCD.
      ]),
    );

    expect(challenge.pin, '1919');
  });

  test('extracts a little-endian numeric PIN after a uint32 length field', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[
        0x04, 0x00, 0x00, 0x00, // 4-digit auth code follows.
        0x7f, 0x07, // 1919, little-endian UInt16.
      ]),
    );

    expect(challenge.pin, '1919');
  });

  test('extracts one-byte digits after a uint32 length field', () {
    final challenge = PairingChallenge.parse(
      Uint8List.fromList(<int>[
        0x04, 0x00, 0x00, 0x00, // 4-digit auth code follows.
        0x08, 0x08, 0x05, 0x04, // 8854, one digit per byte.
      ]),
    );

    expect(challenge.pin, '8854');
  });
}
