import 'dart:typed_data';

/// The identity fields of a PTP `DeviceInfo` dataset that this prototype shows.
class DeviceInfo {
  /// Creates a [DeviceInfo] with the given identity strings.
  const DeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
    required this.serialNumber,
  });

  /// Camera manufacturer name (e.g. `"Nikon"`).
  final String manufacturer;

  /// Camera model name (e.g. `"ZR"`).
  final String model;

  /// Firmware / device version string.
  final String deviceVersion;

  /// Camera serial number.
  final String serialNumber;

  /// Parses a standard PTP `DeviceInfo` dataset and extracts the trailing
  /// identity strings, skipping the fixed fields and the five code arrays.
  static DeviceInfo parse(Uint8List data) {
    final r = _DatasetReader(data);
    r.skip(2); // StandardVersion (UINT16)
    r.skip(4); // VendorExtensionID (UINT32)
    r.skip(2); // VendorExtensionVersion (UINT16)
    r.skipString(); // VendorExtensionDesc
    r.skip(2); // FunctionalMode (UINT16)
    r.skipUint16Array(); // OperationsSupported
    r.skipUint16Array(); // EventsSupported
    r.skipUint16Array(); // DevicePropertiesSupported
    r.skipUint16Array(); // CaptureFormats
    r.skipUint16Array(); // ImageFormats
    return DeviceInfo(
      manufacturer: r.readString(),
      model: r.readString(),
      deviceVersion: r.readString(),
      serialNumber: r.readString(),
    );
  }
}

class _DatasetReader {
  _DatasetReader(Uint8List data) : _bd = ByteData.sublistView(data);

  final ByteData _bd;
  int _offset = 0;

  void skip(int bytes) => _offset += bytes;

  void skipUint16Array() {
    final count = _bd.getUint32(_offset, Endian.little);
    _offset += 4 + count * 2;
  }

  /// Reads a PTP string: UINT8 char count (incl. trailing NUL), then that many
  /// UTF-16LE code units. Returns the value without the NUL.
  String readString() {
    final numChars = _bd.getUint8(_offset);
    _offset += 1;
    if (numChars == 0) return '';
    final units = <int>[];
    for (var i = 0; i < numChars; i++) {
      units.add(_bd.getUint16(_offset, Endian.little));
      _offset += 2;
    }
    if (units.isNotEmpty && units.last == 0) units.removeLast();
    return String.fromCharCodes(units);
  }

  void skipString() {
    final numChars = _bd.getUint8(_offset);
    _offset += 1 + numChars * 2;
  }
}
