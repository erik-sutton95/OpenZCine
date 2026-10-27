# Gyro logging for Gyroflow

OpenZCine can record this phone's gyroscope while it monitors one directly connected Nikon camera.
The phone must be rigidly mounted to that camera throughout each take. This is an experimental
logging feature; stabilization quality still requires validation with the actual rig. The workflow
is available on iOS and Android.

## Arm and record

1. Fix the phone firmly to the camera, connect directly, open live view and keep recording stopped.
2. Enable **Log gyro with camera recordings** in Operator Setup. Turning Gyro on opens the setup.
3. If camera stabilization is on, choose **Turn off IBIS** to turn off IBIS and Electronic VR through
   the camera's normal control queue. **Keep it on** leaves them unchanged and marks the session.
   OpenZCine restores the prior values when Gyro is disarmed or the camera session ends.
4. Follow the ring calibration, or choose **Use last calibration** when the phone has not moved in
   its holder on this camera. You can also continue without calibration; those logs are marked
   **Not calibrated**.
5. Keep OpenZCine in the foreground and wait for **GYRO ARMED**. Start and stop recording from the
   app, camera button, or connected remote. Camera-reported recording transitions create one log
   per take.

Relay viewers, multicam sessions and demo sessions do not write camera stabilization settings.
Logging never starts or stops the camera. Devices without a gyroscope report the feature as
unavailable.

## Ring calibration

Keep the phone fixed in its holder and move the whole rig through the three guided poses. The ring
shows when the camera and phone readings are usable, whether the rig is moving, and when to hold
still. Complete each hold to advance. The final pose independently verifies the measured alignment.
Disconnecting, backgrounding, changing camera or starting recording invalidates an unfinished
calibration without removing a previously saved one.

Calibration determines the phone-to-camera axes without using display orientation. Repeat it after
the phone moves in its holder. There are no mount presets or angle entry controls. A saved
calibration belongs to its camera body and is copied into a take at REC; later changes never modify
that take, its postroll or recovery.

Calibrated gyro samples are rotated once into camera axes before writing. Their GCSV header is
`orientation,XYZ` with `orientation_status,calibrated`. Leave additional IMU rotation at zero in
Gyroflow for these logs. Calibration does not synchronize the video or select a lens profile.

## During and after a take

The logger requests 100 Hz and uses actual sensor timestamps. It keeps motion before and after the
observed recording boundaries, so adjacent takes can share some samples and a log can be longer
than its movie. These are capture diagnostics, not proof of synchronization.

If the phone moves in its holder during a calibrated take, the monitor shows **MOUNT MOVED**. After
the take, OpenZCine offers to recalibrate. The log keeps the first detected mount move and its
approximate offset from REC. Check the take carefully before relying on it.

Starting logging during a take creates a partial log. Backgrounding, disconnecting, disabling
logging, a stalled sensor, or a storage error preserves available samples as interrupted.
Recoverable partial files are retained after an unexpected app exit. Files that cannot be recovered
remain visible as incomplete and can be deleted. Only finalized logs can be shared.

## Logs and sharing

Open Operator Setup → Storage → **Gyro logs**. The list marks each take **Recording**, **Ready**,
**Not calibrated**, **Small gaps**, **Cut short**, or **Mount moved**. It also shows delivered sample
rate, largest sample gap and an approximate REC offset. A negative offset means motion capture
began after the observed REC start.

Use **Share log** for one take, or **Select** to choose several. Share the `.gcsv` files to a
computer, and transfer the matching camera movies separately. Logs live outside the downloaded
media cache and are retained until explicitly deleted.

## Gyroflow

1. Open the camera video in Gyroflow and select the matching camera and lens profile.
2. Load the take's `.gcsv` motion log. For a calibrated log, keep the imported `XYZ` orientation and
   leave additional rotation at zero. For an uncalibrated log, set the alignment in Gyroflow.
3. Use the displayed approximate REC offset as a starting estimate, then synchronize against
   visible camera movement. Check stabilization near the beginning, middle and end.

The app records no reference audio, imports no camera video for synchronization, and includes no
lens profiles or stabilization renderer. GCSV files contain timestamped gyro axes only;
accelerometer-based horizon lock is outside this first version.

For the first ZR test, use a fixed focal length and disable camera and lens stabilization. The phone
measures body motion and cannot observe independent sensor or lens stabilization. Check a short
take and a take of at least ten minutes before relying on the workflow. Sharp exposures help avoid
motion-blur artifacts in post stabilization.

See the [original idea](https://github.com/erik-sutton95/OpenZCine/discussions/212),
[Gyroflow synchronization guide](https://docs.gyroflow.xyz/app/getting-started/basic-usage/synchronization),
[GCSV specification](https://docs.gyroflow.xyz/app/technical-details/gcsv-format), and
[IMU orientation guide](https://github.com/gyroflow/docs.gyroflow.xyz/blob/main/advanced-usage/imu-orientation-and-rotation.md).
