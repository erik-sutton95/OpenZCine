---
title: Keeping docs current
description: Public handbook vs repo engineering docs. What to update in the same PR so opencapture.org/openzcine/docs stays accurate.
---

The public site at
[opencapture.org/openzcine/docs](https://opencapture.org/openzcine/docs/) is
this Starlight handbook. It must stay current with the apps and the protocol.
That is a same-PR rule, not a follow-up.

## Two layers

| Layer | Path | Who it is for | Published? |
| --- | --- | --- | --- |
| **Public handbook** | `handbook/src/content/docs/` | Operators, new contributors, anyone on the website | Yes, at `/openzcine/docs/` |
| **Engineering docs** | `docs/*.md`, `AGENTS.md`, `Apps/Android/README.md` | Agents and maintainers (architecture, audits, design specs, release setup) | No, they stay in the repo |

Do not paste packet captures, camera Wi-Fi keys, pairing codes, credentials,
serial numbers or private media into the handbook. Wire facts that are safe to
publish live under [Shared protocol](../../protocol/connection/).
Model-specific behavior and hardware evidence belong under
[Nikon Z Devices](../../devices/). Protocol facts must be attributable to the
public sources in
[`docs/nikon-mtp.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/nikon-mtp.md).

## What to update when

| You changed | Update in the same PR |
| --- | --- |
| PTP or PTP-IP operations, properties, events, framing | Matching page under `handbook/src/content/docs/protocol/` and the constants' comments in `Sources/OpenZCineCore/` |
| Model-specific values, generation handling, hardware findings | Matching reference under `handbook/src/content/docs/devices/`; link common definitions instead of duplicating them |
| Operator-visible monitor, controls, media or connection UX | The [iOS](../../apps/ios/) or [Android](../../apps/android/) app page if the public description changed |
| Build, toolchain, how to run | [Setup](../../guides/setup/) and [`CONTRIBUTING.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/CONTRIBUTING.md) if the GitHub workflow changed |
| TestFlight tester notes | [`ios/TestFlight/WhatToTest.en-US.txt`](https://github.com/erik-sutton95/OpenZCine/blob/main/ios/TestFlight/WhatToTest.en-US.txt) (this build; not the handbook) |
| Google Play tester notes | [`Apps/Android/distribution/whatsnew/whatsnew-en-US`](https://github.com/erik-sutton95/OpenZCine/blob/main/Apps/Android/distribution/whatsnew/whatsnew-en-US) |
| Architecture seams (core vs shell) | [Architecture](../../apps/architecture/) if the public map changed; [`docs/ARCHITECTURE.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/ARCHITECTURE.md) is the seam table |
| Transport or relay design | [`docs/transport-architecture.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/transport-architecture.md) or [`docs/streaming-architecture.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/streaming-architecture.md), then the matching handbook summary |
| Operator FAQ (discovery, pairing, stalls, delivery) | [Troubleshooting](../../guides/troubleshooting/) and the [support center](https://opencapture.org/openzcine/support/) |
| A reviewed beta release | A page under `handbook/src/content/docs/releases/` |

A task is not done until those pages match the code.

## Preview and build

```bash
cd handbook
npm ci
npm run dev                                   # http://localhost:4321/
HANDBOOK_BASE=/openzcine/docs npm run build   # as opencapture.org serves it
```

Relative links resolve from the final trailing-slash URL, not the Markdown file
path: from `guides/setup/`, the iOS page is `../../apps/ios/`. Link repo files
with absolute `https://github.com/erik-sutton95/OpenZCine/blob/main/...` URLs,
and the marketing pages with absolute `https://opencapture.org/openzcine/...`
URLs.

CI builds the handbook with `HANDBOOK_BASE=/openzcine/docs` whenever
`handbook/` changes. A merge to `main` that touches `handbook/` triggers the
opencapture.org deploy hook, which rebuilds the site.

## Release notes

Tester notes cover the current build for camera operators. A handbook release
page archives a reviewed beta window: every operator-visible change since the
previous release, for both platforms, plus what still needs hardware.

## One home per fact

The handbook summarizes. The engineering docs own the numbers and exceptions.
If a sentence would have to be edited in two places, keep it in the engineering
doc and link it here.

Agents: `AGENTS.md`. Human GitHub workflow:
[`CONTRIBUTING.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/CONTRIBUTING.md).
