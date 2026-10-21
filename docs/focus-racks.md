# Local A/B focus racks

Focus Rack sets two session-relative marks and pulls between them with a chosen duration,
start delay and easing. It uses the same Swift execution controller on iOS and Android.
This local implementation is experimental: the remaining physical qualification is recorded
in [the qualification log](investigations/focus-rack-qualification.md).

## Set the marks

1. Connect the camera, open live view, select movie AF-S and turn tracking off.
2. Open **FOCUS → Focus Rack**. Keep zoom and camera position fixed.
3. Focus the first subject visually or with one-shot AF. After focus settles and a new camera
   frame arrives, choose **Set A**.
4. Use **Near −1 / Far +1** to focus the second subject. **Near −10**
   and **Far +10** each run ten separately confirmed steps for quicker setup; **Stop** discards
   the remaining steps. Choose **Set B** after movement settles. The thumbnails identify the
   accepted frames for each mark. These shortcuts do not change the step size or minimum pull time.

The rack counts acknowledged increments, independently of the ordinary focus dial. Marks do
not represent measured distances. The fixed mark cards group thumbnails and relative step positions. A card sets an empty mark;
once captured, it is labelled Go to A/B with Fast reposition. Replace A/B is explicit under Options.
The current relative position is shown in the same group. Near/Far ±1/±10 sit directly below it.
The panel has no focus wheel or separate setup tabs. Uncertain references show positions as
unknown. Once a mark exists, use the rack's controls for focus
adjustments; peaking and magnification remain available. **Replace A/B** explicitly replaces
that mark at the current acknowledged focus position. **Reset marks** discards both marks.

Physical lens-ring movement may be undetectable. Reset the marks if someone adjusts the ring,
changes zoom or moves the setup. Observed lens, zoom, session, focus-setting or external AF
changes invalidate the reference automatically; the app cannot detect every physical change.

## Choose and run a move

Set **Duration** and **Start delay** in the same panel, then use **Rehearse A→B** or
**Rehearse B→A**. While recording the same controls read **Run A→B/B→A**. Both directions
remain visible and show the selected pull duration. There is no separate direction or
Fastest/Timed selector. Defaults are three seconds, zero delay and Linear. **Options** contains the optional **Ease in-out** curve, which may require more time because its peak
movement rate is higher. The Options label always names the selected curve.

The selected start mark must match the current position. **Go to A / Go to B**, labelled
**Fast reposition**, are separate actions that ignore Duration and Delay. They remain available
when the timed pull is unavailable. Fast Go stays on the fixed mark cards; timed pulls stay fixed below the scrollable setup. A collapsed panel shows
fast positioning when neither timed direction is available; expand it to edit timing. Timing edits
retain both marks. Recording remains independently
controlled by the normal record button; a rack never starts recording automatically.

The shared planner chooses the finest feasible command size for the requested duration, delay and
easing: 16/32/48/64/80 pulses, then the larger 144/192-pulse profiles. Short pulls can use larger commands; long pulls retain fine
steps. Each plan preserves the exact signed sum of the original 16-pulse mark units, including one
bounded residual command. Setup ±1/±10 retains its fine increment; explicit fast positioning keeps
its bounded camera-speed path using 192-pulse groups and one exact residual. Repositioning also
collects timing for the largest playback group and its exact residual without hidden calibration
movement. Every activation is confirmed before
the ledger advances.

Timing admission budgets each command size and the final completion cost. An unmeasured size uses
the session's worst observed command cost as an estimate until that size completes. The controller
halts on a missed budget instead of sending catch-up commands. The spacing guard also rejects sparse coarse schedules like those that previously showed stepping
in source recordings. Some durations can remain unsupported between the available profiles.
It is an experimental scheduling policy, not a measured lens encoder or a guarantee of optical
smoothness. Very close marks may still require finer movement than the tested base increment.

The local production controller opts into 5ms early Busy polling, with no extra quiet time after
native Ready confirmation. Ordinary camera focus and other SDK consumers retain their existing
cadence. A full safety preflight finishes before timed playback starts its delay/pull clock.
Periodic reads may be deferred only when the complete remaining trajectory fits within the existing
2-second safety freshness limit, including a measured-read margin. Longer pulls, countdowns and
paused runs retain periodic checks; a slow safety read can still halt a late trajectory.

A later Mac USB trial at 70mm/f2.8 used twelve 80-pulse commands over the same 60-unit span:
1-second Linear host spans were 0.972s/0.973s. The operator preferred its source-recorded smoothness
over the 96-pulse comparison. This is one round trip on the Mac, not qualification of a 94-unit span,
phone transport, or another lens/zoom. No universal 1-second minimum is assumed. Debug phone builds
save bounded private execution traces after movement, including safety-read duration and scheduled
versus actual command timestamps, for local verification.

A wider Mac USB source comparison at the same zoom/aperture used fresh A0/B−135 marks
(2160 pulses). The 144-pulse profile completed at 0.996s/1.001s; the 192-pulse profile at
0.998s/1.002s. The operator judged both smooth with matching endpoints and preferred 144 pulses.
The planner therefore prefers the smaller feasible profile, retaining 192 when the measured budget
needs it. The latest 144-pulse cost budgets 1.003125s for fifteen commands, so a strict 1s request
must choose a feasible larger profile or refuse. This source comparison does not establish phone
cadence, repeated returns or other zoom/lens combinations.

A local Mac USB trial at 70mm/f2.8 completed one 60-unit round trip with 48-pulse commands at
3 seconds Linear: host movement spans were 2.998s/2.955s, and the operator judged both pulls smooth
with matching focus in native-size source crops. This is one diagnostic result; 94-unit timing is
covered by deterministic tests, and production-phone timing, repeatability and other setups remain
unqualified. Rehearse the actual lens, zoom and marks before recording a take.

Old timing templates still decode. The new direct playback actions always use the displayed duration
and delay, including when a template retains the legacy Fastest mode internally. Fast repositioning
never uses that timing. Paused time is excluded; movement starts only from an explicit action.

- **Pause** stops scheduling new increments and lets the current increment settle. **Resume**
  continues the remaining trajectory, including any unexpired countdown, without replaying
  the original delay or completed movement.
- **Stop** appears only while a countdown, focus movement or paused move can be cancelled. It discards future movement and requests native cancellation. **Stopping…** remains
  until the camera's outcome is known. Focus stays where it stops; recording is not stopped by this control. Focus never returns automatically.

After completion, the endpoint status and opposite pull button allow an explicit timed return;
Go to A/B remains the fast alternative. Stopping recording also cancels further rack movement.

## Save timing and manage the panel

Save a named timing template under **Options**. Reset marks and Focus settings are also available there. Templates retain duration, delay and easing, plus legacy
mode/direction fields for compatibility, only. Existing templates without a mode restore as Timed. Loading one requires fresh marks and starts no movement. Marks, thumbnails, position and
armed state are never restored from storage.

Collapse preserves a compact transport strip. Clean mode and interface lock retain Pause and
Stop; unlock before resuming. The shared monitor reserves temporary space for the panel while
preserving saved scope positions. Drag the header grip to move the panel inside the safe monitor
area; accessibility actions also move or reset its position. Placement belongs to the current
session and adapts to rotation or collapse. Scope reservation follows the panel without changing
saved scope positions. Setup scrolls; the header and transport remain fixed within the panel.
Landscape keeps the panel inside the picture, left of the system rail. Expanded portrait setup
uses the safe monitor area and surrounding letterbox; compact transport remains on the picture.

The single **Close Focus Rack** (×) action stays in the header. It is available while idle and
explicitly discards session marks after confirmation. Collapse (⌄) preserves marks. Saved timing
remains. Closing and reopening cannot clear an unconfirmed-stop requirement; the controller
belongs to the camera session. The ordinary focus controls return when the panel closes.

## Recover from interruption

Backgrounding, Command mode, monitor/source replacement, loss of local control, disconnect or
incompatible focus evidence stops the rack. An interrupted increment may have moved only part
of its requested travel, so its position cannot be counted. Follow the displayed Reset or
Reconnect instruction. A fresh live image alone does not establish readiness or recover the
old marks.

On a slow or failed connection, native cancellation can take longer than the healthy-link
qualification target. Keep the stopped state visible until readiness is confirmed; never infer
that the lens stopped from a UI acknowledgment alone.

## Diagnostics

Diagnostics use the same production `FocusRackController` as normal operation on both apps.
There is one scheduler, safety-read path and native cancellation owner. The deterministic
`FocusRackEngine` holds the session ledger and plans; the shells forward observations and intents.
Debug builds save bounded traces after movement to `focus-rack-production.json` in the app's private
Documents directory on iOS or files directory on Android. Traces include command outcomes and timing,
with no images or camera serial numbers. Collecting a trace starts no movement.

The earlier standalone Focus Probe panels, pulse/cadence launch overrides and action-returning
Android probe bridge have been retired. Historical trials in the qualification log retain their
original settings; new investigations exercise the production panel and controller.

## Local verification

Portable tests cover capture identities, timing/easing, direction, pause/resume, cancellation,
stale callbacks, invalidation, template restoration and native failure outcomes. Fake-camera
and facade tests exercise command ownership and queued-intent cancellation. Simulator/emulator
checks cover the two native editors, compact transport, input dialogs, accessibility and screen
edges. Canonical gates are `just native-check`, `just android-check` and `just check`.

The finer 16-pulse/10ms profile passed source smoothness in two isolated iPhone USB round trips
at 70mm. The latest repeated sequence contains eight timed pulls, four complete round trips,
with operator-reported sharp endpoints. Its source recording was not reviewed. Further physical
testing ended at the operator's request. This does not qualify the wider lens/transport matrix,
new editor or finer-profile cancellation behavior. Nothing is pushed, published or released.

The local Mac USB investigation subsequently demonstrated one smooth source-reviewed round trip
at about 1.50/1.51 seconds using twenty 64-pulse chunks over 1,280 requested pulses at 70mm/f2.8.
The 128-pulse/2-second and 256-pulse/1-second scheduled trials failed source smoothness. The Mac
result does not establish exact requested timing, repeatability, cancellation or production-phone
cadence. Both native shells require qualification with their normal live-view and safety traffic.
