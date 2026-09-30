---
title: Architecture
description: Portable Swift protocol core with a SwiftUI iOS shell and a Jetpack Compose Android shell.
---

OpenZCine is a shared Swift business/protocol core with native platform
shells. Policy lives in Swift; sockets, permissions, lifecycle, rendering,
storage and UI live in the shells.

| Layer | Path | Role |
| --- | --- | --- |
| Shared core | `Sources/OpenZCineCore/` | PTP and PTP-IP, camera state, Nikon property codes, discovery, pairing, layout and monitor policy. Foundation only, **portable**. |
| Core tests | `Tests/OpenZCineCoreTests/` | Swift Testing suite for the portable core. |
| iOS app | `ios/Runner/` | SwiftUI shell, Bonjour discovery, Network.framework and ImageCaptureCore transports, live-view rendering. |
| Watch companion | `ios/OpenZCineWatch/` | watchOS monitor and record remote. The phone stays the camera link. |
| Android facade | `Sources/OpenZCineAndroidFacade/` | Swift-owned Android sessions, PTP-IP and USB transaction serialization, JNI boundary. |
| Android app | `Apps/Android/app/` | Jetpack Compose shell, lifecycle, rendering, storage and platform adapters. |
| Android API | `Apps/Android/core-api/` | Typed Kotlin interface between the app and the camera session. |
| Wear OS | `Apps/Android/wear/`, `Apps/Android/wear-relay/` | Wear UI and the phone-mediated relay. |
| Bug relay | `services/bug-relay/` | Cloudflare Worker behind the anonymous Report a Problem path. |
| Prototype | `reference/flutter-prototype/` | Archived Flutter reference. Not built in CI. |

`Sources/OpenZCineCore` must never import SwiftUI, UIKit, AppKit, Android or
Compose. The interop boundary between core and shell stays as narrow as
possible.

## Transports

Wi-Fi (PTP-IP) and USB-C share one session layer behind the portable
`CameraTransport` protocol. It is **transaction-level**: one call runs a whole
PTP transaction (command, optional data, response), and a separate call reads
the next camera event. That level is set by iOS, which exposes USB PTP only
through ImageCaptureCore, one full transaction per call.

| Transport | iOS | Android |
| --- | --- | --- |
| Wi-Fi | `PTPIPTransport`: two TCP sockets, the Init Command / Init Event handshake, PTP-IP framing | Socket adapter in the app; framing and session in the Swift facade |
| USB-C | `USBCameraTransport`: ImageCaptureCore discovery and authorization, PTP USB containers | USB Host adapter hands raw bulk and interrupt bytes to the Swift facade |

Separately, each saved camera keeps the **path** the operator declared at setup
(camera access point, router, phone hotspot, USB-C). Behavior routes through
that declared path instead of being inferred from an SSID or subnet, so a router
connect can never raise a camera Wi-Fi join prompt. Design record:
[`docs/transport-architecture.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/transport-architecture.md).

## Pairing identity

The camera remembers a client by the GUID it sends in the Init Command request.
A random GUID on each launch would force re-pairing every time, so the app keeps
a stable identity per install and reuses it on every connect.

## Monitor layout

The live monitor is one view tree for landscape and portrait on iOS, and one
Compose tree on Android. Both call the same pure zone map in the core
(`MonitorZoneLayout`), which delegates to the landscape and portrait layout
policies and is covered by golden-parity tests. Rotation is a geometry change
under stable view identity, not a tree swap.

Operator-visible behavior should match across iOS and Android. The full seam
table and decision records:
[`docs/ARCHITECTURE.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/ARCHITECTURE.md).
Screen-level flows:
[`docs/flows/`](https://github.com/erik-sutton95/OpenZCine/tree/main/docs/flows).

Wire format is in [Protocol](../../protocol/connection/).
