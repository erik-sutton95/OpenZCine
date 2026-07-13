# Third-party notices

OpenZCine is licensed under the [Apache License 2.0](LICENSE). It distributes the following
third-party software, reproduced here with their required license texts.

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

## Protocol references (not distributed)

Nikon PTP/MTP property and operation codes were cross-checked against the
[libgphoto2](https://github.com/gphoto/libgphoto2) project's public protocol tables as a reference.
No libgphoto2 source code is included in or distributed with OpenZCine.

No Nikon SDK or proprietary Nikon documentation is included in, distributed with, or required by
this project (see [NOTICE](NOTICE) and [`docs/nikon-sdk.md`](docs/nikon-sdk.md)).
