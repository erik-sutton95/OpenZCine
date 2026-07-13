# PTP / PTP-IP protocol maintenance

How the camera protocol layer in this repo is sourced, verified, and extended.

## Sources of truth

1. **Public standards.** PIMA 15740 / ISO 15740 (PTP) for operations, response codes, containers,
   and dataset encodings; CIPA DC-005 (PTP-IP) for the Wi-Fi transport handshake and packet
   framing.
2. **libgphoto2.** The LGPL [libgphoto2](https://github.com/gphoto/libgphoto2) project
   (`camlibs/ptp2/ptp.h` and `ptpip.c`) is the public reference for Nikon vendor operation and
   property codes. When adding a new opcode or property, check whether it is already cataloged
   there and note the symbol name in a comment.
3. **Observed interoperability behavior.** Anything not covered by the above (newer vendor codes,
   dataset layouts, sequencing/timing constraints) is established by observing how the camera
   actually behaves and is verified on hardware before being relied on in code.

## Rules for protocol changes

- Do not add codes or dataset layouts you cannot attribute to one of the sources above.
- Mark hardware-verified behavior that lacks a public citation as observed behavior in the
  comment; do not invent citations.
- Protocol constants live in `Sources/OpenZCineCore/PTPOperation.swift`,
  `PTPCameraProperties.swift`, and `PTPEvent.swift`; keep new codes alongside their peers with the
  same commenting style.
- Anything unconfirmed on a real camera gets a `[VERIFY-ON-HW]` marker until it is exercised on
  hardware.

See also `docs/nikon-sdk.md` for the project's no-vendor-SDK policy.
