# Connection reliability audit — reconnect wedge (2026-07-09)

**Symptom (field, real ZR over iPhone hotspot 172.20.10.x):** the connection drops "often," and
reconnecting **sometimes wedges the camera** hard enough to require a battery pull. Operator log:

```text
NEHotspotNetwork nehelper sent invalid result code [1] for Wi-Fi information request  (×2)
attempt host=172.20.10.8 strategy=savedProfile saved=1 knownPaired=1
failed  host=172.20.10.8 The camera didn't respond in time. Check Wi-Fi and try again.
attempt host=172.20.10.8 strategy=savedProfile saved=1 knownPaired=1
connected host=172.20.10.8 pairing=false summary=pairing=skipped appMode=0x2001 recProhib=0x0
```

## Root cause

The wedge is not one bug — it's the app applying PTP-IP **Init pressure to a ZR that is still
holding a stale, never-gracefully-closed session** whose TCP FIN it may never have received over
the flaky hotspot link. Four code facts stack, ranked by contribution:

1. **CloseSession (0x1003) was never sent over Wi-Fi** — every disconnect was socket-close only.
   The camera releases its single PTP session/connection slot only when it notices the TCP death;
   on a lost-FIN hotspot drop it never does, so it holds the slot for 30s+ (its own keepalive).
   A reconnect Init inside that window asks for a slot the camera can't grant → firmware wedge. **[HIGH]**
2. **Discovery raw-Init-probes the just-dropped camera** (saved hosts probe first since commit
   e03ca25) plus the real reconnect Init — two Init handshakes at a fragile camera. **[HIGH]**
3. **The reconnect fired with zero settle** — a fresh Init landed within ms of the old socket
   close, far faster than the camera's slot-release time. **[HIGH aggravator]**
4. **The event socket leaks on the command-timeout path** — a half-dead connection can hold a
   second camera-side slot until the next full teardown. **[MED-HIGH]**

The `attempt→fail→attempt→connect` log is the *benign* version of this (the ZR holds the pre-drop
session, times out Init #1, grants #2). The wedge is when that state tips over instead of recovering.

Why it also drops "often": the live-view frame fetch has `deadline: nil`, so a camera that dribbles
then stops bytes isn't detected crisply; and detection leans entirely on the live-view watchdog —
keepalive failures and event-drain death only log, they don't drive a reconnect. The
`NEHotspotNetwork "invalid result code [1]"` line is benign OS log spam (nil-SSID fetch), not part
of the PTP reconnect path — a red herring.

## Fixed (2026-07-09, commit 955a446) — all `[verify-on-HW]`

Highest-leverage, low-risk core. Adversarially reviewed (read-only): protocol-correct, cannot hang
teardown, no concurrency hazard, strictly-better-or-neutral vs the old bare close on every path.

- **Graceful CloseSession before dropping sockets** (`NativeCameraSession.shutdown()`): best-effort,
  2s-bounded (`try?`), then `transport.close()`. Bounded so it can never stall teardown — on a dead
  link the transact's own 2s deadline closes the command socket and wakes the blocked send.
- **Every session teardown now routes through `shutdown()`** — the reconnect and disconnect paths,
  the failed-establishment catch (OpenSession succeeded but a later step threw), and the
  post-pairing auto-reconnect handoff (the single most wedge-prone moment).
- **Reconnect settle**: 1200ms after teardown before a fresh Init, gated to reconnects only (cold
  first connect untouched). The 1200ms is the calibration knob — tune to the camera's real
  slot-release time on hardware.

### Second symptom, same root class (commit e7bc10e)

**"Connected but the feed and all camera control are dead, and the retry says 'unable to
connect'."** The handshake succeeds, then the first `GetLiveViewImageEx` is accepted but delivers
no bytes — and it was awaited with **no deadline** (`liveViewFrame(deadline: nil)`), so it hung
forever holding the serial transaction gate. Every other command (focus, control, polls) queued
behind it and never ran → feed *and* control dead. The held gate is also why the retry wedged:
teardown's `stopLiveView`/`CloseSession` queued behind the stuck fetch and never ran, so the next
connect blocked on teardown. The `LiveViewWatchdog` couldn't help — it's a pure timer that only
evaluates *between* completed frames, never during a fetch that never returns.

**Fixed:** every streaming frame fetch now carries a finite deadline (steady-state 6s, first frame
10s for sensor spin-up) via a shared `liveFrameTask` helper. On breach the fetch's transaction
closes the command socket (the existing proven mechanism), the fetch throws, and the existing
recovery converts it to `.neverStarted`/`.stalled` → restart → full reconnect. One bound fixes both
the freeze and the reconnect-wedge, since both stem from the held gate. (This is the audit's former
deferred item "coarse live-view fetch deadline," now shipped. The `[verify-on-HW]` knob: real ZR
first-frame latency vs the 10s bound.)

## Deferred — need on-device validation, sequence AFTER the above

Applying these blind risks making the wedge worse (wrong ordering / false positives), so they wait
for a real ZR. Recommended order:

1. **Never leak the event socket.** (i) The command-timeout deadline task closes only the command
   socket (`PTPIPTransport.swift` ~:176) — close both. (ii) On event-drain hard error
   (`NativeAppRoot.swift` ~:2982) tear the transport down instead of returning silently. *(Concurrency:
   validate the mid-transaction event-socket close doesn't race the event drain.)*
2. **Escalate keepalive / event-drain failure to a real reconnect.** Today both only log. Drive the
   shared teardown+reconnect when `recentKeepaliveFailures` crosses ~2-3 or the drain dies while
   connected. ⚠️ **Must land AFTER #1 above and after the shipped CloseSession fix** — doing it first
   just means more reconnects into the (then still-un-fixed) hammer, i.e. MORE wedges.
3. **Suppress the discovery self-probe of a just-dropped host.** The priority-probe (e03ca25) raw-
   Init-probes saved hosts first; back it off for a host dropped in the last few seconds so
   discovery doesn't add Init pressure during the camera's slot-release window. (The shipped fix
   already shrinks this window; discovery is provably stopped during establishment, so this is
   belt-and-suspenders.)

### Do NOT

- **Do not tighten the 10s socket timeout** to "drop less" — shorter timeouts = more Init attempts =
  more Init pressure = more wedges.
- **Do not add aggressive auto-retry** to the hotspot savedProfile path before the above land — it
  multiplies the stale-session hammer.
