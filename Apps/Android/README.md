# OpenZCine Android

Production Jetpack Compose shell — early scaffold. One placeholder monitor screen
(black feed area, "No camera" state) wired through the camera-core seam.

- **Build:** `just android-build` from the repo root (or `just android-check` for build + tests + lint).
- **Core seam:** `core-api/` is a pure-JVM module defining `CameraSession`, `LiveFrameSource`, and
  `CameraIdentity`. Either the shared Swift core (via JNI) or a Kotlin port plugs in behind it —
  the shell never sees which. Feasibility call tracked in
  `docs/investigations/android-core-feasibility.md` (forthcoming).
- **Local SDK:** put `sdk.dir=<your Android SDK path>` in `Apps/Android/local.properties` (gitignored).
