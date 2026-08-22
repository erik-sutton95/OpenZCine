---
status: awaiting_hardware_verify
trigger: "Nikon Z6 firmware 3.80 cannot connect from iPad Pro via USB or Wi-Fi (#348)"
created: 2026-08-23
updated: 2026-08-23
---

## Current Focus

hypothesis: PARTIAL — gen-1 connect still assumed a modern pairing surface whenever
`GetDeviceInfo` did not advertise operations, which an original Z 6 (same generation as the
Z 5 in #292) can hit on both USB and Wi-Fi
next_action: Hardware matrix on an original Z 6 firmware 3.80, starting with iPad Pro (2018)
USB-C and Connect-to-computer Wi-Fi

## Report

- Nikon Z 6, firmware 3.80 (untested in the compatibility matrix)
- iPad Pro (2018), TestFlight identity iPad8,3, iPadOS 26.6.1
- OpenZCine 0.2.5 (build 260), which already includes the #292 gen-1 DeviceInfo gate
- USB does not complete; no attempted Wi-Fi method completes
- No diagnostics export or exact in-app phase yet

## Ranked hypotheses

1. **Unknown DeviceInfo keeps the modern surface.** `ZCameraOperationPolicy` treats an empty
   ops list as gen 3, so first-time Wi-Fi still sends `GetPairingInfo` / `ChangeApplicationMode`.
   That is the #292 failure mode when the probe is missing, not merely when the ops list is
   the gen-1 set. Confirmed in a FakeZR loop: handshake name `Z 6_…` with empty ops previously
   paired; after the fix it writes `ApplicationMode` and never pairs.
2. **iOS USB OpenSession-first.** Android USB already issues `GetDeviceInfo` (transaction 0)
   before `OpenSession` because OpenSession-first hung on the cable. iOS relied on
   ImageCaptureCore having opened the session. If ICC does not pre-open an original Z 6,
   the 180 s first command is an unexplained “Connecting…”.
3. **Android USB ignored the probe for app-control.** The pre-session `GetDeviceInfo` was
   discarded; app-control always used the empty/modern policy (`ChangeApplicationMode`).
4. **Wrong Wi-Fi menu.** SnapBridge / Connect to smart device is not PTP-IP. The wizard
   already points at Connect to computer; still possible operator path. Not a code defect
   if that was the method used.
5. **iPad USB never enumerates** (charge-only cable, Photos claiming the device, camera
   control denied). Copy now says “this device” instead of iPhone; authorization recovery
   already exists.

## Code change

- Shared: `ZCameraOperationPolicy.resolvingUnknown(cameraName:)` takes the gen-1 surface
  when DeviceInfo is unknown and the PTP-IP / USB name is an original Z 5 / Z 6 / Z 7 / Z 50.
  `Z 6III` / `Z 6II` / `ZR` keep the modern pairing default.
- iOS: USB probes `GetDeviceInfo` before `OpenSession`; both transports apply the name
  fallback. Establishment diagnostics record `gateFallback=gen1-name`.
- Android facade: Wi-Fi probe applies the same fallback; USB parses the pre-session
  DeviceInfo and passes that policy into app-control.

## Not verified on hardware

Support status remains **untested**. Do not mark the Z 6 working on the landing page until
USB and Connect-to-computer Wi-Fi complete on a real body.

Still needed from the reporter: privacy-safe diagnostics, USB cable/mode, which Wi-Fi
method, whether Nikon’s app connects from this iPad, and whether another iPhone/iPad can
reach the same Z 6.
