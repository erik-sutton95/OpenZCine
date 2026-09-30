---
title: iOS notes
description: Physical-device limits, Local Network permission, joining the camera network, sockets, USB through ImageCaptureCore, and the demo session for the Simulator.
---

Compared with the Android shell:

- **Camera work needs a physical iPhone or iPad.** The Simulator has no camera
  Wi-Fi join and no USB camera. For UI work, set `ZC_DEMO_AUTOSTART=1` on the
  `Runner` scheme and the Simulator boots into a demo live-view session with
  synthetic frames, camera values and AF boxes
  ([CONTRIBUTING.md](https://github.com/erik-sutton95/OpenZCine/blob/main/CONTRIBUTING.md)).
  Protocol changes are covered by `just test` without hardware.
- **Local Network permission** (`NSLocalNetworkUsageDescription`) is required
  for every path. Bonjour types are declared in `NSBonjourServices`: `_ptp._tcp`
  for cameras and `_openzcine-mon._tcp` for Share This Feed. A denied
  permission makes LAN sockets time out; the infrastructure search reports it
  as its own reason ([Camera Wi-Fi](../wifi/#router-and-hotspot)).
- **Joining the camera access point.** iOS 18 and later use AccessorySetupKit:
  the system picker lists Nikon Z hotspots by declared SSID prefix, then
  `joinAccessoryHotspot`. iOS 17 falls back to `NEHotspotConfiguration`, which
  needs the Hotspot Configuration entitlement. Only a setup declared as Camera
  AP can produce a join prompt. Router, hotspot and cable setups contain no join
  code at all.
- **Camera permission** is used only to read the network name and key from the
  camera's Connection wizard screen, and on iPad to read an HDMI capture device.
- **Sockets.** PTP-IP runs on two BSD TCP sockets per session
  (`ios/Runner/PTPIPTransport.swift`). A blocked read cannot be cancelled, so a
  missed deadline closes the socket and recovery reconnects.
- **USB-C** goes through ImageCaptureCore (`ICDeviceBrowser`,
  `requestSendPTPCommand`). ImageCaptureCore owns the USB endpoints and often
  opens the PTP session itself, and it catalogues the card on attach. The app
  vetoes its per-item thumbnail and metadata fetches, which dominate the
  connect delay on a full card. See [transport](../ptpip-transport/#usb-c).
- **Initiator identity.** The app persists one 16-byte initiator GUID and never
  replaces it once stored, because the camera keys its pairing profile to it.
  Camera Wi-Fi keys live in the Keychain.
- **No internet on the camera access point.** Frame.io delivery and the RED LUT
  download offer an internet hop: leave the camera network, finish, then rejoin.
- **Frame.io** sign-in uses `ASWebAuthenticationSession` and needs iOS 17.4.
  The rest of the app targets iOS 17.0.

See [Camera Wi-Fi](../wifi/), [iOS app](../../apps/ios/) and
[Troubleshooting](../../guides/troubleshooting/).
