# ZR Direct-Connect Pairing Prototype — Design

**Status:** Approved design (2026-06-14). Replaces the deleted first prototype.

**Goal:** From an iPhone joined to the Nikon ZR's own Wi-Fi access point ("Connect to PC" /
Direct mode), establish a PTP-IP connection and prove a *usable* PTP session by opening a session
and reading the camera's identity.

## Success criterion

Tapping **Pair** results in: the PTP-IP handshake completes → `OpenSession` returns OK (`0x2001`) →
`GetDeviceInfo` is read and the camera's **manufacturer, model, and serial number** are shown on
screen. That on-screen identity is the definition of "paired successfully." Any failure shows a
specific, actionable reason — in particular the decoded `Init_Fail` reason.

## Scope

**In:** one screen; manual camera IP entry; the PTP-IP connection handshake; `OpenSession`;
`GetDeviceInfo`; decoded errors.

**Out (deferred — YAGNI):** mDNS/Bonjour discovery, GUID persistence, live view, capture, any camera
controls, Android-specific work.

**Reset:** delete `lib/main.dart`, `lib/zr_live_view.dart`, `test/widget_test.dart`, and
`PROTOTYPE.md`; remove the now-unused `bonsoir` dependency from `pubspec.yaml`. Keep the Flutter
scaffold (`ios/`, `pubspec.yaml`, analysis config).

## Architecture

A pure-Dart PTP-IP client (no Flutter imports → unit-testable without hardware) behind a thin UI.

```
lib/
  main.dart                    # UI: IP field (prefilled 192.168.0.1), "Pair" button, step log + result
  ptp_ip/
    ptp_constants.dart         # packet types, opcodes, response codes, Init_Fail reason codes
    ptp_ip_packet.dart         # PTP-IP framing: Length(4)+Type(4) header, encode/decode
    ptp_operation.dart         # PTP-IP Operation_Request envelope + Operation_Response parse
    socket_reader.dart         # buffered "read exactly N bytes" over a TCP socket
    device_info.dart           # parse the GetDeviceInfo dataset -> {manufacturer, model, serial}
    ptp_ip_client.dart         # orchestrates: connect -> handshake -> OpenSession -> GetDeviceInfo
    ptp_exceptions.dart        # descriptive throws (incl. InitFailException carrying the reason)
```

Boundaries: the UI knows only `PtpIpClient` (call → camera identity, or a thrown exception). The
client composes the packet, container, reader, and device-info units; each is understood and tested
independently.

## Pairing sequence

Canonical PTP-IP connection establishment (CIPA DC-005 + libgphoto2 `ptpip.c`):

1. TCP-connect the **command** socket to `IP:15740`; send `Init_Command_Request` — stable hardcoded
   16-byte GUID, friendly name `"OpenZCine"` as raw UTF-16LE + double-NUL, protocol version on
   the wire as **`00 00 01 00`** (UINT32 `0x00010000`).
2. Read the reply on the command socket: `Init_Command_Ack` → keep the Connection Number;
   `Init_Fail` → decode the reason, surface it, stop.
3. **Only then** TCP-connect the **event** socket to `IP:15740`; send
   `Init_Event_Request(ConnectionNumber)`; read `Init_Event_Ack`.
4. Send `OpenSession` (TransactionID 0, SessionID 1) on the command socket; expect `0x2001`.
5. Send `GetDeviceInfo` (`0x1001`); reassemble the data phase; parse manufacturer / model / serial;
   display them. **This is the paired state.**

All transport facts (packet-type values, the `0x00010000` → `00 00 01 00` version bytes, the
`Init_Fail` reason codes) derive from the **public** PTP-IP standard (CIPA DC-005) + libgphoto2.
`OpenSession`, `GetDeviceInfo`, and the DeviceInfo dataset layout are standard PTP/MTP. (No
Nikon-proprietary SDK content is reproduced in this spec.)

> **PTP-IP operation envelope (correction confirmed during planning).** Over PTP-IP, operations use
> the PTP-IP `Operation_Request` envelope — `DataPhaseInfo`(4) + `Code`(2) + `TransactionID`(4) +
> params — and the data phase arrives as `Start_Data` / `Data` / `End_Data` packets (each prefixed
> with a 4-byte TransactionID), **not** the USB-style MTP generic container the old prototype wrapped.
> Layout verified against libgphoto2 `ptpip.c`. Hence the component is `ptp_operation.dart`.

## Error handling

- Throw descriptive exceptions; never signal failure with `null`.
- `InitFailException` carries the reason code; the UI maps it to actionable text:
  - **reason 1 (REJECTED_INITIATOR)** → "camera rejected us — confirm it is in Connect to PC /
    Camera Control mode with an active profile, and that no other app is connected."
  - **reason 2 (BUSY)** → another connection holds the camera; close everything and retry.
  - **reason 3 (UNSPECIFIED)** → re-check the request; surface raw reason.
- Socket connect/read **timeouts** → clear "camera not reachable / not in the right mode" message.
- **One attempt per tap** — no blind retry loop. Sockets are always closed on failure.

## Testing

- TDD the pure-Dart units with **no hardware**:
  - PTP-IP packet framing encode/decode round-trip.
  - MTP container encode/decode.
  - **Exact-bytes assertion for `Init_Command_Request`** (GUID at offset 8, name as UTF-16LE +
    double-NUL, version bytes `00 00 01 00`, correct total Length) — a regression guard for the prior
    prototype's version-byte bug.
  - `Init_Fail` reason decoding (1/2/3 → enum).
  - `GetDeviceInfo` dataset parsing against a sample byte array.
- The live pairing against a real ZR is a **manual on-device test** (documented run steps).

## References

- CIPA DC-005 (PTP-IP standard) — handshake packets and framing.
- libgphoto2 `camlibs/ptp2/ptpip.c` — public PTP-IP implementation reference.
- PIMA 15740 — OpenSession + container layout.
