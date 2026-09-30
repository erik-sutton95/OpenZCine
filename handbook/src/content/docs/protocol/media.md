---
title: Media transfer
description: Card listing, object info and thumbnails, resumable partial reads, delete and star rating, proxies and R3D masters, and the LUT-baked export path.
---

Clips and stills come off the card over the same PTP session as control and
[live view](../live-view/). There is no HTTP server on the camera. Every read
is a bounded transaction behind the single command gate, so a large download
shares the channel with the monitor.

## Listing

| Step | Operation | Notes |
| --- | --- | --- |
| Storages | `GetVendorStorageIDs` (`0x9209`) | Card-present IDs only. Standard `GetStorageIDs` reports placeholder slots that `GetStorageInfo` rejects |
| Capacity | `GetStorageInfo` (`0x1005`) | Maximum capacity and free bytes |
| Objects | `GetObjectHandles` (`0x1007`) | Per storage. The format filter is only a hint [verify-on-HW] |
| Metadata | `GetObjectInfo` (`0x1008`) | Filename, compressed size, width, height, capture date |
| Thumbnail | `GetThumb` (`0x100A`) | Embedded JPEG |

Format filter hints: movies `0x300D` (QuickTime), `0xB982` (MP4), `0x300A`,
`0x300B`; stills `0x3801` (JPEG), `0x380D`, `0x3811`, `0x380B`. NEF, HEIF and
R3D use vendor codes that are not mapped, so a wrong guess must never blank a
tab.

Camera filenames are **untrusted network input**. The core accepts one
filesystem-safe basename and rejects path components and control characters
before the app stores, opens or deletes anything by that name
([`MediaClipFilename.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/MediaClipFilename.swift)).

With backup recording the same filename lands on both cards as two objects.
The library keeps one row per filename that carries every card location.

## Reading an object

Reads go through a resumable cursor in the core (`PTPObjectTransfer.swift`):

| Operation | When |
| --- | --- |
| `GetObjectSize` (`0x9421`) | 64-bit size for large objects [verify-on-HW] |
| `GetPartialObject` (`0x101B`) | Offset and length fit in 32 bits |
| `GetPartialObjectEx` (`0x9431`) | Larger objects or ranges; offset and length as low/high words [verify-on-HW] |

Requests default to **4 MiB**, trimmed to the bytes remaining. A resumed
download starts from the bytes already cached and verified. Playback starts
while the cache grows. JPEG and PNG stills may decode progressively; HEIF and
TIFF wait for a complete cache.

## Delete and star rating

| Action | Operation | Notes |
| --- | --- | --- |
| Delete | `DeleteObject` (`0x100B`) `p1` handle | The body refuses protected objects [verify-on-HW] |
| Read rating | `GetObjectPropValue` (`0x9803`) `p1` handle, `p2` `0xDC8A` | `u16` |
| Write rating | `SetObjectPropValue` (`0x9804`) | Values `0`, `1`, `25`, `50`, `75`, `100` for off through five stars [verify-on-HW] |

A RAW still does not carry the rating; the JPEG or HEIF side of a pair does.
The app's favorite star writes this rating to the card.

## Proxies and R3D masters

A ZR recording R3D NE writes a playable proxy (MP4 or MOV) beside the `.R3D`
master with the same filename stem. The listing pairs them by stem, case
insensitive
([`R3DClipIndex.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/R3DClipIndex.swift)):

| Object | Browser action |
| --- | --- |
| MOV, MP4 or M4V proxy | Progressive player |
| Master with a proxy | Hidden behind the proxy |
| Master without a proxy | Listed, not previewable |
| JPEG, HEIF (`.HIF`), NEF | Photo viewer |

Frame dimensions of a master can be read from its leading bytes (`RED1` atom);
the ZR's on-card layout is [verify-on-HW]. Both apps consume this one shared
policy instead of classifying filenames themselves.

## Export and delivery

Share, Save to Photos and Frame.io upload export from the cached clip,
optionally with the selected LUT baked in. On iOS:

1. Build a composition of video and audio only. Nikon proxies carry a
   per-frame QuickTime timecode track (`tmcd`), and feeding it to the export
   session fails with an invalid sample cursor error.
2. Bake the LUT with the same color-cube pipeline as the live view, in half
   float, through `AVAssetReader` and `AVAssetWriter`.
3. Copy the source's timecode track back into the finished file, byte for byte,
   so an editor can conform the proxy to its master. A missing track never
   fails a delivery.
4. When a proxy's media data is shorter than its header claims, treat that as
   the end of readable media and finish a playable file.

Code: `ios/Runner/MediaLUTExport.swift`, `ios/Runner/MediaTimecode.swift`.
Android has its own export path with the same options. Frame.io upload uses
OAuth with PKCE and needs internet; from the camera access point the app can
hop to an internet connection, deliver, then reconnect the camera. Setup for
contributors: [Frame.io setup](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/frameio-setup.md).

Do not put camera filenames, paths or card contents that identify people into
issues.
