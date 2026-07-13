# RED LUT download over an internet hop (camera-AP mode)

**Date:** 2026-07-05 · **Status:** approved

## Problem

The in-app RED IPP2 LUT download needs the public internet. In camera-AP transport the phone is
joined to the ZR's local-only Wi‑Fi, so the download screen is a dead end: it blocks with
"you're on the camera's Wi‑Fi, which has no internet."

## Decision

Offer a **Wi‑Fi hop**: temporarily leave the camera's network so iOS falls back to home Wi‑Fi or
cellular, let the existing download run, then rejoin the camera network and auto-reconnect using
the machinery already built for the post-pairing AP restart.

Rejected alternatives:
- **Cellular-pinned download while staying on the AP** — `URLSession` cannot pin an interface;
  requires a hand-rolled `NWConnection` HTTPS client and silently excludes devices without
  cellular data.
- **Pre-shoot nudge only** — doesn't help on set; may be added later independently.

## Flow

1. **Entry**: the RED download screen's `blockedOnCameraAccessPoint` state gains a primary
   "Download over internet" action with the sub-line "We'll hop off the camera's Wi‑Fi to
   download, then reconnect your camera automatically."
2. **Hop** (`NativeAppModel.beginRedLUTInternetHop()`): stash the camera SSID, tear down the PTP
   session, stop the discovery loop (nothing may re-apply the camera network mid-download), and
   call `WiFiJoinCoordinator.leaveCameraNetwork(ssid:)` →
   `NEHotspotConfigurationManager.removeConfiguration(forSSID:)`. iOS drops the AP and falls back
   on its own.
3. **Unblock**: no new download path — `InternetReachability` is observable, so the screen
   reactively swaps from blocked → normal download UI when the path becomes `.available`.
   While waiting, the blocked card shows a "Switching networks…" progress row. If internet never
   arrives, the state settles into the existing `.blockedNoInternet` copy; backing out triggers
   the return path.
4. **Return** (`NativeAppModel.endRedLUTInternetHop()`, fired on RED screen dismiss when a hop is
   active): arm the paired-reconnect machinery — `pendingPairedReconnectHost`/`SSID` with
   `pairedReconnectSawCameraLeave = true` — and restart discovery. It re-applies the camera
   network (throttled 5 s) and auto-connects when the camera answers, in the connection popup's
   white-card language.

## Error handling

- **No internet after the hop**: screen shows `.blockedNoInternet`; user backs out → return path
  rejoins the camera network.
- **Join alert declined / camera off on return**: the saved-cameras home shows the camera with
  its normal Connect recovery. No new failure surface.
- **Known trade**: removing the hotspot configuration forgets iOS's join approval, so the
  "Wants to Join" alert may reappear on return; the reconnect popup copy already instructs the
  operator to tap Join.

## Scope

Shell-only glue (~3 files): `WiFiJoinCoordinator` (leave), `NativeAppRoot` (begin/end hop),
`RedDownloadView` (blocked-state action + switching row). Core `RedLUTDownloadPolicy` and its
tests are already the decision surface and stay unchanged.
