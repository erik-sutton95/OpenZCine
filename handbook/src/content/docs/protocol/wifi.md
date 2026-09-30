---
title: Camera Wi-Fi
description: Camera access point, router and phone hotspot paths, the credential scan, and how discovery finds a body on the network.
---

PTP-IP needs the phone and the camera on one IP network. OpenZCine supports
three Wi-Fi paths. Each is a **declared setup**, chosen once and saved per
camera, never re-derived from an SSID or a subnet afterwards
([transport architecture](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/transport-architecture.md)).

| Path | Who joins whom | Camera menu | App behavior |
| --- | --- | --- | --- |
| **Camera AP** | The phone joins the camera's own network | Connection wizard shows the SSID and key | The only path with Wi-Fi join code |
| **Router** (infrastructure) | Both join an existing network | Network menu, Connect to PC, a profile for that network | Never touches Wi-Fi settings; searches the current network |
| **Hotspot** | The camera joins the phone's Personal Hotspot | Connect to PC with a profile for the hotspot | Hosts and waits; scans and joins nothing |

USB-C and HDMI capture are the other two setup kinds; see
[PTP-IP and USB transport](../ptpip-transport/). A camera can hold one setup
per kind, and a DHCP move updates the router setup's address in place.

## Camera access point

The camera's Connection wizard screen shows its network name and key. The app
can read both from that screen with the phone camera: on-device text
recognition hands one transcript to the shared
`CameraWiFiScreenParser`, which validates the Nikon Z network shape and
repairs common look-alike characters. The operator reviews the result before
joining. When the scan cannot validate a format, manual entry accepts the name
and key as typed.

SSIDs are **not** synthesized for unknown bodies. The ZR's network name can be
derived from its PTP name; other bodies use the exact scanned or stored name,
and a setup without one joins by Nikon brand prefix.

:::caution[Never publish the key]
The camera key, scan screenshots and saved credentials must not appear in
issues, pull requests or captures. Keys are stored in the iOS Keychain or an
Android Keystore-encrypted store; Android writes one only after a successful
join.
:::

| Platform | Join |
| --- | --- |
| iOS 18+ | AccessorySetupKit system picker, `joinAccessoryHotspot` |
| iOS 17 | `NEHotspotConfiguration` (Hotspot Configuration entitlement) |
| Android | `WifiNetworkSpecifier` plus `ConnectivityManager.bindProcessToNetwork` |

The access point's IP is **not** a constant across bodies, firmware or regions.
After the join, connect rediscovers the camera on the live link instead of
dialing a guessed address. An access-point setup that has never learned an
address is stored under a non-dialable placeholder key. The access point has no
internet; see [iOS notes](../ios/) for how the app routes around that.

## Router and hotspot

On a router the camera must have a Connect to PC profile for that same network.
The infrastructure finder
([`InfrastructureDiscovery.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/InfrastructureDiscovery.swift))
browses continuously, probes known hosts patiently, then sweeps the local
subnet. After two empty passes it offers manual host entry. When nothing is
found it reports a typed reason instead of an endless search:

| Reason | Meaning |
| --- | --- |
| Still on the camera AP | The phone is on the camera's network, so a router search cannot succeed |
| Silent network | Almost nothing answers: wrong network, client isolation, or a permission problem |
| Hosts but no PTP-IP | Devices answer, but nothing accepts port 15740. Connect to PC is off, or isolation blocks the camera |
| Held by another device | Another OpenZCine device holds the only camera found |
| Budget exhausted | No camera and no stronger diagnosis |

On the hotspot path the phone is the network. iOS waits for the camera to
appear on the hotspot subnet; Android waits on NSD discovery.

## Discovery

| Step | Detail |
| --- | --- |
| Bonjour | Browse `_ptp._tcp` for the lifetime of the search (iOS Network framework, Android NSD) |
| Port sweep | Connect and close on TCP 15740, bounded width, **no PTP bytes sent** |
| Identify | A minimal `Init_Command_Request` only against hosts that answered, to read the camera name |
| Liveness | Saved cameras are checked with a kernel-level dial, never a PTP Init |

Every private IPv4 range is scanned, `10/8` included. The plan starts from the
subnets the phone actually has an address in and widens to neighbouring /24s,
nearest first
([`SubnetScanPlan.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/SubnetScanPlan.swift)).

Probing is deliberately gentle. A camera serves one PTP-IP initiator, and an
`Init` from a second device drops the first device's session or knocks a body
out of pairing mode. A camera another OpenZCine device announces as held is
listed as in use and is not probed.

Operator steps for each path: [Troubleshooting](../../guides/troubleshooting/).
Once the camera is reachable, open the [PTP-IP session](../ptpip-transport/).
