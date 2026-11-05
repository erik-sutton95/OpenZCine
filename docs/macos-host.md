# Mac Catalyst monitor and virtual webcam

The Mac candidate keeps the native Catalyst monitor and uses a separate signed
macOS companion to install the Core Media IO camera extension. This is a local
Mac implementation under qualification, not a published release.

## Picture and control

Choose the camera connection for control independently from the picture source.
For HDMI, connect a compatible UVC capture device, select HDMI as the picture
source, and explicitly select that device and an advertised 1080p30 or1080p60
mode. The Mac never substitutes its built-in camera or its own virtual webcam.
Wireless Nikon control uses the network selected in macOS; the Mac does not claim
to have joined a camera access point automatically. Losing that control connection
must leave the independent HDMI capture owner alive.

The Catalyst HDMI path keeps native pixel buffers through preview and the clean
webcam look. Scope and relay analysis use bounded, sampled work. Source replacement
fences delayed callbacks, and slow webcam clients cannot create a frame backlog.
The virtual output includes the selected LUT look and excludes monitor overlays.

## Virtual webcam

Install both signed applications in Applications. Open OpenZCine Camera, choose
Install / Update, and approve the camera extension through macOS when prompted.
Then enable OpenZCine Camera under Operator Setup, Sharing. Receiving applications
select the camera named OpenZCine. Output is1920x1080 BGRA at negotiated30 or60fps;
slower inputs produce counted repeated frames. A missing picture produces a slate.

See [the companion guide](../macos/README.md) for identifiers, signed bundle
validation, bounded ownership, lifecycle operations and verification limits.
Extension activation proves installation only. A successful producer connection
and received frames must also be checked before claiming a working webcam.

## Build and qualification

Use the workspace heavy-command wrapper around `just macos-build`,
`just macos-camera-build`, `just macos-camera-test` and the publisher test script.
Keep derived data and package scratch on the approved external build volume.
Run `just check` and `just native-check` for the app, and the shared-platform
verification and propagation checks for any OpenCine changes.

This task adds Mac-only platform adapters and optional shared host values.
iOS defaults remain unchanged and Android has no corresponding Core Media IO
extension API. OpenPocketCine and OpenInstaCine need no Mac UI adoption; their
shared-Core pins and consumer checks remain separate integration gates. The Mac
candidate currently builds against the paired local Core worktree.

The actual HDMI capture chain, wireless-control independence, sustained frame
pacing, receiving-client compatibility and long-running memory/GPU behavior
remain untested until recorded against physical hardware. Compile-only and
synthetic ownership checks do not satisfy those acceptance criteria.
