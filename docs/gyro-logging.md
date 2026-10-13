# Gyro logging for Gyroflow

OpenZCine can record this phone's gyroscope while it monitors one connected Nikon camera.
The phone must be rigidly mounted to that camera throughout each take. This is an experimental
logging feature; stabilization quality still requires validation with the actual rig.

## Capture

1. Open Operator Setup → Controls and enable **Log gyro with camera recordings**.
2. Keep OpenZCine in the foreground and wait for the logger to report **Ready**.
3. Start and stop recording from the app, camera button, or connected remote. Camera-reported
   recording transitions create one motion log per take.
4. Open Operator Setup → Storage → **Gyro logs** to review, share, or delete completed logs.

The logger requests 100 Hz and uses actual sensor timestamps. It keeps two seconds of motion
before the observed recording start and two seconds after the observed stop. Adjacent takes can
therefore share some motion samples. The list shows delivered sample rate, largest sample gap,
and an approximate REC offset; these are capture diagnostics, not proof of synchronization.

Starting logging during a take creates a partial log. Backgrounding, disconnecting, disabling
logging, a stalled sensor, or a storage error preserves available samples as interrupted.
Recoverable partial files are retained after an unexpected app exit. Logging never stops the
camera. Devices without a gyroscope report the feature as unavailable.

V1 supports one directly connected camera. Relay viewers and multicam sessions are excluded.
Logs live outside the downloaded-media cache and are retained until explicitly deleted.

## Gyroflow

1. Transfer the camera video and its matching `.gcsv` log to the computer.
2. Open the video in Gyroflow and load the motion log. A log can be longer than the video.
3. Select the camera/lens profile and set the phone-to-camera IMU orientation and rotation.
   Exported device axes are marked unverified; screen rotation is not mount calibration.
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
and [GCSV specification](https://docs.gyroflow.xyz/app/technical-details/gcsv-format).
