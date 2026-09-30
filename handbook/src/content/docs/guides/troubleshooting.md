---
title: Troubleshooting
description: Discovery, pairing, camera Wi-Fi, USB-C, live view, camera settings and delivery.
---

Discovery, pairing and live view need a **physical** phone or tablet and the
camera. The iOS Simulator can only run the demo session
([Setup](../setup/#run-without-a-camera)).

If a step fails, open **Operator Setup → System → Report a Problem**. Choose an
anonymous public issue (no GitHub account; optional privacy-filtered activity
events and screenshots you pick) or a signed-in
[GitHub bug report](https://github.com/erik-sutton95/OpenZCine/issues/new?template=bug_report.yml)
for richer details. Both paths are public. For a local diagnostic export, use
**Settings → Share Diagnostics**: it keeps a connect-attempt trace on the phone
(body family, whether DeviceInfo was read, the pairing decision) until you send
it. The same guide for operators is on the
[support center](https://opencapture.org/openzcine/support/).

:::caution[Keep reports clean]
Never post camera Wi-Fi keys, pairing codes, private media or security
vulnerabilities in an issue. Screenshot metadata is removed, but visible content
can still identify someone. Security issues follow
[`SECURITY.md`](https://github.com/erik-sutton95/OpenZCine/blob/main/SECURITY.md).
:::

## Camera does not appear

Put the camera on its Wi-Fi connection screen, or connect a **data-capable**
USB-C cable. Then check the path you chose:

- **Camera Wi-Fi:** the phone must be on the exact network the camera shows.
  OpenZCine can scan the network name and key from the camera screen, or you
  can type them.
- **Router:** phone and camera must be on the same network. On iOS, after two
  empty search passes, the app offers manual entry of the camera address.
- **Personal Hotspot:** the camera joins the phone's hotspot; the phone hosts
  and waits for the camera to appear.
- **USB-C:** allow camera accessory access when iOS asks, or approve the USB
  prompt on Android.

On iPhone and iPad, allow **Local Network** access. Without it the app cannot
reach the camera on any Wi-Fi path. Android asks for **Nearby Wi-Fi devices**
or **Location** to see networks, and **Camera** only for the Wi-Fi scanner.

A device with no working camera, such as a field monitor, can always type the
camera Wi-Fi name and key by hand.

## Pairing never finishes

Keep the Nikon pairing screen visible and accept the confirmation on the camera.
After you confirm on the body, the camera restarts its network and the app
reconnects with the saved profile, so a short pause there is expected.

If the camera was paired with an earlier install or another device, remove the
saved camera in OpenZCine, clear the old pairing entry on the camera, and pair
again.

## Original Z 5, Z 6, Z 7 or Z 6III shows a wireless error

Original Z 5, Z 6, Z 7 and Z 50 bodies have no pairing handshake. Earlier builds
could send pairing steps anyway and leave a wireless error on the camera while
the app kept connecting. Current builds pick the right path from the camera's
own operation list, or from its network or USB product name when that list is
missing. A Z 6III is no longer mistaken for an original Z 6. If a Z 6III still
fails, send **Share Diagnostics**. Details:
[original Z bodies](../../devices/gen-1/connection/) and
[Z 6III](../../devices/z6iii/connection/).

## Live view stalls or drops frames

Move closer to the camera or access point, reduce network congestion, and pick
a lighter **Stream Preset** under **Settings → Link**. Link Health on that page
shows the rate the link is actually carrying. A weak link lowers the picture
quality instead of dropping the session.

Recording adds camera load, so OpenZCine deliberately reduces non-essential
polling during a take and caps the preview (never the recording). The preview
also steps down when the phone gets hot. If the session drops, the monitor holds
the last frame, clearly marked as held, while a bounded reconnect runs. When it
gives up you get **Retry connection** and **Operator menu**.

## USB-C does not reconnect

Current builds reconnect after the cable is knocked loose, or after a few
seconds in the background, without force-quitting the app. Use a data-capable
cable. If an Android phone reports that a USB write failed on reconnect, the app
now resets the camera's USB pipe and retries once on the same attempt.

Wi-Fi and USB-C are separate setups of the same camera. Disconnect before
switching between them.

## A camera setting will not change

Nikon allows some values only in specific exposure, focus, codec or recording
modes. Pickers offer the values the connected camera advertises, in its order,
and a change counts only after the camera reads it back. Firmware and transport
differences can still reject a write. Confirm the mode on the camera and try the
change there; include the camera model, firmware and exact mode in a bug report.

Resolution, codec and stabilization writes are still being verified across real
Nikon ZR configurations. See [ZR coverage](../../devices/zr/coverage/).

## Frame.io is unavailable

If **Settings → Storage** says the feature is not set up in this build, that
build has no Frame.io credentials. Otherwise sign in before the shoot. Upload
needs internet: on camera Wi-Fi, approve the temporary internet hop. The app
leaves the camera network, delivers, then rejoins the camera.

## Share or Save to Photos fails

Earlier iOS builds could fail with "Invalid sample cursor" on camera clips,
including proxies whose media is shorter than the header. Current builds finish
those exports. Save to Photos asks for library access before the long export,
then shows a spinner while Photos writes. You do not have to disconnect the
camera first.

## Cached media uses too much space

Open **Settings → Storage** and clear the cache. This removes cached clip data
and thumbnails and keeps favorites, upload history and the media index.

## Android: sideload APK will not install

Devices without Google Play, including field monitors, install the sideload APK
from [GitHub Releases](https://github.com/erik-sutton95/OpenZCine/releases). It is
one arm64 package for Android 10 and newer. A copy installed from Google Play or
an APK mirror is signed by Google and cannot be updated by the sideload APK.
Remove it first, then install.
