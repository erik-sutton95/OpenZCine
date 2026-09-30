---
title: OpenZCine docs
description: Protocol, apps, and how to build OpenZCine, the public handbook at opencapture.org/openzcine/docs.
---

OpenZCine is the open field monitor for Nikon Z. It turns an iPhone, iPad or
Android phone into a production monitor and remote for Nikon Z cinema cameras,
with development and testing centered on the **Nikon ZR**. These pages are the
**public handbook**: the camera protocol, both apps, and how to build and
maintain the project. Markdown in `handbook/src/content/docs/` is the source.
Engineering notes that agents and maintainers follow (`AGENTS.md`,
`docs/ARCHITECTURE.md`, audits and design specs) stay in the git repo and are
summarized here, not copied.

Product pages live on the marketing site:
[opencapture.org/openzcine](https://opencapture.org/openzcine/), with the
[support center](https://opencapture.org/openzcine/support/) and the
[privacy policy](https://opencapture.org/openzcine/privacy/).

OpenZCine is not affiliated with Nikon. No vendor SDK or proprietary Nikon
documentation is in this repository or needed to build it. Protocol facts come
from the public PTP and PTP-IP standards, libgphoto2 and behavior observed on
cameras we test ([`docs/nikon-sdk.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/nikon-sdk.md)).

:::caution[Do not publish captures]
Packet captures (`*.pcap`, `*.pcapng`) are gitignored and never committed.
Do not open issues or discussions with captures, camera Wi-Fi keys, pairing
codes, private media or vendor documents.
:::

## Start here

- [Setup and build](./guides/setup/): `just`, Xcode, the demo session without a camera, Android, quality gate
- [Troubleshooting](./guides/troubleshooting/): discovery, pairing, Wi-Fi, USB-C, live view and delivery
- [Share This Feed](./guides/share-feed/): broadcast the monitor to other phones and iPads on set
- [Architecture](./apps/architecture/): portable Swift core, SwiftUI, Compose
- [iOS app](./apps/ios/): iPhone, iPad, Apple Watch and TestFlight
- [Android app](./apps/android/): Compose shell, Wear OS, Google Play and the sideload APK
- [Keeping docs current](./contribute/documentation/): what to update in the same PR

## Nikon Z Devices

[Device references](./devices/) collect model-specific behavior, command
differences and evidence. Start here for what a body supports and what still
needs hardware verification:

- [Nikon ZR](./devices/zr/): the primary target; modes, exposure, focus, media and connection evidence
- [Nikon Z 6III](./devices/z6iii/): USB product naming, pairing and connection fixes
- [Original Z 5, Z 6, Z 7 and Z 50](./devices/gen-1/): first-generation bodies without the pairing handshake

## Shared protocol

The camera speaks PTP (ISO 15740). Over Wi-Fi it runs as PTP-IP (CIPA DC-005)
on TCP port 15740; over USB-C it runs as standard PTP containers.

```text
discover → TCP command socket → Init Command → event socket → Init Event → OpenSession → pair → app mode → properties → live view → media
```

- [Connection spine](./protocol/connection/)
- [Camera Wi-Fi](./protocol/wifi/)
- [PTP-IP packet](./protocol/ptpip-packet/) · [PTP-IP and USB transport](./protocol/ptpip-transport/)
- [Command catalog](./protocol/commands/)
- [Live view](./protocol/live-view/)
- [Media transfer](./protocol/media/)
- [iOS protocol notes](./protocol/ios/)
