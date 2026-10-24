# A/B focus-rack qualification

Status: **software regression coverage is in place; the physical qualification matrix remains open**.
This summary accompanies [discussion 11](https://github.com/erik-sutton95/OpenZCine/discussions/11)
and the current [Focus Rack workflow](../focus-racks.md).

## Recorded findings

- Timed MFDrive trials showed that regular command acknowledgments and sharp endpoints can still
  produce visible stepping. Earlier coarse and ten-command profiles did not establish acceptable
  smoothness and are not production alternatives.
- The revised three-second planner schedules smaller movements and safety reads together.
  The operator judged the subsequent Mac USB source comparison much better in both directions.
  This is evidence for that lens, scene and transport, rather than qualification of every setup.
- Native AF-F with Auto-area AF produced source-reviewed smooth transitions when targeted from
  the iPhone. The low-contrast near subject sometimes required retries. The camera's g6 AF speed
  controls its transition; Native AF does not promise an exact requested duration or acquisition
  of every subject.
- A six-second Timed Rack regression terminated after early successful commands when a
  maintenance-read timing budget was exceeded. Timing-only overruns now extend the schedule and
  warn. Offline coverage checks completion with serialized safety reads; fresh recorded acceptance
  of the current six-second path remains open.

Temporary launch overrides, private trace exporters and obsolete profile selectors have been
removed from production code. Historical captures remain local working evidence. New tests use
the normal production modes and controls; see the workflow for setup and interruption behavior.

## Remaining physical acceptance

Use the same actual lens, zoom, scene and transport for each comparison. Review the original
recording at normal speed and verify sharp endpoints. Host command timing is supporting evidence,
not optical acceptance.

- Compare current Timed Rack 1/3/6-second targets in both directions on iOS and Android.
- Repeat round trips and check endpoint drift, smoothness and timing warnings over longer runs.
- Exercise Pause/Resume, Stop, recording stop and connection loss, including a pending safety read.
- Verify Native AF acquisition and target selection on subjects with different contrast.
- Check automatic AF setup and restoration after close, preserving manual changes and deferring
  restoration while recording or focus movement is active.
- Extend coverage to other lens/zoom combinations and USB/Wi-Fi transports.

Camera-free unit and UI tests verify software behavior and layout. They do not replace these
recorded checks or establish universal optical performance.
