---
title: Z 6III connection and reconnect
description: USB product-name matching, Android USB dead-write recovery, access-point joins and shared addresses on the Nikon Z 6III.
---

Part of the [Nikon Z 6III reference](../).
Read the overview for firmware, survey scope and evidence levels.

## USB product name

**Observed
([#363](https://github.com/erik-sutton95/OpenZCine/pull/363),
[Discussion #12](https://github.com/erik-sutton95/OpenZCine/discussions/12)):**
Nikon's USB product string for this body is `NIKON DSC Z6_3`. The app compacted
it to `Z63`, which matched the original Z 6. When the `GetDeviceInfo` probe was
missed, the app then skipped pairing and wrote the generation 1
`ApplicationMode` property, and the camera showed a connection error.

Generation marks (`Z6_3`, `Z 6_2`, `Z5_2`, `Z50_2`) are now rewritten to roman
numerals before punctuation is stripped, longest match first. A digit after the
underscore means a serial number follows, not a generation mark, and the name is
left alone. **Synthetic:** a facade test pins that an empty DeviceInfo with the
`Z6_3` product name still pairs.

Share Diagnostics now includes a local connect-attempt trace: the inferred body
family, whether DeviceInfo was known, and the pairing decision. It uses closed
model tokens (`z6iii`) and never a serial number, and it leaves the phone only
when the operator shares the file.

## Android USB dead write

**Observed (Discussion #12, Z 6III over USB-C on an Android phone):** the first
bulk-out write, the 12-byte `GetDeviceInfo` command, returned `-1` even though
the USB device status read OK. The system MTP handler had left an aborted
session on attach. The app already issued a PTP device reset, but still returned
the failure, so every reconnect showed an error.

That write is now retried once on the same attempt after the reset. This is
Android only; iOS USB goes through ImageCaptureCore. **Synthetic:** a JVM test
pins the retry. `[verify-on-HW]`: reconnect after a pending live view on the
same phone.

## Camera access point

The ZR's network name can be derived from its PTP friendly name; a Z 6III's
cannot. A camera access-point setup with no stored network name used to skip the
join entirely. It now asks the system to join by the Nikon brand prefix, without
inventing a model-specific name. The exact scanned or stored name stays
authoritative.

## Two bodies, one address

**Observed ([#293](https://github.com/erik-sutton95/OpenZCine/issues/293)):**
pairing a Z 5 removed the saved Z 6III. Every Nikon camera access point serves
its camera at the same address, and saved records sharing a host were merged.
DHCP reuse on a router does the same. A shared address now merges records only
when the names do not contradict it: two different assigned names prove two
bodies. Forgetting one no longer deletes the other. **Synthetic:** regression
tests on both platforms.
