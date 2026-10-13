# Gyro logging for Gyroflow

OpenZCine can record this phone's gyroscope while it monitors one connected Nikon camera.
The phone must be rigidly mounted to that camera throughout each take. This is an experimental
logging feature; stabilization quality still requires validation with the actual rig.

## Capture

1. Open Operator Setup → Controls → **Phone mount** and configure the phone's fixed position.
   Enable **Log gyro with camera recordings**.
2. Keep OpenZCine in the foreground and wait for **GYRO ARMED** on the monitor.
3. Start and stop recording from the app, camera button, or connected remote. Camera-reported
   recording transitions create one motion log per take.
4. Open Operator Setup → Storage → **Gyro logs** to review, share, or delete completed logs.

The logger requests 100 Hz and uses actual sensor timestamps. It keeps two seconds of motion
before the observed recording start and two seconds after the observed stop. Adjacent takes can
therefore share some motion samples. The list shows delivered sample rate, largest sample gap,
and an approximate REC offset from the first retained sample, matching Gyroflow's imported
time origin. A negative offset means motion capture began after the observed REC start.
These are capture diagnostics, not proof of synchronization.

Starting logging during a take creates a partial log. Backgrounding, disconnecting, disabling
logging, a stalled sensor, or a storage error preserves available samples as interrupted.
Recoverable partial files are retained after an unexpected app exit. Logging never stops the
camera. Devices without a gyroscope report the feature as unavailable.
Files that cannot be recovered remain visible as incomplete and can be deleted. Only finalized
logs can be shared.

V1 supports one directly connected camera. Relay viewers and multicam sessions are excluded.
Logs live outside the downloaded-media cache and are retained until explicitly deleted.

## Phone mount

Choose which way the screen faces and where the phone's USB-C edge points. Directions are
viewed from behind an upright camera. These presets assume the phone screen is parallel to
the camera's back, perpendicular to the lens axis, and the phone has portrait natural sensor
axes, as on iPhone. The camera's movable rear screen does not determine this alignment.
Android devices with another natural sensor frame retain the unconfigured option.

The selection is saved and copied into each take when REC is observed. Changing the setting
affects future takes; it never relabels an existing recording or its postroll. Turning the
whole rig or rotating the app's display does not change the fixed phone-to-camera alignment.
The take list shows the mount that was used, including after recovery or an app restart.

| USB-C edge points | Screen toward you | Screen toward lens |
| --- | --- | --- |
| Down | `YxZ` | `YXz` |
| Left | `xyZ` | `Xyz` |
| Right | `XYZ` | `xYz` |
| Up | `yXZ` | `yxz` |

These mappings follow Gyroflow's camera-up, camera-left, camera-backward coordinate system.
Raw readings remain in fixed phone axes; the GCSV orientation header tells Gyroflow how to
apply the selected mapping once. The header marks the mount as operator-selected, rather
than claiming that it was measured or hardware-calibrated.

**Unconfigured** is the default and also applies to older logs. For a tilted or otherwise
unsupported holder position, leave the mount unconfigured and set its alignment in Gyroflow.
A short initial rig test should confirm the selected preset's direction and stabilization.
The logger does not infer camera mounting from the phone's portrait/landscape display state.

## Gyroflow

1. Transfer the camera video and its matching `.gcsv` log to the computer.
2. Open the video in Gyroflow and load the motion log. A log can be longer than the video.
3. Select the camera/lens profile. Gyroflow reads a configured mount's IMU orientation from
   the log automatically. For unconfigured mounts, set the IMU orientation and rotation there.
4. Use the displayed approximate REC offset as a starting estimate, then synchronize against
   visible camera movement. Check stabilization near the beginning, middle, and end.

The app records no reference audio, imports no camera video for synchronization, and includes
no lens profiles or stabilization renderer. GCSV files contain timestamped gyro axes only;
accelerometer-based horizon lock is outside this first version.

For the first ZR test, use a fixed focal length and disable camera/lens stabilization. The phone
measures body motion and cannot observe independent sensor or lens stabilization. Check a short
take and a take of at least ten minutes before relying on the workflow. Sharp exposures help
avoid motion-blur artifacts in post stabilization.

See the [original idea](https://github.com/erik-sutton95/OpenZCine/discussions/212),
[Gyroflow synchronization guide](https://docs.gyroflow.xyz/app/getting-started/basic-usage/synchronization),
[GCSV specification](https://docs.gyroflow.xyz/app/technical-details/gcsv-format), and
[IMU orientation guide](https://github.com/gyroflow/docs.gyroflow.xyz/blob/main/advanced-usage/imu-orientation-and-rotation.md).
