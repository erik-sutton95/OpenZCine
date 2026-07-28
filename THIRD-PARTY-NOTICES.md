# Third-party notices

OpenZCine is licensed under the [Apache License 2.0](LICENSE). It distributes the following
third-party software, reproduced here with their required license texts, and the
community-contributed material recorded below.

## ZIPFoundation

- **Homepage:** <https://github.com/weichsel/ZIPFoundation>
- **Version:** 0.9.20 (pinned in `ios/Runner.xcodeproj` via Swift Package Manager)
- **Used for:** unpacking downloaded LUT preset archives in the iOS app
- **License:** MIT

```text
MIT License

Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## "R3D NE Monitor" built-in look — contributed by Wang Yuehua

- **Contributor:** Wang Yuehua, credited in the app's LUT picker beside the look itself
- **What it is:** a monitoring LUT for R3D NE footage, authored by the contributor and offered for
  inclusion in OpenZCine's Built-in look category
- **Permission:** included with the author's permission, given on 2026-07-18 in reply to a direct
  request to ship it as an option in the built-in category with full credit. Permission was granted
  in conversation; no formal license was exchanged, so none is named here
- **As shipped:** the contributor's file is a 65³ `.cube`; OpenZCine ships it at 33³, matching every
  other built-in look. Because 65 = 2·32 + 1, each 33³ lattice point falls on an exact source index
  (stride 2), so the shipped samples are the author's own values with no interpolation — but anyone
  comparing against the original should know the grid differs
- **Where it lives:** the table is embedded in the shared Swift core as a base64 UInt16 blob
  ([`Sources/OpenZCineCore/MonitorLUTContributedTable.swift`](Sources/OpenZCineCore/MonitorLUTContributedTable.swift)),
  regenerated from the source `.cube` by
  [`scripts/generate-builtin-lut-table.rb`](scripts/generate-builtin-lut-table.rb). The `.cube` file
  itself is not committed — see [`docs/commit-hygiene.md`](docs/commit-hygiene.md)

## Protocol references (not distributed)

Nikon PTP/MTP property and operation codes were cross-checked against the
[libgphoto2](https://github.com/gphoto/libgphoto2) project's public protocol tables as a reference.
No libgphoto2 source code is included in or distributed with OpenZCine.

No Nikon SDK or proprietary Nikon documentation is included in, distributed with, or required by
this project (see [NOTICE](NOTICE) and [`docs/nikon-sdk.md`](docs/nikon-sdk.md)).
