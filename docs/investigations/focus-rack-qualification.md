# Local A/B focus-rack qualification

This log records historical hardware trials, including the retired standalone Focus Probe.
Current diagnostics and trace collection use the production controller described in
[Focus Rack](../focus-racks.md#diagnostics); old probe launch commands below are historical.

Status: **local diagnostics; 64-pulse profile failed on both phones; finer profile passed source
smoothness in isolated iPhone USB cycles; full qualification remains open**.
After reviewing normal-speed native-size source crops from each phone, the operator reported
visible stepping or jumps on both. The tested profile was 64 pulses per increment, an 80ms
quiet period, an eight-second Ease in-out pull and a two-second delay at fixed 70mm/F2.8 over
USB. Repeatable endpoints and acceptable host timing do not satisfy the smoothness requirement.

This is the first gate for [discussion 11](https://github.com/erik-sutton95/OpenZCine/discussions/11).
The local Marks/Move editor, saved timing templates and pause/resume now share a production
controller across both shells; their software verification is recorded in the local implementation
handoff. These changes have not repeated physical qualification through either production shell.
The original physical qualification remains incomplete. Local editor implementation continues after
the operator ended further hardware testing. The finer-profile follow-up passed normal-speed
source smoothness for one iPhone USB cycle at 16 pulses, 10ms quiet, 16s Linear and 2s delay.
The corrected latest sequence contains four complete round trips; ten-cycle repeatability and
the remaining physical matrix are still open. The source-reviewed single-cycle result
does not establish the complete feature's feasibility across the requested configurations.

## What the candidate does

The same portable Swift probe plans fixed-size pulse increments for both shells. It counts only
completed increments, requires fresh real frames and focus/lens readback, and never starts a
movement on launch. Duration and easing change the increment timing; they do not change pulse
size. Mark replacement preserves the existing relative reference.

AF-S, movie mode, tracking off and foreground local ownership are required. Initial AF acquisition
is allowed before A; capture waits for actual DeviceReady confirmation after external focus commands
retire, followed by a subsequent frame. A finite AF polling budget is not settlement proof. After A,
outside focus changes invalidate the marks. Physical ring movement and replacing an identical lens
may be undetectable. Keep zoom fixed and use only the probe controls once marks are set.

Stop discards future work immediately and asks the native session to cancel at a safe transaction
boundary, then confirm readiness. An interrupted increment loses the relative reference. A stop
that cannot be confirmed requires reconnection before Reset can establish another reference.
An old run's completion cannot establish movement or readiness for a replacement session.

The pulse quantum and cadence defaults below are **experimental inputs**, not qualified lens
calibration. A one-increment span cannot pretend to form a long timed rack. Timing that would
overload the configured cadence is rejected, and late work never catches up in a burst.
The configured interval is a conservative quiet period after each confirmed completion. Native
queue delays cannot shorten it; measured command latency may make an otherwise planned timing fail.
Nudge and Go to mark wait for readiness without an absolute duration promise. Timed Run retains
its deadline. iOS safety readback and rack increments do not overlap, so readiness cannot mistake
the rack's own active increment for external unsettled focus.

## Enable the probe

Use a Debug build and connect a real camera normally. Do not enable the synthetic demo feed for
physical testing. Release builds ignore these launch hooks.

Current finer-profile experiment, iOS launch environment:

```text
ZC_FOCUS_RACK_PROBE=1
ZC_FOCUS_RACK_PULSES=16
ZC_FOCUS_RACK_INTERVAL=0.01
ZC_FOCUS_RACK_DURATION=24
ZC_FOCUS_RACK_DELAY=2
ZC_FOCUS_RACK_EASING=linear
```

Android launch extras after installing with `just android-install <serial>`:

```sh
adb shell am start -n com.opencapture.openzcine/.MainActivity \
  --ez zc.focusRackProbe true \
  --ei zc.focusRack.pulses 16 \
  --es zc.focusRack.cadence 0.01 \
  --es zc.focusRack.duration 24 \
  --es zc.focusRack.delay 2 \
  --es zc.focusRack.easing linear
```

Use `easeInOut` for the other curve. Pulse size, quiet period and delay are launch configuration;
changing them requires a full relaunch and fresh marks. Idle duration/curve presets preserve marks.
A two-second delay with a 24s duration waits two seconds after Run, then requests a 24s pull.
Observed final-command cost is included in the requested duration; the trace records actual
command starts and completions for comparison. These are experimental inputs, not a lens preset.

## Physical procedure

1. Record camera/lens firmware, transport, recording settings, focal length and aperture. Start
   with a Nikon ZR and Tamron 35-100mm F/2.8 Z mount at fixed 70mm and F/2.8, with two stationary
   subjects at different distances. Keep source recordings local.
2. Focus A visually or with one-shot AF, wait for the probe to allow capture, then Set A. Use Near
   or Far to reach B, wait for fresh-frame admission, then Set B. No meters or absolute lens
   coordinates are implied by the relative step values.
3. Use Go to A explicitly, verify A visually, and run A to B without recording. Go to a mark and
   running from it are separate actions. Confirm the reverse direction independently.
4. Repeat during normal recording. Change the launch duration, delay, easing and cadence between
   runs to establish achievable timing. Compare equal travel at different rates; changing the
   increment size requires Reset and new marks.
5. Exercise Stop during delay, between increments and during an active increment. Check that no
   later increment is issued, the stopped/uncertain feedback is truthful, and normal recording
   stop stays usable. Immediately trying another action must not reuse a stopped native run.
6. Verify backgrounding, Command mode, source/control loss, AF takeover, zoom/lens change and
   disconnect. Confirm that a fresh frame alone cannot restore unconfirmed readiness.
7. Inspect source recordings at 100%. Repeat at fixed 35mm and 100mm, near/middle and middle/far
   subject pairs, and both USB and Wi-Fi. A clean live JPEG or a passing simulated test is not
   evidence of repeatable optical focus.

Acceptance: ten consecutive A-B-A cycles per qualified configuration, no endpoint correction,
progressive drift, visible stepping or overshoot; timing error no greater than 0.2 seconds or 5%,
whichever is larger. Stop should acknowledge immediately in the UI and physically stop within one
second on a healthy link. Record observed latency rather than inferring it from cancellation receipt.

If equal pulse travel does not return reliably, or the rates required for smooth easing fail,
retain this diagnostic candidate and report the results before building the production editor.

## Evidence and verification

The probe stores a bounded in-memory trace. Normal display updates omit its event array. Explicit
export includes scheduled/actual command times, exact outcomes, run identity, stop requests, actual
observations and an omitted-event count. It does not contain credentials, camera serial numbers,
image data or automatic telemetry.

iOS **Save trace** writes `focus-rack-<monotonic-milliseconds>.json` into the app's Documents folder.
Retrieve it through the device container tools. Android **Export** opens the native share sheet
with a local JSON file through the existing narrow diagnostics FileProvider.

Run `just focus-rack-test` for the portable probe/wire regressions, `just native-check`,
`just android-check`, and `just check`. The opt-in iOS UI smoke test is
`RunnerUITests/FocusRackProbeSmokeTests` in the `RunnerPhysicalQualification` scheme. It takes a
landscape screenshot and accessibility snapshot, and issues no focus or recording command.
It explicitly uses a SIMULATED feed on either target; movement remains unavailable. Relaunch with
only the probe flag, without the demo feed, before connecting the real camera for qualification.

The local OpenCine candidate adds rack-specific APIs beside the existing focus dial. The original
`mfDrive` behavior stays unchanged. Its task handoff records shared verification and consumer impact.
The app's pinned revision was missing the gyro settings/metadata interfaces already used by the app;
the local dependency also contains the narrow compatibility backport from `07fcfc8`. No pin,
publication or remote project-management changes are part of this diagnostic work.

On 18 October, build caches moved to the external SSD after disk pressure interrupted verification.
The latest shared suite passes (500 tests), including the positioning/deadline regression.
The Android gate passes (933 JVM tests, including 920 app tests); the separate local diagnostic
is the only enabled OpenZCine app on the Pixel, preserving the public app's data. All six
instrumented recovery/USB fixtures pass on the Pixel 7a, covering probe layout, nudge controls,
separate repositioning/timed-run controls, persistent recovery instructions and USB consent.
Landscape recovery screenshots were inspected in expanded and collapsed states; the instruction
and Stop remain visible. Earlier setup, Clean, interface lock and portrait screenshots were also
inspected. The original automatic rotation setting and 30-second display timeout were restored.

First-use USB testing exposed a discovery dead end: Android detected a complete ZR PTP interface,
but the shared first-run page hid the device before USB consent and offered no Allow action.
The existing Android pairing extension now presents pending/denied devices with explicit Allow.
After consent, normal discovery supplies the selectable camera. Enumeration follows the foreground
discovery owner. This is an Android USB-host permission repair; iOS already requests its
ImageCaptureCore session on attachment. The fixture test covers denial, retry and successful grant. Whole-display landscape captures
confirm the consent row stays visible in all three states; a separate capture verifies the
probe setup remains expanded after a nudge.
Real-camera verification now confirms explicit USB consent, ZR connection and live movie view on
the Pixel. Initial mark capture was blocked while live-view metadata reported tracking active;
Set A became available after subsequent frames reported tracking clear.

The first operator-driven USB trial used the experimental 8-pulse increment at the reported
70mm/F2.8 setup. Four separate Far commands returned complete in 127-143ms each. The operator
reported no visible focus change. Resets occurred during setup, and the retained trace ends
without marks; this is not a repeatability or optical-motion result. No A-B-A cycle or source
recording has been qualified. Android also collapsed setup after every nudge, hiding the controls
needed to establish B; the local follow-up keeps setup visible, matching iOS.

A subsequent 64-pulse USB trial produced visible movement. The operator reported matching A
sharpness after a one-step reversal and after returning from B at relative position 20. The
exported trace contains 86 completed commands with 126-199ms adapter durations; the final
20-command reposition took 4.252 seconds. These are command timings, not measured lens travel.
After relaunching with fresh marks, an eight-second Ease in-out rehearsal with a two-second
start delay reached sharp B and looked smooth in the live view. The reverse timed pull also
reached sharp A while recording continued. Those two timed runs began movement after 2.001s
and completed movement in 8.059s and 8.071s respectively, within the requested timing tolerance.

The operator reported ten further cycles, but the trace contains twelve repositioning returns
using Go A/Go B (4.188-4.432s each), not twenty timed runs. No events were omitted. The ten-cycle
timed acceptance is therefore **not passed**. The follow-up labels both timed actions Run and
separates their Android row from Go controls; verification must use Run A to B and Run B to A.

Cancellation during the delay acknowledged immediately with no observed movement. The camera
was already in Standby before the subsequent authorized automatic cancellation trial. That trial
requested Stop 93.8ms into an active chunk; the native driver returned cancelled-and-ready
39.7ms later and invalidated the unknown position. The operator reported stopping within one
second with no later motion. This does not prove recording-stop priority during active movement.
The newest retained camera file is DSC_1670.MOV: 504,238,539 bytes, 335.209875 seconds,
3840x2160 HEVC Main 10 at 24000/1001 fps. Its byte-for-byte private cache copy is on the SSD.
Although the playback UI labels it PROXY, the inspected file contains native 4K frames; no app
transcoding was used. Unscaled native-pixel crop inspection confirms one recorded timed B-to-A
pull and six later seek round-trips. The foreground returns look broadly consistent, but scene
brightness, focus breathing and codec texture variation prevent a smoothness or zero-drift claim.
The private report and crops are retained beside the recording on the SSD. Ten timed cycles,
optical smoothness and recording-stop priority remain unqualified.

A later setup used new marks A=0/B=23 after the operator repositioned the camera. The retained
trace confirms a complete timed A-to-B-to-A round-trip: delays 2.003s/2.000s and total durations
10.062s/10.057s. The operator reported sharp endpoints and smooth motion. Source-footage review
for this new framing remains pending. A subsequent no-delay reposition stalled on its 21st
increment. That native call lasted 2.783s; safety evidence expired and requested Stop 1.824s into
it, followed by an unconfirmed native outcome 0.959s later. Its actual displacement is unknown,
and reconnection is required. These results do not pass ten-cycle acceptance.

That export also exposed repeated idle invalidation warnings (19,418 retained invalidations,
37,000 omitted events). Invalidation now latches on the loss of the position reference, preserving
the first causal event instead of repeatedly overwriting terminal state and filling the trace.
The shared snapshot supplies a short recovery instruction for both panels outside scrolling
setup; full diagnostic details still scroll. Unconfirmed movement explicitly requires reconnection
before Reset. The focused rack/wire suite passes 32 tests.

Additional native detail is opt-in at compile time with `OPENCINE_FOCUS_RACK_TRACE`; normal builds
leave it off. It records up to 32 short rows per chunk: phase, raw response, polling limit,
stop request, transport failure and outcome. Buffered rows flush only after native wire work.
Android uses only the current JNI call's environment and isolates logger-created Java exceptions;
it never reuses the retired connection listener. The trace includes no payloads, frames, camera
serials or credentials. It does not alter polling, timing, cancellation or unknown-position rules.
The full OpenCine Swift suite passes with strict concurrency: 3,227 Swift Testing cases and
177 XCTest cases. Both updated diagnostic apps are installed. Their simulated device UI checks pass; this does
not qualify optical behavior.

Tracking admission now accepts the same raw header evidence on both shells and resolves it in
portable Swift. Subject detection alone is distinct from an active tracking lock. Missing focus
metadata remains unknown and blocks capture; the feedback distinguishes missing metadata from
active tracking.

The signed local diagnostic also installs and launches on the iPhone 17 Pro Max. The final smoke
passes: 44pt hit areas, setup scrolling, collapsed transport, Clean, interface lock and settled
portrait orientation. Landscape and portrait screenshots were inspected after redeployment.
The portrait panel is bounded so Stop, recording and the home indicator remain clear.
The latest rerun handles the observed Local Network permission prompt specifically and passes
on the iPhone, with new landscape and portrait captures inspected. The panel reserves the actual
camera-values row and keeps Stop at least 10pt above its readouts; scrolling exposes both explicit
Run actions without clipping the fixed transport controls. Android's landscape fixtures
also pass after unlock; the temporary display timeout was restored to its original 30 seconds.
Canonical iOS and Watch simulator builds also pass. No optical movement was issued by these tests.

`just native-check` now passes: 500 shared tests, 296 iOS XCTest cases (two existing skips),
151 iOS Swift Testing cases, and the iOS and Watch builds. The earlier media/gyro composition
failures were reproduced as an unavailable simulator accessibility tree. With feature sources
unchanged, enabling the private simulator's real application accessibility service made all
focused failures pass, followed by the full native gate. The temporary preferences were removed
and the private simulator returned to its original shutdown state. This is a simulator test
prerequisite, not a product-code fix or a hardware qualification result.

`just check` still stops at the unchanged Google Play release notes (six bullets where the guard
allows five); the history secret scan also has two existing findings. These are not waived.

## Latest 70mm USB retry

A fresh Android USB session used fixed 70mm/F2.8 and A=0/B=22. The operator completed ten full
timed A-to-B-to-A cycles without correction and reported sharp endpoints throughout. The export
contains all twenty alternating timed runs, each with 22 completed increments: 440 timed
increments, no native failures and no omitted trace events. Measured host delays were
2.000-2.031s; host movement spans were 8.031-8.096s for the requested eight seconds. These
command timings meet the requested tolerance; later operator source review failed smoothness.
The previous stalled native command did not recur, and its cause remains unresolved.

The operator then stopped recording during another timed pull and reported focus stopping within
about one second and remaining still. The trace stops between increments after eight completed
steps, retains relative position 8, and schedules no further command. This tests recording-stop
priority between chunks; it does not add an active-chunk cancellation measurement. A private app
screen recording was retained. Entering the export share sheet afterward invalidates the session
reference as expected; no automatic return was requested.

The new source recording is DSC_1673.MOV. Direct camera-to-Mac import retrieved the complete
1,064,693,454-byte file: 376.000625s, 3840x2160 HEVC Main 10, 24000/1001 fps and 9,015 frames.
The private original and SHA-256 fingerprint are retained on the SSD; camera deletion after
import was verified off. Android playback had stopped after 20MiB with a USB response-read error.
Its partial cache was preserved; this is not a decoder or optical-focus finding.

Native-pixel source review now supports no progressive visible focus loss at either endpoint
across all ten cycles. All twenty settled arrivals were inspected with unscaled crops. All 9,015
source frames were also measured for motion navigation, with consecutive native-frame inspection
of first, middle and last pulls and each pull's largest contour change. No obvious abrupt jump or
endpoint overshoot appeared in those inspected sequences. Approximate optical response spans
of 7.92-8.17s support the eight-second target with several-frame boundary uncertainty.

Small real changes and holds remain visible in the measurements. Frame inspection alone left
the strict no-visible-stepping gate inconclusive. First, middle and last normal-speed native-size
crop reels were prepared; lossless 10-bit crops are retained, with separate 8-bit H.264 copies for
convenient playback. No source scaling or grading was applied.

The operator then reported, "I can see stepping or jumps" during playback review. This fails the
practical smoothness gate for this profile. Work stops at the diagnostic milestone, preserving
the source, traces, reports and both local implementations. At that checkpoint, no further
motor test was started; the operator subsequently requested the iPhone comparison below. This
finding does not establish that every drive profile, focal length or camera transport must fail.
Other focal lengths, subject pairs and transports remain unqualified. The earlier intermittent native stall and media USB read failure also
remain unresolved. No push, PR, release, board update, SDK commit or pin move was made.

## iOS diagnostic comparison after the failed Android profile

After the failed smoothness result was reported, the operator explicitly requested testing the
connected iPhone. This resumes diagnostic comparison only. The failed Android result remains
in force; the production editor remains gated. The same installed iOS candidate was launched in
real-camera mode with 64 pulses, an 80ms quiet period, eight-second Ease in-out and two-second
delay. Launch does not initiate movement. A new camera connection and fresh session marks are
required. The short recorded comparison tests whether the visible stepping also occurs through
iOS; it is not a substitute for the remaining physical acceptance matrix.

The iOS comparison captured one recorded A-to-B-to-A cycle at fresh A=0/B=23 marks. Both 23-step
runs completed: delays 2.001s, host movement 8.061s and 8.091s, returning to A. All 142 commands
in the retained setup-and-run trace reported complete; zero events were omitted. The earlier
setup included a tracking-related invalidation, followed by Reset and fresh marks before the
timed runs. The cause of that tracking observation was not established.

The operator reported both endpoints sharp and the movement smooth in live view. Direct Mac
import preserved DSC_1674.MOV: 100,802,092 bytes, 35.5355s, 3840x2160 HEVC Main 10 at 24000/1001fps,
852 frames. Native endpoint comparisons support sharp returns for this single cycle; source
motion analysis shows discrete changes separated by holds in both directions. The operator then
reviewed the normal-speed native-size playback copy and answered, "Stepping or jumps are also
visible on iPhone." This fails the practical smoothness gate for the iOS profile as well.

This is one iOS cycle, with 23 increments rather than Android's 22 and a different framing. It
cannot isolate platform causality or satisfy the ten-cycle acceptance matrix. Both tested USB
paths now have a failed source-playback smoothness result. Work stops at this diagnostic
milestone. A smaller reliable increment and sufficient command cadence are possible subjects
for a later diagnostic iteration, not established fixes. No production-editor work, protocol
changes or remote actions were made.

## Finer increment and faster cadence experiment

The operator requested a further local diagnostic iteration after both source-playback failures.
The new candidate uses 16 pulses per increment and a 10ms quiet period, initially retaining the
eight-second Ease in-out pull and two-second delay. These settings are unqualified. Fresh marks
are required; four times as many increments is only an estimated equivalent span.

Both native rack executors now consume the same shared readiness-wait schedule: after Busy,
the first six waits are 20ms and the next ten are 120ms. Seventeen Busy responses exhaust each
driving/confirmation phase. This retains the previous 1.32s cumulative sleep budget per phase;
it adds five readiness transactions and is not a whole-chunk wall-clock deadline. An immediate
Ready response still requires no sleep. The ordinary focus dial's budget is unchanged.
Cancellation and actual readiness confirmation remain required, with the same uncertain-movement
outcomes. The opt-in native trace cap is 48 rows to retain terminal evidence at both poll limits.

The probe now measures successful dispatch-to-completion durations in the current reference.
Timed admission uses the longest observed command duration plus the configured quiet period.
Reset clears that estimate. This is conservative observed evidence, not a guarantee of future
latency; runtime deadlines still halt late work without a catch-up burst. Final completion also
checks duration tolerance. A timing failure retains an acknowledged endpoint and reports failure
instead of claiming a successful timed rack.

Both diagnostic setup panels add Near x4 and Far x4 controls. Each issues four separately
acknowledged increments of the same size used for single-step setup, returns and timed playback.
Stop discards the remaining increments; a partial chunk still invalidates the relative reference.
Single-step controls remain available for fine adjustment. These are probe controls, not the
production editor. Source smoothness, repeated returns and cancellation must be requalified.

Focused verification passes: 46 shared probe/facade tests and 28 native sequencing, wire and
command-admission tests, including the opt-in tracing build. `just native-check` passes with
514 shared tests, 296 iOS XCTest cases (two existing skips), 151 iOS Swift Testing cases and
both builds. `just android-check` passes with 935 JVM tests, lint and instrumentation compilation.
The iOS simulated smoke and ten Android emulator fixtures pass; landscape and portrait edges,
timing controls and persistent Stop were inspected after installation. `just check` still stops
at the unchanged Play release-note bullet limit. All changes and recordings remain local.

### Finer-step short-return evidence and timing sweep

Two separate iPhone USB checks used four positive 16-pulse commands followed by four negative
commands. Both returned from relative 0 to 4 to 0, with the operator reporting A sharp without
correction. Each retained trace contains eight completed commands and zero omitted events.
First-check host durations were 67.9-155.2ms (median 124.2ms); the shortest completion-to-next-start
quiet period was 10.51ms. The second check measured 66.7-137.2ms (median 102.5ms). These include
host dispatch, queueing and native completion; they are not isolated physical lens timings.
Neither check establishes a long-span rack, ten-cycle repeatability or source smoothness.

The iPhone console captured normal app logs but filtered the rack's debug-level rows. Only the
opt-in native trace now uses notice level so those bounded rows can be collected through the
same private console. Camera execution, ordinary focus and default-disabled tracing are unchanged.

The diagnostic panels now offer duration presets of 8, 16, 24 and 32 seconds plus Linear and
Ease in-out. Shared Swift accepts timing edits only while idle, preserves marks and pulse size,
and records each timing change and each run's actual requested timing in the trace. Changing
duration needs no reconnect or new marks. The final command reserves observed completion cost;
the quiet period is reserved only between commands. This avoids a false early-arrival failure.

The dense 92-step synthetic regression admits and completes an eight-second eased move with
40ms native cost and 10ms quiet, and rejects 50ms native cost. That does not qualify the actual
lens: the measured short-return calls are slower. Android's matching candidate is installed on
the retained emulator; finer-profile physical Android testing remains open. The baseline 64-pulse
source-playback failures remain valid.

### Finer-step full-span setup

The C3 iPhone USB setup established fresh A=0/B=90 marks. The operator reported A sharp again
after the return, without correction. All 204 setup/return commands completed; no trace events
were omitted. Host call durations were 10.7-162.0ms (median 82.7ms), with native durations of
10.6-161.9ms (median 81.2ms). The same-process monotonic timestamps correlate all commands and
place most measured cost inside the native call. This includes wire and queueing costs and does
not measure physical lens position or motor completion independently.

For this 90-step span, the longest observed call plus the 10ms quiet period requires about
15.47s Linear or 23.12s Ease in-out. An eight-second pull is therefore not admitted on this
evidence. The first requested recorded trial is 16s Linear with the existing two-second delay.
This provides measured scheduling headroom only; later latency can still stop a run. The first
recorded result follows below; ten-cycle repeatability remains unqualified.

### First recorded finer-step trial

The operator completed one recorded A-to-B-to-A cycle at A=0/B=90 with 16s Linear and a two-second
delay, reporting sharp endpoints and smooth movement in live view. All 180 timed commands
completed; the combined setup/run trace has 384 completed commands, 851 events and zero omitted
events. Every command matches a successful native row within its host-call interval.

| Move | Host start delay | First dispatch to last completion |
| --- | --- | --- |
| A to B | 2.001s | 15.918s |
| B to A | 2.001s | 15.907s |

Both arrival times pass the 0.8s tolerance for a 16s request. Planned Linear command spacing was
177.96ms; actual start gaps ranged from 82.53ms to 286.72ms. No calls overlapped and the shortest
completion-to-next-start quiet period was 10.16ms. The anchored schedule recovers lateness with
shorter subsequent gaps: this supports no immediate queued burst, not perfectly uniform cadence
or a claim that no phase recovery occurs. All timed calls completed within the early 20ms polls;
none reached the 120ms backoff.

Direct Mac import preserved DSC_1675.MOV: 155,384,371 bytes, 60.935875s, 3840x2160 HEVC Main 10,
24000/1001fps and 1,461 frames. Camera deletion after import was off. Native-size endpoint crops
show comparable detail at initial and returned A; B remains stable during its hold. Approximate
source motion intervals are 13.2-13.5s to 29.0-29.4s and 38.3-38.6s to 54.2-54.6s, consistent with
roughly 16s travel with several-frame uncertainty. These observations do not measure exact motor
latency or prove perceptual smoothness.

The full-duration, unscaled near/far crop reel retains all source frames at the original frame
rate. Decoded 10-bit lossless crop pixels match the decoded source crops byte for byte. An 8-bit
H.264 convenience copy is available for normal-speed operator review. After reviewing both pulls,
the operator answered, "Both pulls look smooth." This passes practical smoothness for this one
recorded iPhone USB cycle. One cycle does not establish ten-cycle repeatability; other focal
lengths, subject pairs, Wi-Fi, finer-profile Android and new-cadence cancellation remain open.
This slower Linear trial also cannot isolate the effect of smaller increments from duration or
easing changes. The next physical check is ten consecutive recorded timed cycles at this profile,
with fresh marks after reconnect and no focus corrections during the sequence.

### Finer-step repeatability setup

After reconnecting, the operator moved the camera slightly before setting fresh A=0/B=94 marks,
then reported A sharp again without correction. The post-reset trace has 194 completed setup and
return commands, all successful, with zero omitted events. Host call durations were 13.4-159.8ms
(median 79.8ms). The resulting observed Linear minimum is 15.951s, leaving only 0.049s of admission
headroom at 16s. This admits the current request; it does not guarantee later command latency.

Ten consecutive recorded timed A-to-B-to-A cycles have been requested from these fresh marks,
with no Go actions or focus correction. The operator must stop at the first warning, disabled
control, drift, stepping or overshoot. During the attempt, the operator reported the admission
warning, "this move needs at least 16.60 seconds at the test cadence." The ten-cycle test has not
passed. The retrieved trace confirms one complete 16s A-to-B-to-A pair, followed by another
mark setup. Forward/reverse delays were 2.001s; movement spans were 15.993s and 15.868s. All 574
post-reset commands completed successfully, with no omitted events. The current ledger is A=0,
with A=0/B=94 marks and recording stopped. No uncertain movement or native refusal is recorded.

The longest successful command was a 166.724ms single near nudge during the later setup, raising
the calculated Linear minimum to 16.602s. The completed timed pair predates the latest mark
replacement and cannot count toward a new ten-cycle sequence. A single 24s Linear round trip
with the existing two-second delay and marks is now requested, giving about 7.4s more observed
admission headroom. No Reset, mark replacement or Go is requested. Its source smoothness must be
reviewed before repetition; no 24s result is claimed yet. The earlier B=90/16s one-cycle source
pass remains valid for that test only.

The previous iPhone native console ended after a CoreDevice XPC connection invalidation. No
native-row capture is claimed for the new setup. The saved probe trace still records command
dispatch, completion, outcomes and reference state; no app restart was forced during setup.

### First 24s Linear trial

The operator completed one recorded A=0/B=94/A=0 pair at 24s Linear with the existing two-second
delay and marks, reporting sharp endpoints and smooth live-view movement. The trace confirms
188 successful timed increments, zero omissions, and no new nudge, Go, mark replacement or
invalidation. Forward/reverse movement spans were 23.913s/23.852s, with delays 2.001s/2.003s.
No overlapping calls, quiet violations or missed deadlines occurred. A 177.560ms reverse command
raised the observed next-run Linear minimum to 17.621s, leaving about 6.4s at the current setting.

The saved state was A=0 with recording stopped and fresh safety evidence. This uses host trace
evidence; no new native console is available. Source import preserved DSC_1678.MOV: 163,935,987
bytes, 60.810750s, 3840x2160 HEVC Main 10 at 24000/1001fps, with all 1,458 frames. Deletion after
import was off and the normal import destination was restored afterward.

Native endpoint crops support comparable initial and returned A detail and a stable B hold.
The finial's front-surface mark is sharper at A, while its rear silhouette sharpens inside the
pull; these different depths must not be confused with execution overshoot. Approximate optical
intervals are 3.5-3.8s to 27.4-27.8s and 32.5-32.9s to 56.7-57.1s, consistent with roughly 24s
travel with several-frame uncertainty. Both transitions and settled endpoints are fully recorded.

The operator reviewed normal-speed unscaled playback and answered, "Both pulls look smooth."
Lossless 10-bit crop pixels match the decoded source crops byte for byte; the convenient H.264
preview retains all frames at the original frame rate. This passes smoothness for this one
iPhone USB cycle, not ten-cycle repeatability or the wider matrix.

The next operator instruction combines reconnection, fresh A/B setup once and ten consecutive
recorded 24s Linear cycles with a two-second delay. Only Run actions are allowed during those
twenty pulls; no Go, mark replacement or focus correction. The operator must stop at the first
warning, disabled control, drift, stepping or overshoot and leave focus where it stops. No repeat
result is reported yet. The earlier isolated trials do not count toward this fresh sequence.

### Corrected repeat count and local implementation scope

The operator corrected the latest count to **eight timed pulls: four full A-to-B-to-A cycles**,
then ended further physical testing for this iteration. The fresh A=0/B=94 trace agrees: 752 timed
increments across eight alternating runs, all complete, with no omitted events, intervening Go,
mark replacement or correction. Delays were 2.001-2.090s; movement spans were 23.833-24.067s.
Arrival error was -0.087 to +0.069s against the requested delay plus duration, within tolerance.
The final saved position is A=0 with recording stopped. The operator reported both marks sharp.

This repeat recording has not been inspected in source playback, and no new native console was
captured. Four cycles do not satisfy the original ten-cycle criterion. Firmware versions, other
focal lengths and subject pairs, Wi-Fi, finer-profile Android and cancellation with the finer
profile remain unverified. The earlier two isolated iPhone USB source-smoothness passes remain
limited to those recordings. No further camera movements or physical test requests are pending.

At the operator's request, local software implementation now continues with the existing
16-pulse/10ms path: shared execution state, Pause/Resume, timing templates and the Marks/Move UI
on both shells. Deterministic tests, fake-camera tests and simulator/emulator checks can establish
software behavior; they do not close the remaining optical qualification. Nothing is pushed,
published or released.
