# Streaming architecture

The networking backend for the monitor: the camera live view one device pulls, and the relay
that serves that picture to every other screen on set. This is the design record — what the
system is, the invariants that keep it correct, what was measured, what was considered and
rejected, and the documented upgrade paths. Written 2026-08-01, after the relay/HEVC/handoff
arc and the streaming overhaul (`5bddeb7`, `321ac95`).

## Topology

```
Camera ── PTP/IP or USB ──> Broadcaster ── TCP (length-prefixed) ──> Viewer A
   (one initiator, ever)        │  one HEVC encode, fan-out          Viewer B …
                                └── Bonjour _openzcine-mon._tcp
```

- **One camera, one initiator.** PTP-IP serves a single session and every install presents the
  same identity; a second screen exists only by relaying. This is a camera-protocol fact, not a
  design choice, and it makes the broadcaster the root of every stream.
- **The relay is a co-located SFU.** One hardware HEVC encode; per-viewer send queues with
  independent drop. This is the selective-forwarding topology (RFC 7667 §3.7) with the encoder
  living beside the "middlebox". Per-viewer encoders were rejected: N hardware sessions on a
  phone that is already decoding the camera stream buys nothing when every viewer wants the
  same picture, and costs the thermal budget the camera link depends on.
- **Control is proxied, never transferred.** A viewer that "takes control" is the app agreeing
  whose commands the broadcaster executes on its own session — the camera link never moves.
  Requests prompt on the broadcaster's live view; the host reclaims unilaterally.

## Invariants

1. **Newest frame or no frame.** A viewer that stops draining is skipped, never queued for
   (`maxInFlightFramesPerPeer = 2`: one on the wire, one behind it). Fire-and-forget sends
   buffer without bound and present as minutes of latency; a monitor must never do that.
2. **Reference-chain discipline.** Every skip breaks that viewer's HEVC reference chain, so a
   skipped or joining peer receives nothing until a keyframe. The host tracks `needsKeyframe`
   per peer; the encoder latches requests and honors them at most once per second (deployed
   keyframe-coalescing practice — a keyframe is 3–8× a P-frame, and a chronically slow viewer
   must not turn the stream keyframe-heavy for everyone else).
3. **Never pay for what nobody receives.** All viewers saturated → the encode itself is
   skipped. Because nothing was encoded, the encoder's reference chain stays exactly where
   every viewer's is — resuming needs no keyframe.
4. **Bitrate follows the slowest viewer that should keep up.** Sustained saturation steps down
   a 6 → 4 → 2.5 Mb/s ladder; recovery climbs one rung after 30 clean seconds
   (`RelayBitrateAdaptation`, pure and tested). Degradation is prompt, recovery deliberate —
   oscillation reads worse on a monitor than a steady, slightly softer picture.
5. **Quality floor, not quality mush.** `MaxAllowedFrameQP = 45`: a bitrate sag drops frames
   rather than smearing the picture into something an operator would misread as a focus
   problem.
6. **A viewer session explains itself and heals itself.** Failures surface their reason on the
   empty feed (never a bare FAIL chip over a frozen frame); a watchdog rejoins as soon as the
   broadcast is visible again and tears through connected-but-stalled links.
7. **The radio is part of the budget.** Peer-to-peer (AWDL) advertising time-slices the same
   radio the camera stream and every viewer flow ride (third-party measurements: 30–100 ms
   locks about once a second). The host advertises peer-to-peer ONLY when the camera occupies
   its Wi-Fi (camera-AP session — the one case with no infrastructure path). Every relay
   connection is marked `.interactiveVideo` so the sender's own uplink schedules it in the
   Wi-Fi video access class.
8. **Polls never outrank the picture.** On the camera link, every between-frames poll is a
   round trip the next frame queues behind; `LiveViewPollPacing` scales poll cadence by the
   measured round trip so a fixed stride cannot become a periodic hitch on a high-RTT (router)
   path. Operator-announced changes keep their fast cadence regardless.

## Scaling model

Broadcaster cost per additional viewer: one TCP socket, ≤2 in-flight frame buffers, and the
send syscalls — the encode is shared. The bounded resource is the broadcaster's Wi-Fi
**airtime**: at 6 Mb/s HEVC, N viewers cost ~6N Mb/s of uplink (every relayed frame crosses
the air once per viewer on infrastructure). On a healthy 5 GHz channel that supports a handful
of viewers; when it doesn't, saturation trips the bitrate ladder and the stream fits itself to
the channel. The protocol never fans out at the transport level (no multicast — consumer
Wi-Fi multicast rates make it worse than unicast fan-out at this scale).

## Considered and rejected (with reasons)

- **QUIC / Media-over-QUIC.** MoQT is an IETF draft (draft-19, 2026-07) aimed at relay/CDN
  scale; Network.framework QUIC requires TLS 1.3 with self-provisioned certificates for LAN
  peers. TCP head-of-line blocking only bites after Wi-Fi MAC retries give up — rare on a
  clean channel, bounded by the 2-in-flight cap (~66 ms of video), healed by keyframe-on-
  resume. Upgrade path if hardware testing shows recurring RTO-class (~100–200 ms) stalls
  through the actual travel router: one QUIC stream per frame via NWMultiplexGroup, so a lost
  frame never stalls the next. Measure first.
- **HEVC low-latency rate control.** `EnableLowLatencyRateControl` is documented for the
  H.264 hardware encoder; Apple has never stated HEVC support. Its wins (encoder queue depth,
  rate-controller reaction) don't survive the codec swap, and switching the relay to H.264
  costs the bitrate advantage that motivated HEVC. Revisit only with measured glass-to-glass
  numbers demanding it.
- **Temporal layering / LTR frames.** Both are documented for H.264 low-latency mode only.
  Their payoff (a slow viewer drops enhancement frames without forcing keyframes on everyone)
  matters with a chronically slow viewer in the fleet; the adaptive ladder covers today's
  scale. Documented upgrade path, not built.
- **Per-viewer encoders.** N× hardware sessions and power for identical content. No.
- **JPEG pass-through as the primary stream.** No generational loss, but ~20 Mb/s at 25 fps
  capped set-router viewers at 8–11 fps. Survives as the wire fallback (`FrameCodec.jpeg`)
  when the encoder is unavailable — a heavier picture, never no picture.
- **Relay authentication.** Deliberately absent (operator decision): a set LAN is treated as
  trusted. Revisit before any non-LAN transport.

## Multicam trajectory

The pieces this backend already gives a future multicam feature: multiple broadcasters coexist
on one Bonjour type today (every broadcasting device is one service); a viewer joins any of
them; control tokens are per-host. A multicam switcher is, structurally, a viewer that joins
several hosts at once and presents a quad-split — the wire needs nothing new for picture. What
it WOULD need: per-host decode sessions on the switcher (N × VTDecompressionSession — cheap),
bitrate requests per subscription (the ladder is currently broadcaster-global; a switcher
wanting thumbnails would motivate per-peer target hints in a `hello` extension), and program/
preview tally back-channel (a trivial new message kind). The protocol version field gates all
of it.

## Verified vs pending hardware

Everything above is verified on simulators/emulator except: real-router stutter improvement
(the poll-pacing mechanism is measured, the feel needs the actual Ubiquiti), AWDL-off
smoothness gain, `.interactiveVideo` effect through the travel router, adaptive-ladder
behavior under genuine congestion, and camera-AP relay reach over AWDL (unproven on hardware
since the relay's first commit). Android: the relay (broadcast + view) is iOS-only today —
tracked divergence; `LiveViewPollPacing` lives in shared core ready for the Android facade's
pump when its live-view path grows the same RTT exposure.
