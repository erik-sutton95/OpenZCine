# Live audio monitoring — feasibility note (Nikon ZR)

**Status:** Not feasible over PTP-IP live view as of 2026-07-01. OpenZCine does not fake playback.

## Question

Can the iOS app play camera-captured audio to headphones (e.g. AirPods) while live-view
monitoring?

## Verdict

**No.** The remote live-view path delivers a JPEG preview frame plus a metadata header. It does
not expose a PCM, AAC, or other encoded audio stream the host could decode and route through
`AVAudioEngine` / `AVAudioSession`, and the camera reports no PTP v1.1 streaming support
(`GetStream` / `GetStreamInfo` are absent from its supported-operations list).

What *is* available is **metering metadata only**: the live-view frame header carries L/R
peak/current level indicators (0–14), and PTP device properties cover mic *configuration*
(sensitivity, attenuator, wind filter, input selection) — recording settings, not program audio.

Program audio physically leaves the camera only via the body headphone jack and the HDMI output;
neither is reachable over PTP-IP.

## Reasonable alternatives (no fake audio)

| Alternative | Notes |
| ----------- | ----- |
| **On-camera headphones** | ZR body headphone jack — zero app latency, full quality. |
| **VU meters in-app** | Draw L/R meters from the live-view header level indicators during live view / recording. Visual only. |
| **Clip playback** | Already implemented via `MediaPlaybackAudioSession` + `AVPlayer` for recorded clips on card. |
| **HDMI / external monitor** | Tap program audio from the HDMI output or a dedicated wireless video+audio link (NDI, etc.). |

A useful vendor feature request would be remote live-view audio monitoring over PTP-IP — either a
companion audio stream or an optional encoded-audio chunk in the live-view payload. Until
something like that exists, the only in-app affordance is visual VU meters.
