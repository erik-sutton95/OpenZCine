# Vendor SDKs (not included, not required)

This project is **not** affiliated with or endorsed by Nikon. It does not include, bundle, or
depend on any Nikon SDK, header, documentation, or other proprietary material — and none is
needed to build, run, or contribute.

The app communicates with the camera using the standard PTP/MTP protocol over USB and PTP-IP over
Wi-Fi. The protocol implementation is based on public sources:

- **PIMA 15740 / ISO 15740** — the PTP standard (operations, containers, datasets).
- **CIPA DC-005** — the PTP-IP transport standard (handshake, packet framing).
- **[libgphoto2](https://github.com/gphoto/libgphoto2)** — LGPL, long-standing public catalog of
  Nikon vendor operation/property codes (`camlibs/ptp2/ptp.h`).
- **Observed interoperability behavior** — values and sequences confirmed against real hardware.

The `vendor/` and `ref/` directories are gitignored; anything placed there stays local and is
never committed.
