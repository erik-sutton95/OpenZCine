# Networking audit — 2026-08-04 (overnight)

Requested scope: the entire networking codebase — connections, relay, stability, reliability —
across the real link mix (WiFi5 portable travel router, home WiFi 6/7, phone hotspots, camera
AP, USB-C). Three parallel deep sweeps (iOS connection lifecycle, relay stack both platforms,
Android transport) plus the storm investigations that preceded them the same night.

Legend: **SHIPPED** = fixed tonight with green gates. **DEFERRED** = verified real, queued with
reason. Line numbers are as of the audit pass and drift with edits.

---

## The night's storyline (context for the fixes)

1. The share-this-feed drop storm recurred and was root-caused live: PTP-IP
   **ProbeRequest/ProbeResponse were missing from the packet table** (unanswered body liveness
   pings are grounds for the body to close the session), and **no cross-run damping** existed
   for drops whose recoveries succeed. Both fixed (`bf3fd4b`), plus the storm guard's
   operator card. HW-confirmed: the camera no longer bricks; the guard pauses at 3 drops.
2. Erik isolated the trigger: **a second device's open camera list knocks the held camera**.
   Fixed in three layers: dual `.bonjour`/`.bonjourWithTXTRecord` browse (listing never hinges
   on TXT delivery), sticky + blanket served-host shields, and the **in-use beacon** — a held
   camera advertises `ch=<host>` + `w=0` even when NOT sharing, both platforms
   (`ad53fb8`, `eea036c`, `8b78cba`).
3. A debug **LAN log tap** now streams every connection-diagnostic line from DEBUG builds to a
   developer machine (`3bd82f0`; sink script in the session scratchpad, advertise
   `_ozc-logtap._tcp`). Its own launch bug — browsing an undeclared Bonjour type fails
   NoAuth(-65555) *and destabilizes the app's other local-network flows on device* — is why
   `NSBonjourServices` now lists every browsed type, and why the tap hard-disables itself on
   any browse failure.

## SHIPPED tonight (audit rounds, commits `98ac43d` + the iOS batch)

> **2026-08-04 morning update — the adaptive ladder was REMOVED at Erik's request** ("not a
> very nice experience"): automatic preview softening read as instability, and in the morning's
> knock-storm it degraded the picture without being able to help. The RTT-scaled fetch deadline
> is now the stall-survival mechanism; quality stays pinned to the operator's preset (the
> stream-preset picker is the manual control). A starved link shows honest low fps instead of
> secretly changing the picture. If the field wants adaptation back, it returns as an explicit
> opt-in. The ladder entries below are kept for the record; the policy, its tests, and all
> wiring were deleted on both platforms.

### Cross-platform ladder + congestion
- **iOS H3 — the adaptive ladder was inert.** `refreshLinkHealth()` (the 1 s tick) never called
  `applyThermalStreamStepDownIfNeeded()`; the only steady-state applier was a property
  round-robin visit ~10+ minutes out under congestion. One line: the tick now applies the cap.
  This is likely the single biggest "Router felt unusable" contributor after the probe fix.
- **Android ladder (task #107).** The facade pump feeds the shared `LiveViewAdaptiveQuality`;
  verdicts restart the stream at the stepped size on the pump thread, never mid-take
  (EndLiveView during recording freezes the body's monitor — [verify-on-HW] whether the iOS
  restart path needs the same guard). `sessionLiveViewPreviewReduced()` drives the link
  caption and gates the heavy Kotlin property round-robin.
- **Android S1#1 — quality bias was 2/3 dead.** Kotlin's `require(compression in 1..3)` threw
  inside `runCatching` for latency (0) and detail (5), silently dropping the ENTIRE preview
  request. Widened to 0..5; parser test now round-trips all six values (it used to PIN the bug).

### Session lifecycle (iOS)
- **H1/H5 — drops outside the monitor were dropped on the floor.** `beginSessionRecovery`
  guarded on `isMonitorPresented`, so "live view never started", ready-page drops, and
  keep-alive ×3 all detected death and then did nothing. Guard is now `isCameraControlSession`.
- **H2 — the `.preparingLiveView` watchdog could never fire.** The establishment task's defer
  cancelled it at the instant the phase began. It now survives until the first decoded frame
  (`dismissConnectionProgress` cancels it); "connected but never started live view" is bounded
  again (40 s budget).
- **M8** — `.waitingForOperator` now blocks fresh automatic recovery runs (only
  `.pausedAfterRepeatedDrops` did).
- **H6 — the 6 s frame-fetch deadline killed sessions on radio stalls.** A breach closes the
  command socket by design (blocked reads can't cancel), so the steady-state deadline now
  rides the RTT EWMA: `clamp(25×RTT, 6 s, 15 s)`. First-frame keeps its 10 s.
- **M6/foreground pairing** — backgrounding now cancels an in-flight recovery (it kept opening
  PTP sessions until iOS suspended the app mid-handshake); foregrounding resumes recovery when
  the monitor is up with no session, and restores the **relay watcher's browse** (S1 relay #1:
  after one background round-trip the watcher's rejoin watchdog was blind forever).
- **M3** — the AccessorySetup Wi-Fi picker continuation latched permanently when the connect
  attempt was cancelled; every later join failed with "picker already active" until app
  restart. Now cancellation-aware.
- **M7** — the relay held-frame heartbeat stops one minute into an operator-decision pause
  instead of re-sending the frozen frame forever.

### Relay (iOS)
- **Crash fix in tonight's own dual-browse**: duplicate service names (one result per
  interface under `includePeerToPeer`) hit `Dictionary(uniqueKeysWithValues:)` — a hard trap
  on the main actor. Now merges with a shield-preferring uniquer.
- **S2#5 — TCP keepalive on all relay connections** (10 s/5 s/3): a vanished control holder
  released the token in ~25 s instead of the TCP retransmission eternity.
- **#10** — `hasPeerReadyForFrame` counts authorized peers only (a passcode lurker pinned the
  congestion signal at "ready", disabling the bitrate ladder's saturation half).
- **#9** — the listener's `.failed` handler is identity-guarded like `.ready` (a late failure
  from a superseded listener tore down its replacement).
- **#11** — turning control requests OFF now reclaims from a current holder, not just the
  pending request.
- **#12** — the in-use beacon advertises under a distinct service name (`<host> in-use`), so
  its async teardown can't race the real broadcast into an "(2)" mDNS rename.

### Android transport
- Socket parity: **SO_KEEPALIVE (10/5/4) + SO_RCVBUF 512 KiB** (half-open AP drops detected;
  per-frame JPEG bursts no longer stall the default receive window).
- **S2#3** — a dead Wi-Fi event drain now tears the session down for ONE clean reconnect
  (no re-open path exists, and an unanswered body liveness probe kills the session anyway).
  Contract test updated — it pinned the old behavior.
- **S2#5** — `consecutivePumpEnds` resets on connect (it survived reconnects at its
  escalation value: a positive-feedback teardown loop).
- **S2#4 (half)** — `stopLiveView`'s timeout path un-latches `liveViewPumpActive` (a stuck
  flag turned every later start into `liveViewAlreadyActive` → reconnect loop).
- **S3#15** — `disconnect()` shortens the EVENT socket timeout too (the drain can block in
  the probe-answer send while teardown holds the lifecycle lock).
- **S3#14** — read/send loops re-read the descriptor per iteration (fd-number reuse could
  silently `recv` off a different socket: cross-connection PTP desync).
- **S3#13** — the 60 Hz JNI frame path clears pending Java exceptions after allocations and
  upcalls (a pending OOM aborted the process on the next JNI call).

## DEFERRED — ranked queue for follow-up nights

**High value, medium effort**
1. **iOS H4 — abandoned establishment attempts can't be force-closed** → two live command
   channels at a one-initiator body (the wedge mechanism). Needs an early transport handle
   (`inFlightTransport`) the 30 s abandon path can close. The most important remaining item.
2. **Android relay strand (relay #3)**: no preferred-port rebind on the Android host + the
   watcher rejoins a captured host:port forever. Mirror iOS's preferred port + rejoin through
   the live NSD row by name.
3. **Android watcher stall watchdog (relay #4)**: no liveness check at all — a suspended
   broadcaster leaves a frozen "live-looking" picture indefinitely. Mirror the iOS 8 s stall
   tear-through off `RelayLiveFrameSource` timestamps.
4. **iOS M5 — `.initFailed(.busy)` is retried aggressively** (up to ~16 Inits in 45 s against
   a body that answered "another initiator holds me"). Split it out: ≥10 s backoff + count
   toward the storm guard.
5. **Android S2#4 (rest)** — `readExact`/`send` need a whole-call deadline (a trickling link
   keeps one transaction alive indefinitely while holding the transaction lock).
6. **Android S2#6** — the recovery coordinator's budget resets on every lifecycle bounce
   (each foreground buys a free immediate connect); hoist `consecutiveFailures` + terminal
   state to coordinator fields. Also unify the two entry points' storm-guard reset
   (`MainActivity:1188` has no reset path).

**Correctness, small**
7. iOS M1/M2 — PTPIPSocket fd close/reuse race (close on the socket's own serial queue) and
   the deadline-task-vs-completed-transaction race (finished flag).
8. Relay #6 — adopted-but-never-greeted connection has no timeout (cancel the connect timeout
   on HELLO, not on `.ready`); add a `.connecting` branch to the watchdog.
9. Relay #7 — Android host reads `peers` outside the mutex (HashMap corruption under
   concurrent join/leave); #13 — the outgoing host's async stop clobbers the new broadcast's
   UI (null the callbacks in `stop()` first).
10. Relay #8 — Android NSD registration failures/renames are silently swallowed; adopt the
    OS-assigned name from `onServiceRegistered`, surface `onRegistrationFailed`.
11. Relay #15/#16 — Android frame pump: no empty-peer guard, no 30 fps cap, and no
    `updateServedCamera` twin (broadcast-before-connect advertises no `ch=` for its lifetime).
12. Android S3#7 — thread the loop's `host` through `probePtpIpReachable` (one call uses the
    default 192.168.1.1 = a home router's gateway off the camera AP) + a no-active-session
    precondition.
13. iOS LOWs: `sessionTeardownTask` never nils (every later connect pays the 1200 ms settle);
    `probeCameraName` swallows `CancellationError`; `.streaming` case in the restart loop has
    no sleep; `.restoreCameraProfileBeforePairing` lacks the `allowsPairingEscalation` guard
    (USB-only today); Bonjour browse deadline rides the main queue; `nextEvent`'s skip loop
    could use a junk counter.
14. Relay #17/#18 — host-side hardening: peer cap, unauthenticated-peer timeout, join rate
    limit (4-digit passcode has none), and a 64 KB host-side inbound frame cap (viewers can
    currently drive 8–16 MB allocations on the device holding the camera).

**Larger / design**
15. **Android S3#8 — camera-AP loss unbinds the process and recovery reconnects over the
    default network** (Init against the home router's gateway). Recovery needs the joiner's
    bound-state, or `handleLost` should re-arm the specifier request.
16. Relay #14 — unbounded state/control queueing to a wedged peer (both platforms); add
    in-flight accounting beyond frames.
17. Relay #22/#23 — Android relay: `PickerValue` commands are accepted and dropped; no HEVC
    encode or bitrate adaptation (JPEG passthrough only) — an iOS watcher on an Android
    broadcaster gets the ~20 Mbit/s stream the HEVC work replaced.
18. Android S4#21 — delete the dead parallel Kotlin PTP stack (`PtpIpSocketTransport.kt`,
    `NsdCameraSessionFactory.kt`) after verifying `transport/ReconnectBackoff.kt` consumers.
19. Contract pins: add `maximumPayloadBytes` + protocol `version` to the cross-platform
    vector tests (TXT keys + service type were pinned tonight).

**Targeted tests the auditors recommended**
- `AsyncSerialGate` stress test (N tasks, random cancellation — the single most load-bearing
  primitive; traced correct, untested).
- Storm-guard convergence through the `.neverStarted` reconnect path.
- `LiveFrameSignature` collision at the smallest stream size; `PTPIPReadBuffer` partial-consume
  growth under a chunked 2 MB frame.

## Field-verification list for the next hardware session

- Router path under load: expect `adaptive stream step-down` within seconds of congestion
  (not minutes), "Preview reduced for link quality" in Link details, fps degrading instead of
  dropping. Same on the Galaxy (ladder + caption + maintenance gate are new there).
- Multi-second radio stalls: sessions should ride them out (RTT-scaled deadline) instead of
  tearing down.
- Second device's camera list open, sharing OFF: the main device must stay rock solid (the
  in-use beacon shield). Watcher list open, sharing ON: broadcast row lists on the iPad/13,
  with `relay browse[list|txt]` lines in the tap naming any residual break.
- Latency + Detail quality bias on Android: both must now visibly change the stream.
- Background/foreground round-trips as watcher and as operator mid-outage.
- Log tap: with the sink running, both devices' `attached` hellos and live diagnostics.
