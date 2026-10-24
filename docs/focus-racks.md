# A/B focus racks

Focus Rack sets two session-relative marks and pulls between them with a chosen duration,
start delay and Linear timing. It uses the same Swift execution controller on iOS and Android.
Remaining physical qualification is recorded in
[the qualification summary](investigations/focus-rack-qualification.md).

## Native AF and Timed Rack

The focus panel offers **Native AF** and **Timed Rack** on iOS and Android. It opens in
Timed Rack to retain the existing workflow. Opening the panel or selecting a mode temporarily
sets its movie AF configuration through the existing confirmed camera-setting path. Native AF
uses **AF-F / Auto-area AF / subject detection Off**; Timed Rack uses **AF-S / Auto-area AF /
subject detection Off**, preserving the configuration used for the local timing calibration.
A mode change is unavailable while a timed movement, unconfirmed stop or another focus command
still owns control. Setup waits for confirmed recording stop, a fresh post-action header, idle
focus commands and bounded DeviceReady confirmation. It can switch AF-F to AF-S without first
acquiring a subject. Restoration retains the stricter focus-settlement checks below.

**Native AF** saves two picture targets independently of Timed Rack's relative lens marks.
Choose **Set A** or **Set B**, then tap the subject in the live picture. The panel collapses during
selection so it does not cover the subject. Saving a target also selects it for a focus preview.
**Go to A/B** selects a saved target immediately. **Rehearse A→B/B→A**, labelled **Run** while
recording, waits for **Start delay** before selecting the destination. It never repositions to
the source or changes recording automatically. **Cancel delay** discards unsent targeting; it
does not promise to stop the camera's continuous AF after a target request has been sent.
Target coordinates use the camera picture, so rotating or mirroring the monitor does not reverse
them. A mode or lifecycle interruption cancels unsent work while retaining the saved targets.
Each target explicitly shows **A set / B set** or **not set**. Go requires its saved target;
directional transitions require both. Unavailable actions remain visible with a dimmed appearance.
Switching from Timed Rack to Native AF releases the app's focus-point lock so the picture can accept targets.
If the point is locked again, **Unlock focus point** is available in the panel, even without an AF
box. Unlocking does not select a target, move focus, or release the main interface lock.

Native AF uses the camera's existing **g6 AF speed**. It has no exact-duration selector or MF
calibration requirement: the camera determines the transition and whether it acquires the subject.
AF-F, Auto-area and subject detection Off are configured automatically; g6 has no control in the
current protocol implementation. **Focus settings** remains an optional secondary control.
“Target A/B selected” acknowledges targeting, not optical sharpness. The local test at speed −5 produced smooth transitions
of roughly five seconds; the near bedpost needed retries. This does not promise exact 1/3/6-second
moves or reliable acquisition of every subject.

**Timed Rack** retains the existing mark, planner, cancellation, readiness and freshness
checks described below. Native AF revokes timed movement authority. A no-op setup retains timed
marks; actual AF actions and AF-setting writes invalidate their relative reference through the
existing external-focus path. Before returning to timed playback, set fresh marks if focus moved
outside the rack or its configuration changed.

Closing the panel restores the confirmed values from before automatic setup, only for settings
the app changed and still owns. Manual picker intent, including selecting the same value, or an
observed camera change relinquishes that setting; changing away and back does not regain ownership.
Manual choices made while the initial setup reads are pending are also kept.
An explicit later mode selection can configure it again, remembering the latest manual value for
restoration. Lens position is never restored. If recording or focus work is active, closing hides
the panel and retains pending restoration until the camera is idle. Unknown recording/readiness
or setting values do not permit a write. Errors are reported without an automatic retry loop.
Disconnecting retires the pending restoration; it is never replayed on a replacement connection.

## Set the marks

1. Connect the camera and open live view. Leave recording stopped for automatic AF setup.
2. Open **FOCUS → Focus Rack**. Keep zoom and camera position fixed.
3. Focus the first subject visually or with one-shot AF. After focus settles and a new camera
   frame arrives, choose **Set A**.
4. Select **Near** or **Far**, then choose **1**, **10** or **100** steps to focus the second
   subject. The buttons show negative amounts for Near and positive amounts for Far. Selecting
   a direction does not move focus. Each step is confirmed separately; **Stop** discards
   the remaining steps. The mark cards and Near/Far controls stay in place during a nudge. The
   pressed button shows the percentage of acknowledged steps; the other setup controls are disabled
   until movement settles, and Stop remains available. Choose **Set B** after movement settles.
   The thumbnails identify the
   accepted frames for each mark. These shortcuts do not change the step size or minimum pull time.

The rack counts acknowledged increments, independently of the ordinary focus dial. Marks do
not represent measured distances. The fixed mark cards group thumbnails and relative step positions. A card sets an empty mark;
once captured, it is labelled Go to A/B with Fast reposition. Replace A/B is explicit under Options.
The current relative position is shown in the same group. The Near/Far selector sits below it,
with the three signed step buttons directly underneath.
In Clean display the panel keeps its compact transport. **Open focus rack setup** returns to Live
display and opens setup without changing marks or timing. The interface lock still prevents setup;
Stop remains available during movement. Compact transport keeps timing warnings visible.
The panel has no focus wheel or separate setup tabs. Uncertain references show positions as
unknown. Once a mark exists, use the rack's controls for focus
adjustments; peaking and magnification remain available. **Replace A/B** explicitly replaces
that mark at the current acknowledged focus position. **Reset marks** discards both marks.

Physical lens-ring movement may be undetectable. Check the marks if someone adjusts the ring,
changes zoom or moves the setup, and reset them if needed. Observed lens, zoom or focus-setting
changes preserve marks and detach incompatible timings. A new camera session or an external AF
move invalidates the relative reference; the app cannot detect every physical change.

## Choose and run a move

Set **Duration** and **Start delay** in the same panel, then use **Rehearse A→B** or
**Rehearse B→A**. While recording the same controls read **Run A→B/B→A**. Both directions
remain visible and show the selected pull duration. There is no separate direction or
Fastest/Timed selector. Defaults are three seconds, zero delay and Linear. The panel currently offers
Linear only. Ease in-out remains readable in old templates, but loading them uses Linear while
retaining their duration and delay. Timing is a target; overruns are warnings, while cancellation,
camera errors and safety admission remain enforced.

The selected start mark must match the current position. **Go to A / Go to B**, labelled
**Fast reposition**, are separate actions that ignore Duration and Delay. They remain available
when the timed pull is unavailable. Fast Go stays on the fixed mark cards; timed pulls stay fixed below the scrollable setup. A collapsed panel shows
fast positioning when neither timed direction is available; expand it to edit timing. Timing edits
retain both marks. Recording remains independently
controlled by the normal record button; a rack never starts recording automatically.

Duration is a requested target, separate from the estimated fixed execution schedule. If measured
command costs need longer, the controls remain available and show the longer estimate without
overwriting the requested value. Small estimate growth, such as 1.007 seconds for a 1-second
target, does not disable playback. The planner leaves dispatch headroom when extending a move.
The 3-second target preserves the accepted 64-pulse ordinary family, with measured smaller tails
and safety-read bridges no larger than 128 pulses. Measured smaller ordinary moves can be used
when 64-pulse measurements are unavailable; larger ordinary moves are not silently substituted.
The existing 1-second and 6-second families remain separate. Each plan preserves the exact signed
sum of the original 16-pulse mark units, including one
bounded residual command. Setup ±1/±10/±100 retains its fine increment; explicit fast positioning keeps
its bounded camera-speed path using 192-pulse groups and one exact residual. Repositioning also
collects timing for the largest playback group and its exact residual without hidden calibration
movement. Every activation is confirmed before
the ledger advances.

Timing admission budgets each command size and the final completion cost. An unmeasured size uses
the session's worst observed command cost as an estimate until that size completes. Measured
playback never invents timing for an unmeasured residual. The command sequence is fixed before
movement. If a command, host wake or safety read runs late, the remaining schedule extends instead
of compressing commands or stopping short. A separate timing warning reports the overrun and does
not disable playback. Timing-only planning limits use a slower measured schedule and estimate.
Required calibration, invalid marks, camera errors and unsafe context can still prevent movement.
Requested duration, estimated execution duration and observed host command span are separate
values. None measures optical arrival or guarantees smoothness. Very close marks may require
finer movement than the tested base increment.

Optional **Calibrate increments** under Options measures 32, 48, 64, 96 and 128 pulses in
both directions over the actual A/B span, including exact residual commands. Each tap moves to
the other mark. A partial, stopped or failed traversal does not complete its stage. Marks must
be at least eight units apart; they do not need to be exactly 100 units apart. Playback can use
available measured sizes before every calibration stage is complete.

Both apps save acknowledged command timing maxima separately from session marks. Compatible
measurements recover after reconnecting only when fresh camera identity, transport, lens, zoom
and focus configuration match. Recovery restores no position, mark, readiness timestamp or
movement authority. New larger costs take precedence; incompatible measurements remain inactive.
Reset, mark replacement and a confirmed setup change restart traversal credit. Idle inactivity
preserves completed stages.

The controller uses early Busy polling with no extra quiet time after native Ready confirmation.
A full safety preflight finishes before the delay/pull clock starts. Periodic reads may be deferred
only if the complete remaining trajectory fits the two-second freshness limit, measured from the
oldest preflight evidence. Longer pulls reserve safety-read windows alongside movement. The latest
accepted read duration, with a 100ms floor, determines the reservation; the budget can grow during
the run. Ordinary focus commands retain their existing polling cadence.

A safety read must drain before the next focus command. A late successful read extends the
schedule. When earlier evidence expires while its replacement is pending, playback waits for that
read; it never starts movement without an accepted result. Failed or stale evidence still prevents
activation. Stop remains available during reads. Countdowns and pauses retain periodic checks,
and acknowledged pauses extend the timing epoch. Timing growth never causes a catch-up burst.

Rehearse the actual lens, zoom and marks before recording a take. Command acknowledgments and
host timing do not establish optical smoothness or sharpness.

Old timing templates still decode. The new direct playback actions always use the displayed duration
and delay, including when a template retains the legacy Fastest mode internally. Fast repositioning
never uses that timing. Paused time is excluded; movement starts only from an explicit action.

- **Pause** stops scheduling new increments and lets the current increment settle. **Resume**
  continues the remaining trajectory, including any unexpired countdown, without replaying
  the original delay or completed movement.
- **Stop** appears only while a countdown, focus movement or paused move can be cancelled. It discards future movement and requests native cancellation. **Stopping…** remains
  until the camera's outcome is known. Focus stays where it stops; recording is not stopped by this control. Focus never returns automatically.

After completion, the current-position row and opposite pull button allow an explicit timed return;
Go to A/B remains the fast alternative. Stopping recording also cancels further rack movement.

## Save timing and manage the panel

Save a named timing template under **Options**. Reset marks and Focus settings are also available there.
Templates retain duration and delay with Linear timing, plus legacy mode/direction fields for
compatibility. Older Ease in-out values still decode; production playback uses Linear. Existing
templates without a mode restore as Timed. Loading one requires fresh marks and starts no movement.
Marks, thumbnails, position and
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

Backgrounding, Command mode, loss of local control, or stale/incompatible camera evidence
stops scheduling without discarding acknowledged position or marks. Returning requires fresh
camera readiness and a later real frame; movement resumes only from another explicit action.
A confirmed lens, zoom or focus-configuration change advises you to check A and B and reset
marks if needed. Resetting is the operator's decision. Timing measurements from an incompatible setup
are detached from playback. Compatible saved timings can recover after a fresh readiness read,
including after resetting or recapturing marks; calibration traversal credit is never fabricated.
The normal preflight, two-second freshness, Stop, uncertainty and fixed-plan ordering checks
still apply. Timing overruns remain warnings.

An interrupted increment may have moved only part of its requested travel. If the native
outcome cannot account for that displacement, follow the displayed Reset or Reconnect
instruction. A new camera session or an observed external focus move also invalidates the
relative position. A fresh image alone cannot recover an unknown position.

On a slow or failed connection, native cancellation can take longer than the healthy-link
qualification target. Keep the stopped state visible until readiness is confirmed; never infer
that the lens stopped from a UI acknowledgment alone.

## Execution and verification

Both apps use the same production `FocusRackController`. The deterministic `FocusRackEngine`
holds the session ledger and plans; shells forward observations and intents. There is one
scheduler, safety-read path and native cancellation owner. Temporary focus-trace exporters,
Native AF event logging and retired pulse-profile trials are not part of the app.

Portable and fake-camera tests cover capture identities, direction, timing warnings, six-second
completion, safety-read placement, pause/resume, cancellation, stale callbacks, template and
calibration restoration, AF ownership and native failures. Simulator/emulator tests cover both
modes, saved targets, the setup controls, accessibility, compact transport and screen edges.
Canonical gates are `just native-check`, `just android-check` and `just check`.

Software checks do not close the remaining optical qualification in the
[qualification summary](investigations/focus-rack-qualification.md).
