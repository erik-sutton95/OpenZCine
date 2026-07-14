# Android distribution (Google Play internal testing)

Signed Android App Bundles are built and uploaded to the Google Play **internal testing** track by
[`play-internal.yml`](../.github/workflows/play-internal.yml). Releases are deliberate: the workflow
runs on manual dispatch or an `android-v*` tag — never on plain merges.

## Flow

```text
feature PR → CI (Gradle build + tests + lint) → merge to main
→ tag android-v* (or Actions → Play Internal → Run workflow)
→ signed .aab → Play internal track
```

The track goes live only after the [one-time Play console setup](#one-time-play-console-setup)
below, including Google's rule that the **first** `.aab` reaches the track through a manual console
upload.

## Version numbers

| Field | Source | Example |
| --- | --- | --- |
| **Version name** (Play "Release name") | `openzcine.versionName` in `Apps/Android/gradle.properties` | `0.1.0` |
| **Version code** (Play's monotonic build id) | `100 + workflow run number`, passed as `-PversionCode` | `101`, `102`, … |

This mirrors the iOS pattern ([TestFlight CI](testflight-ci.md)): the human-readable version lives
in one committed file and changes only through a reviewed PR; the machine version code is stamped
per CI build and never committed back. Local builds without `-PversionCode` fall back to
`openzcine.versionCode` in `gradle.properties`.

Adjust `ANDROID_VERSION_CODE_OFFSET` in `play-internal.yml` if it ever falls below the highest
version code already in the Play console (for example after the manual first upload).

## One-time Play console setup

Erik's checklist, in order:

1. **Create the app** — [Play Console](https://play.google.com/console) → **Create app**, package
   name `com.opencapture.openzcine` (must match `applicationId`; it is permanent).
2. **Generate the upload keystore** — locally, `just android-keystore`. It writes
   `.local/android/upload-keystore.jks` (gitignored) and prints the follow-up steps. Back up the
   file and password; enroll in **Play App Signing** (the default) so this is only the *upload*
   key and Google holds the app signing key.
3. **Service account for the API** — in [Google Cloud Console](https://console.cloud.google.com):
   create (or pick) a project, enable the **Google Play Android Developer API**, create a service
   account, and download its **JSON key**. Then in Play Console → **Users and permissions** →
   invite the service account's email and grant it release permissions (release-manager level:
   "Release apps to testing tracks" and app access for OpenZCine).
4. **First upload is manual** — Google requires the first bundle on a track to be uploaded through
   the console. Build one locally ([Local signed build](#local-signed-build)), then Play Console →
   **Testing → Internal testing → Create new release** and upload
   `Apps/Android/app/build/outputs/bundle/release/app-release.aab`. Add the internal-tester email
   list while there.
5. **Create the GitHub environment** — repo **Settings → Environments → New environment** named
   `play` (mirrors the `testflight` environment), with the secrets below. Optionally restrict it
   to `main` and tags, or require approval.

## GitHub `play` environment secrets

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i .local/android/upload-keystore.jks \| pbcopy` |
| `ANDROID_KEYSTORE_PASSWORD` | Store password entered during `just android-keystore` |
| `ANDROID_KEY_ALIAS` | `upload` (the alias the recipe creates) |
| `ANDROID_KEY_PASSWORD` | Same as the store password (PKCS12 keystores share it) |
| `PLAY_SERVICE_ACCOUNT_JSON` | Full contents of the service-account JSON key file |

No keystore, password, or service-account JSON is ever committed — `.gitignore` blocks `*.jks`,
`*.keystore`, and `.local/`, and `just check` runs gitleaks over history.

## Running the workflow

- **Tag release** — `git tag android-v0.1.0 && git push origin android-v0.1.0` (any `android-v*`
  tag).
- **Manual** — **Actions → Play Internal → Run workflow**.

Either way the workflow runs Gradle tests + lint, computes the version code, decodes the keystore
secret to a runner temp file, builds `bundleRelease` signed via the `ANDROID_KEYSTORE_*`
environment variables, and uploads to the `internal` track with
[r0adkll/upload-google-play](https://github.com/r0adkll/upload-google-play) (pinned by digest;
Google publishes no official Play-upload action, and this is the best-maintained community one).

## Local signed build

```bash
just android-keystore                     # once; writes .local/android/upload-keystore.jks
export ANDROID_KEYSTORE_PATH="$PWD/.local/android/upload-keystore.jks"
export ANDROID_KEYSTORE_PASSWORD='...'
export ANDROID_KEY_ALIAS=upload
export ANDROID_KEY_PASSWORD='...'
cd Apps/Android && ./gradlew bundleRelease
# → app/build/outputs/bundle/release/app-release.aab
```

With the `ANDROID_KEYSTORE_*` variables unset, `bundleRelease` still succeeds and produces an
**unsigned** bundle — useful for structure checks; Play will reject it, so signing is required for
any real upload. The debug path (`just android-build` / `android-check`) never needs signing
variables.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Workflow skipped | Fork — it only runs on `erik-sutton95/openzcine` |
| `ANDROID_KEYSTORE_BASE64 is not set` | `play` environment or its secrets missing |
| Upload fails with 403 / "not found" | Service account lacks release permission, or the app was never created in the console |
| "Package not found" on first CI upload | The mandatory manual first upload (step 4) hasn't happened yet |
| "Version code already used" | Raise `ANDROID_VERSION_CODE_OFFSET` in `play-internal.yml` |
| Play rejects the bundle signature | Wrong keystore secrets, or Play App Signing expects a different upload key — reset the upload key via Play support |
