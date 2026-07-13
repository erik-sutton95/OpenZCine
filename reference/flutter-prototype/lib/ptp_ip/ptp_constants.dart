import 'dart:typed_data';

/// Default PTP-IP TCP port (both the command and event channels).
const int ptpIpPort = 15740;

/// Canonical PTP-IP protocol version (UINT32 0x00010000 -> wire bytes 00 00 01 00).
const int ptpIpProtocolVersion = 0x00010000;

/// Parameter passed to [PtpOp.confirmPairing] to finalize the ZR's Wi-Fi
/// pairing handshake.
const int pairingConfirmValue = 0x2001;

/// PTP-IP packet type codes (CIPA DC-005).
class PtpIpType {
  PtpIpType._();
  static const int initCommandRequest = 1;
  static const int initCommandAck = 2;
  static const int initEventRequest = 3;
  static const int initEventAck = 4;
  static const int initFail = 5;
  static const int operationRequest = 6;
  static const int operationResponse = 7;
  static const int event = 8;
  static const int startData = 9;
  static const int data = 0x0A;
  static const int cancel = 0x0B;
  static const int endData = 0x0C;
}

/// PTP operation codes used by this prototype. Hex values are cross-referenced
/// against libgphoto2 `camlibs/ptp2/ptp.h`.
class PtpOp {
  PtpOp._();
  static const int getDeviceInfo = 0x1001;
  static const int openSession = 0x1002;
  static const int closeSession = 0x1003;

  // --- ZR Wi-Fi pairing handshake ---
  /// Data-in pairing query issued right after OpenSession; returns an 8-byte
  /// status blob.
  static const int getPairingInfo = 0x952b;

  /// Pairing-confirm/unlock op. Called with [pairingConfirmValue]; on success
  /// the camera fires DeviceInfoChanged and shows "Pairing Complete".
  static const int confirmPairing = 0x935a;

  // --- New-API vendor ops (ZR) ---
  static const int changeApplicationMode = 0x9435;
  static const int getVendorCodes = 0x9439; // P1: 0x09=ops, 0x0D=props
  static const int getDevicePropDescEx = 0x943a; // P1: 4-byte DevicePropCode
  static const int getDevicePropValueEx = 0x943b; // P1: 4-byte DevicePropCode
  static const int setDevicePropValueEx = 0x943c; // P1: 4-byte DevicePropCode
  static const int getCommandFeature = 0x944c; // P1: command code to describe

  // --- Live view (activation cmd + readiness poll + pull loop) ---
  static const int startLiveView = 0x9201;
  static const int endLiveView = 0x9202;
  static const int getLiveViewImageEx = 0x9428;
  static const int deviceReady = 0x90c8;

  // --- Events ---
  static const int getEventEx = 0x941c; // P1: KeepBuffer (0=delete, 1=keep)
}

/// Vendor PTP device-property codes (4-byte New-API codes) referenced directly.
class PtpProp {
  PtpProp._();

  /// `LiveViewProhibitionCondition` — gate for StartLiveView; must read 0.
  static const int liveViewProhibitionCondition = 0xd1a4;

  /// `LiveViewImageSize` — 1=QVGA, 2=VGA, 3=XGA (settable; [VERIFY-ON-HW] in PC mode).
  static const int liveViewImageSize = 0xd1ac;

  /// `LiveViewImageCompression` — 0..5 (Basic/Normal/Fine × Size/Quality).
  static const int liveViewImageCompression = 0xd1bc;

  /// `MovieRecProhibitionCondition` — UINT32 bitfield; nonzero ⇒ cannot record.
  /// Bit14 = "Not in application mode" (cleared by ChangeApplicationMode P1=1).
  static const int movieRecProhibitionCondition = 0xd0a4;

  /// `MovieRecordScreenSize` — UINT64; bits 16-23 = movie frame rate (fps).
  static const int movieRecordScreenSize = 0xd0a0;

  /// `ISOControlSensitivity` — UINT32, the effective ISO the camera is applying.
  static const int isoControlSensitivity = 0xd0b5;

  /// `MovieExposureIndex` — UINT32 video ISO (Mode M; rejected in RAW/R3D).
  static const int movieExposureIndex = 0xd1aa;

  /// `MovieBaseISOSensitivity` — UINT8 dual-base selector (1=Low/800, 2=High/6400).
  static const int movieBaseIso = 0x0001d09d;

  /// `MovieISOSensitivity` — UINT32 working video ISO; range follows the base
  /// (Low 200–3200, High 1600–25600).
  static const int movieIsoSensitivity = 0x0001d09e;

  /// `MovieShutterSpeed` — UINT32; upper 16b numerator, lower 16b denominator.
  static const int movieShutterSpeed = 0xd1a8;

  /// `MovieShutterAngle` — INT32 cine shutter angle ×100 (18000 = 180°).
  static const int movieShutterAngle = 0x0001d075;

  /// `MovieFnumber` — UINT16 aperture ×100 (280 = f/2.8).
  static const int movieFnumber = 0xd1a9;

  /// `MovieWhiteBalance` — UINT16 WB-mode enum.
  static const int movieWhiteBalance = 0xd23a;

  /// `MovieWbColorTemp` — UINT16 white-balance colour temperature in Kelvin.
  static const int movieWbColorTemp = 0xd21a;

  /// `MovieFileType` — UINT32; packs codec, bit-depth, container.
  static const int movieFileType = 0xd0af;

  /// `FocalLength` — UINT32 current focal length in mm ×100 (read-only).
  static const int focalLength = 0x5008;

  /// `LensID` — UINT16 attached-lens identification code (read-only).
  static const int lensId = 0xd0e0;

  /// `LensFocalMin` — UINT32 minimum focal length of the lens, mm ×100 (read-only).
  static const int lensFocalMin = 0xd0e3;

  /// `LensFocalMax` — UINT32 maximum focal length of the lens, mm ×100 (read-only).
  static const int lensFocalMax = 0xd0e4;

  /// `LensApertureMin` — UINT16 widest (min f-number) aperture, ×100 (read-only).
  static const int lensApertureMin = 0xd0e5;
}

/// PTP response codes.
class PtpResponse {
  PtpResponse._();
  static const int ok = 0x2001;
  static const int deviceBusy = 0x2019;
}

/// PTP-IP Init_Fail reason codes (CIPA DC-005 §2.3.5).
enum InitFailReason {
  rejectedInitiator(1),
  busy(2),
  unspecified(3),
  unknown(-1);

  const InitFailReason(this.code);

  /// The on-wire reason value (or -1 for [unknown]).
  final int code;

  /// Maps a raw on-wire reason value to an [InitFailReason].
  static InitFailReason fromCode(int code) => InitFailReason.values.firstWhere(
        (reason) => reason.code == code,
        orElse: () => InitFailReason.unknown,
      );
}

/// A stable, app-specific 16-byte initiator GUID. Hardcoded so the camera sees
/// the *same* identity on every attempt (a per-attempt-random GUID can never be
/// recognized/paired). A persisted GUID is a future enhancement.
Uint8List zcineControllerGuid() => Uint8List.fromList(<int>[
      0x5a,
      0x43,
      0x69,
      0x6e,
      0x65,
      0x43,
      0x74,
      0x72,
      0x6c,
      0x00,
      0x11,
      0x22,
      0x33,
      0x44,
      0x55,
      0x66,
    ]);
