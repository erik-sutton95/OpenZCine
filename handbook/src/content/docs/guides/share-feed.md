---
title: Share This Feed
description: Broadcast the monitor from the device on the camera to other phones and iPads on set, with per-watcher assists and control handoff.
---

**Beta feature. Several network paths still need hardware verification.**
Share This Feed is on iPhone, iPad and Android. See
[What is still pending](#what-is-still-pending) before relying on it for a take.

A Nikon camera serves one PTP-IP session at a time, and every install presents
the same identity to it. A second screen therefore exists only as a relay: the
device connected to the camera (the **broadcaster**) serves its picture and the
camera's readings to other devices running OpenZCine (the **watchers**). The
camera link never moves.

## Start a broadcast

1. Connect to the camera as usual.
2. Open **Settings → Link** and turn on **Share This Feed**.
3. Optionally set a **Watcher Passcode**. Watchers enter it once per device
   before they receive any picture or readings. Leave it empty for an open
   broadcast. Devices already watching keep access until they leave.
4. Choose **Broadcast Priority**. Low latency is the tightest glass-to-glass
   path, the setting for pulling focus. Quality trades about four frames
   (around 130 ms) for a steadier stream. Changing it mid-broadcast briefly
   restarts the stream; watchers rejoin on their own.

The **Watching** list shows the devices currently receiving the feed.

## Watch a broadcast

On another device, open OpenZCine. Broadcasts appear under **Nearby
Broadcasts** in the camera list. Tap one to watch.

Watchers stay on their own network, or none: devices can find each other
directly without a router. **Do not join the camera's own Wi-Fi on a watcher.**
The camera access point drops the monitor when a second device joins it.

A watching device cannot re-share the feed it receives. That would add a second
encode and a second hop of delay for everyone downstream.

## Per-watcher monitoring

Each watcher sees the picture and every View Assist tool, and chooses its own
scopes, LUT and assists. Those choices stay local to the watcher. A watcher
cannot change anything on the camera unless it holds control.

## Camera control handoff

| Step | What happens |
| --- | --- |
| Request | A watcher asks to drive the camera. The request appears on the broadcaster's live view. |
| Grant or decline | The broadcaster chooses **Grant** or **Decline**. **Control Requests** in Settings can hide the ask on watchers entirely. |
| Control | One holder at a time. The broadcaster keeps the camera link and runs the holder's commands on its behalf. |
| Take back | The broadcaster reclaims control at any time, without asking. |

A watcher that holds control can start and stop recording. Control survives a
brief network blink: a watcher that reconnects is recognized as the same device
and resumes the control it held.

## Picture and bandwidth

The broadcaster encodes once with the hardware HEVC encoder and sends the same
stream to every watcher. Watchers whose hardware cannot decode that HEVC stream
are served JPEG automatically, a heavier picture but never no picture. The
stream carries explicit BT.709 color tags so a LUT on the watcher does not
amplify a color-matrix guess.

A watcher that stops keeping up is skipped rather than queued, then resumes at
the next keyframe. When the network is congested, the bitrate steps down
(10, 7, 4.5 and 3 Mb/s) and climbs back one step after 30 clean seconds. The
broadcaster's own camera feed counts toward that signal: the operator's monitor
is protected first. Each extra watcher costs roughly one more stream of Wi-Fi
uplink from the broadcaster.

Relay connections have no authentication beyond the optional passcode. A set
LAN is treated as trusted. Use the passcode on shared networks.

## What is still pending

The relay is verified on simulators and emulators. These remain open on real
hardware:

- the stutter improvement through a real set router
- the smoothness gain from turning peer-to-peer advertising off
- the effect of video-class network priority through a travel router
- the bitrate ladder under genuine congestion
- relay reach over peer-to-peer Wi-Fi during a camera access point session

The design record, invariants and rejected alternatives are in
[`docs/streaming-architecture.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/streaming-architecture.md).
The wire format is summarized under [Live view](../../protocol/live-view/).
