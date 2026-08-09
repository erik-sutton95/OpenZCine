# Wireless transport audit — dropouts and low fps on the router path

Field report (2026-08-03): constant dropouts and low fps in every wireless mode, worst on
Router, unusable regardless of stream preset / quality bias. This audit maps the complete
wireless live-view path, names the mechanisms, and records what shipped versus what is
deliberately deferred. Relay/sharing is out of scope here (it has its own architecture doc).

## The path, in one paragraph

PTP-IP over two raw BSD TCP sockets (command + event, port 15740, `PTPIPTransport`). Every
operation — live-view frames, event polls, property reads/writes, media chunks, keep-alive —
is one strictly serial transaction on the command socket behind a FIFO gate. The frame loop
(`streamUntilStall`) pulls `GetLiveViewImageEx` as fast as the chain completes; there is no
target fps and no pacing sleep. Between frames, `LiveViewPollPacing` schedules `GetEventEx`
and property round-robins at frame-count strides scaled by measured RTT. The stream preset
and quality bias each change exactly one camera-side byte (`LiveViewImageSize`,
`LiveViewImageCompression`). Frame deadlines: 10 s for the first frame, 6 s steady-state —
enforced by closing the command socket, because a blocked socket read cannot be cancelled.

## Root causes found

### Dropouts: congestion becomes disconnection by design

A frame slower than the 6 s deadline doesn't fail the frame — it **closes the command
socket** (the only way to unwedge an uncancellable read), which kills the session and
surfaces as "The camera closed the connection", then recovery reconnects and the cycle
repeats. On a weak/congested field router, a static quality setting parks frame times near
the cliff and every gust of interference tips one over. The presets didn't help because no
preset changes the *deadline* dynamics — a slow link needs the stream to get smaller, and
nothing made it smaller.

**Shipped:** `LiveViewAdaptiveQuality` (core, tested) — an EWMA over inter-frame intervals
steps the requested `LiveViewImageSize` down (≥8 s between steps) when the stream sustains
>0.45 s intervals or spikes past 2.5 s, and back up toward the operator's preset after 45 s
of sustained health. The operator's preset is a ceiling, never overridden upward;
compression is untouched (size-priority compression is known-bad on hardware). The cap is
applied through the same out-of-loop seam thermal step-down already uses, so no new restart
machinery. Congestion now degrades the picture instead of dropping the session.

### Low fps: serial wire-and-CPU, noisy pacing, per-frame churn

1. **Fetch and decode never overlapped.** The loop awaited the frame, decoded, baked,
   published, and only then requested the next frame — on a router path where fetch RTT
   dominates, the decode/bake time was a dead 10-25 % fps tax. **Shipped:** the next fetch
   now starts before decode; peak cost is one extra in-flight JPEG (~100 KB). The wire
   stays strictly serial (the camera never sees overlapped operations).
2. **RTT was measured from the frame fetch itself** — a single unsmoothed sample including
   the whole JPEG transfer, overwritten per frame. Poll pacing (stride 4↔20) flapped on
   single frames and reacted to picture size as if the link had slowed. **Shipped:** RTT is
   EWMA-smoothed (α=0.25) and sampled only from small commands (`GetEventEx`, keep-alive).
3. **A reachability monitor was constructed per view re-init** (`@State … =
   InternetReachability()` in the LUT panel and RED download view). Every monitor chrome
   re-render — i.e. every frame while those were mounted — started an `NWPathMonitor` and
   fired a nehelper XPC, the exact "invalid result code" log spam from the field. This is
   also a plausible contributor to the felt UI jitter. **Shipped:**
   `InternetReachability.shared`; per-view construction is banned and documented on the
   class.
4. **Socket-layer gaps:** no `SO_NOSIGPIPE` (the Android facade sets it; iOS had diverged),
   no receive-buffer tuning for ~100 KB bursts, and a fresh zero-filled 256 KiB buffer per
   `recv` (tens of MB/s of allocator/memset churn at streaming rates). **Shipped:**
   `SO_NOSIGPIPE`, `SO_RCVBUF` = 512 KiB, and a persistent per-transport receive scratch
   buffer.
5. **Media chunks shared the gate at 4 MiB.** One chunk on a slow router exceeds the frame
   deadline — a background clip download could kill the session on its own. **Shipped:**
   1 MiB chunks on Wi-Fi; USB keeps 4 MiB.

### Radio contention while a session is up

The sweep confirmed the session window is mostly clean (discovery fully stops on connect;
relay browsing/advertising off when not broadcasting; AWDL correctly off on router
sessions). Three real holes, all shipped:

- **Backgrounding leaked the relay browser:** `enterBackground` cancelled the discovery
  task directly instead of calling `stopDiscoveryLoop()`, so the AWDL-browsing relay
  `NWBrowser` survived into a resumed session with nothing to stop it. Now the full stop.
- **`ICDeviceBrowser` ran unconstrained for the app lifetime** with no device-type mask —
  eligible to browse shared/network devices continuously. Now explicitly local cameras
  only.
- The reachability churn above.

## Verdict on "it wasn't like this before"

Two genuine regressions line up with the timeline: the concurrent quick pass (d09f340)
made *other devices'* camera lists probe a live body every pass (fixed yesterday —
Bonjour-first probing + the TXT-descriptor fix that made the served-camera exclusion work
at all), and the RTT-from-frame-fetch pacing (5bddeb7) destabilised poll cadence. The
deadline-closes-the-channel design predates both but only bites on genuinely weak links —
the field router exposed it. The adaptive ladder is the structural answer.

## Second pass (shipped after the first round)

- **Cumulative socket-wait bound** (finding #13): `waitForDescriptor` restarted its full
  timeout on every spurious wakeup; the bound is now a deadline across retries.
- **The one unbounded frame fetch** (finding #14): `liveViewFrameJPEG()` now always passes
  a deadline, so no future caller can wedge the transaction gate.
- **Wall-clock property bursts spread and congestion-gated:** the descriptor refresh runs
  ONE group per pass at a fifth of the old interval (same per-group freshness, no
  five-read burst), and all maintenance refreshes defer entirely while the adaptive
  ladder has the stream stepped down — a struggling link keeps every frame slot.
- **Copy chain, the avoidable subset:** `readPacket` builds packets directly from the
  parsed header + payload `Data` instead of the serialize-then-reparse roundtrip that
  copied the JPEG-sized payload three extra times per frame. Remaining copies
  (recv→Data, buffer take, data-phase append, JPEG extraction) are one structural copy
  each.
- **Adaptive state is visible:** the Link details append "Preview reduced for link
  quality" while the ladder is below the operator's preset, so field softness is
  attributable.

## Deferred, with reasons

- **Pipelining two frame fetches on the wire.** PTP transaction semantics are strictly
  serial per session; bodies are not documented to accept overlapped operations, and a
  desync wedges the camera. Not worth the protocol risk for one RTT of gain. [verify-on-HW
  before ever revisiting]
- **Android facade ladder parity.** The Kotlin-facing pump (`runLiveViewPump`) is a
  different architecture (fixed-interval schedule, its own error taxonomy); wiring
  `LiveViewAdaptiveQuality` there is tracked as its own task and needs a real body to
  verify.
- **Watch mirroring A/B.** Per-frame WCSession traffic is backpressured and
  Bluetooth-side, but a with/without-watch fps comparison in the field would bound its
  real cost. [verify-on-HW]
- **Event-channel read errors → immediate recovery.** Correct for genuine link death;
  a retry-once policy would mask cable pulls. Left as is deliberately.

## Field validation checklist

- Weak-router session: fps should ride down (smaller picture) instead of dropping; the
  connection log shows `adaptive stream step-down/up` lines.
- No more `nehelper sent invalid result code` spam while the LUT panel is open.
- Clip download during a live session no longer stalls or kills the feed on Wi-Fi.
- Overall fps at the same preset should read a notch higher (fetch/decode overlap).
