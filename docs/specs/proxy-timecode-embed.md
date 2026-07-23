# Feature Spec: Source Timecode in Delivered Proxies

## Status

In Progress

## Priority

P1

## User Stories

1. As a **camera operator**, I want proxies I upload to Frame.io to carry the R3D NE / N-RAW
   start timecode, so that review comments and conform line up with the master clips in the NLE.
2. As a **camera operator**, I want LUT-baked share exports to keep the same timecode as the
   camera originals, so that graded dailies stay conformable.

## Acceptance Criteria

- [x] LUT-baked exports (Share and Frame.io) contain a `tmcd` timecode track whose start value,
      frame quanta, and flags match the source proxy's track exactly.
- [x] Sources without a timecode track export exactly as before (no track invented).
- [x] A timecode-embed failure never fails the delivery — the clip uploads without TC, as today.
- [ ] Manual: a real ZR clip baked + uploaded shows the master's start TC in Frame.io.

## Technical Design

### Overview

The camera writes the R3D NE / N-RAW master and its proxy MP4 from the same timecode generator,
so the proxy's own embedded `tmcd` track *is* the master's timecode (verified on a real ZR proxy:
`samples/A002_C057_0704BT.MP4`, brand `mp42avc1niko`, start TC `03:40:28:02` @ 25 fps). Delivery
paths that copy the cached proxy byte-for-byte already preserve it. The LUT-bake path transcodes
through `AVAssetExportSession`, which only carries video and audio and drops the track.

Fix: after the transcode branch in `MediaLUT.export`, copy the source's timecode track into the
finished output in place with `AVMutableMovie.insertTimeRange(_:of:at:copySampleData:)` — a
4-byte sample append plus a rewritten moov, no re-encode. Proven end-to-end against the real
sample (transcode → track gone; embed → `ffprobe` reads `03:40:28:02` again, byte-perfect).

R3D NE / NEV header parsing was considered and rejected: unnecessary (the proxy carries the TC)
and unverified reverse-engineering (FFmpeg's r3d demuxer does not parse TC).

### Components Affected

- `ios/Runner/MediaTimecode.swift` — new: best-effort timecode-track copy helper.
- `ios/Runner/MediaLUTExport.swift` — call the helper after the transcode branch.
- `ios/RunnerTests/MediaTimecodeTests.swift` — new: synthesized-source roundtrip test.

### Data Flow

Cached camera proxy (has `tmcd`) → `MediaLUT.export` transcode (drops `tmcd`) →
`MediaTimecode.copySourceTimecodeTrack` re-embeds from the cached proxy → Share / Frame.io upload.

### API / Interface Changes

```swift
enum MediaTimecode {
    /// Best-effort; no-ops when the source has no timecode track, logs on failure.
    static func copySourceTimecodeTrack(
        from sourceURL: URL, to outputURL: URL, as fileType: AVFileType) async
}
```

## Edge Cases

| Scenario | Expected Behavior |
| --- | --- |
| Source proxy has no `tmcd` track | Helper no-ops; export identical to today |
| Embed fails (I/O, malformed output) | Log via `os.Logger`; delivery continues without TC |
| Passthrough copy path (no bake) | Untouched — byte copy already preserves the track |
| `.mp4` export format | `tmcd`-in-MP4 is Nikon's own convention (the ZR writes it); embed normally |
| Android delivery | Uploads camera originals as-is; TC already preserved, no change |

## Testing Plan

### Unit Tests

- `RunnerTests/MediaTimecodeTests` — writes a tiny movie with a known `tmcd` track
  (`AVAssetWriter`, frame 330702 @ 25 fps = `03:40:28:02`), runs it through the
  `MediaLUT.export` transcode branch, asserts the output's timecode track start frame and
  frame quanta survive.

### Manual Verification

- [ ] Bake + upload a real ZR clip; confirm Frame.io shows the master's start TC. [ZR · verify-on-HW]

## Open Questions

None.
