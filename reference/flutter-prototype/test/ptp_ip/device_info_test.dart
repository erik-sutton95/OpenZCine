import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcinecontroller/ptp_ip/device_info.dart';

/// PTP string: UINT8 length-in-chars (incl. trailing NUL) + UTF-16LE code units.
List<int> _ptpString(String s) {
  if (s.isEmpty) return [0];
  final bytes = <int>[s.length + 1];
  for (final u in s.codeUnits) {
    bytes.addAll([u & 0xFF, (u >> 8) & 0xFF]);
  }
  bytes.addAll([0, 0]); // NUL
  return bytes;
}

List<int> _emptyArray() => [0, 0, 0, 0]; // UINT32 count = 0

void main() {
  test('parse extracts manufacturer, model, version, serial', () {
    final data = <int>[
      100, 0, //              StandardVersion
      10, 0, 0, 0, //         VendorExtensionID
      100, 0, //              VendorExtensionVersion
      ..._ptpString(''), //   VendorExtensionDesc
      0, 0, //                FunctionalMode
      ..._emptyArray(), //    OperationsSupported
      ..._emptyArray(), //    EventsSupported
      ..._emptyArray(), //    DevicePropertiesSupported
      ..._emptyArray(), //    CaptureFormats
      ..._emptyArray(), //    ImageFormats
      ..._ptpString('Nikon'),
      ..._ptpString('ZR'),
      ..._ptpString('1.0'),
      ..._ptpString('ABC123'),
    ];
    final info = DeviceInfo.parse(Uint8List.fromList(data));
    expect(info.manufacturer, 'Nikon');
    expect(info.model, 'ZR');
    expect(info.deviceVersion, '1.0');
    expect(info.serialNumber, 'ABC123');
  });
}
