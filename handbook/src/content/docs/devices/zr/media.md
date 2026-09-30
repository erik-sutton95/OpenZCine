---
title: ZR original media
description: Storage and object operations, RAW masters and proxies, proxy timecode, ratings and still-size classes on the Nikon ZR.
---

Part of the [Nikon ZR reference](../).
Read the overview for firmware, survey scope and evidence levels.

## Storage and object listing

Media travels over the same PTP session as control and live view; there is no
separate HTTP or file service. The shared transfer layer is described in
[Media transfer](../../../protocol/media/).

| Step | Operation | ZR notes |
| --- | --- | --- |
| Cards | `GetVendorStorageIDs` `0x9209` | Returns only card-present storage IDs. **Observed:** standard `GetStorageIDs` (`0x1004`) reports placeholder per-slot IDs even with a card inserted, and `GetStorageInfo` rejects those. |
| Capacity | `GetStorageInfo` `0x1005` | Free space for the remaining-time estimate; refreshed every 15 s during a take. |
| Objects | `GetObjectHandles` `0x1007` | Per storage. Handles are only unique per storage and are recycled after a format. |
| Metadata | `GetObjectInfo` `0x1008` | Filename, format code, size, dimensions and capture date. |
| Thumbnail | `GetThumb` `0x100A` | Embedded JPEG. |
| Bytes | `GetPartialObject` `0x101B`; `GetPartialObjectEx` `0x9431` for large objects or ranges | The Ex form packs offset and maximum byte count as low/high UINT32 words. `[verify-on-HW]` |
| Size | `GetObjectSize` `0x9421` | One little-endian UINT64. `[verify-on-HW]` |
| Delete | `DeleteObject` `0x100B` | Protected objects are refused. |

Object identity in the app is the (storage ID, handle) pair, confirmed against
filename, capture date and size. In backup mode one shot lands on both cards as
two objects that share a filename. A cached library only fetches
`GetObjectInfo` for new or changed locations.

Movies are classified by object format code (QuickTime `0x300D`, MTP MP4
`0xB982`, AVI `0x300A`, MPEG `0x300B`) or by extension. `[ZR · verify-on-HW]`:
the ZR's own movie format codes and clips of 4 GiB or more.

## RAW masters and proxies

When the ZR records R3D NE or N-RAW it writes a proxy MP4 or MOV beside the
master. The media browser pairs a proxy with its sibling `.R3D` master by
filename stem
([`R3DClipIndex.swift`](https://github.com/erik-sutton95/OpenZCine/blob/main/Sources/OpenZCineCore/R3DClipIndex.swift)).
Proxies play in the progressive player; an unpaired RED master stays
intentionally non-previewable.

The resolution filter prefers the linked master's dimensions. Those come from
the leading bytes of the `.R3D` file: the `RED1` atom layout (big-endian UINT32
width and height at offsets 52 and 56), with a legacy fallback.
`[ZR · verify-on-HW]`: the ZR's on-card R3D NE header layout.

### Proxy timecode

**Observed** on a real ZR proxy: the camera writes master and proxy from one
timecode generator, so the proxy's own `tmcd` track is the master's start
timecode. The inspected proxy was an MP4 with brand `mp42avc1niko` at 25 fps.

Byte-for-byte deliveries keep that track. LUT-baked exports transcode, which
drops it, so iOS copies the source timecode track back into the finished file
without re-encoding
([spec](https://github.com/erik-sutton95/OpenZCine/blob/main/docs/specs/proxy-timecode-embed.md)).
A timecode failure never fails the delivery. Still open: a manual check that a
real baked and uploaded ZR clip shows the master's start timecode in Frame.io.

**Observed (field reports):** some Nikon proxies have media data shorter than
the header declares. AVFoundation export then failed with `Invalid sample
cursor`. Export now strips the camera timecode track before the export session
and restores it afterwards, and treats the short read as end of readable media
so the file is finished and playable.

## Stills

| Topic | ZR notes |
| --- | --- |
| Formats | JPEG, HEIF, NEF and TIFF appear as format chips. JPEG and PNG may decode while their cache grows; HEIF and TIFF wait for a complete cache. |
| Size classes | L, M and S are ranked among the widths present in the listing, not fixed thresholds: L is 6048 px on a ZR, Z 6III or Z5II but 8256 px on a Z8. More than three distinct widths leaves stills unclassified. |
| Ratings | Object property `0xDC8A` via `GetObjectPropValue` / `SetObjectPropValue` (`0x9803` / `0x9804`). Steps `0`, `1`, `25`, `50`, `75`, `100` map to Off through five stars; off-step values round down. The instant-playback favorite star writes here. |
| Bursts | Continuous-drive frames group into one stack that spans both cards. |
| Body-fired shots | `ObjectAdded` (`0x4002`, one per file, so RAW+JPEG emits two) and `CaptureComplete` (`0x400D`) arrive from the event poll and drive instant playback. |

## Live monitoring stream versus originals

The live-view JPEG is a monitoring preview, not a recording. Its size and
compression are set by `LiveViewImageSize` (`0xD1AC`) and
`LiveViewImageCompression` (`0xD1BC`); both are unrelated to the recording
format. During a take the preview is capped at VGA and steps down further under
phone thermal pressure. See [Live view](../../../protocol/live-view/).
