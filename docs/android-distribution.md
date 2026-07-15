# Android distribution (Google Play internal testing)

Signed phone and Wear OS Android App Bundles are built and uploaded to their Google Play
**internal testing** tracks by [`play-internal.yml`](../.github/workflows/play-internal.yml).
Releases are deliberate: the workflow runs on manual dispatch or an `android-v*` tag, never on
plain merges.

## Flow

```text
feature PR → CI (Gradle build + tests + lint) → merge to main
→ tag android-v* (or Actions → Play Internal → Run workflow)
→ signed phone + Wear .aab files → Play phone + Wear internal tracks
```

The track goes live only after the [one-time Play console setup](#one-time-play-console-setup)
below, including Google's rule that the **first** `.aab` reaches the track through a manual console
upload.

## Version numbers

| Field | Source | Example |
| --- | --- | --- |
| **Version name** (Play "Release name") | `openzcine.versionName` in `Apps/Android/gradle.properties` | `0.1.0` |
| **Phone version code** (Play's monotonic build id) | `100 + workflow run number`, passed as `-PversionCode` | `101`, `102`, … |
| **Wear version code** | Phone version code + `1,000,000,000` (or explicit `-PwearVersionCode`) | `1,000,000,101` |

This mirrors the iOS pattern ([TestFlight CI](testflight-ci.md)): the human-readable version lives
in one committed file and changes only through a reviewed PR; the machine version code is stamped
per CI build and never committed back. Local builds without `-PversionCode` fall back to
`openzcine.versionCode` in `gradle.properties`.

Google Play requires unique version codes across form factors that share one package. The large,
fixed Wear offset keeps both streams monotonic and collision-free while remaining below Play's
`2,100,000,000` maximum. Adjust `ANDROID_VERSION_CODE_OFFSET` in `play-internal.yml` if the phone
stream ever falls below the highest phone version code already in the Play console.

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
4. **Enable Wear OS** — in Play Console, opt the app into the Wear OS form factor. The phone and
   watch use the same package and upload/app-signing identity, but remain separate artifacts with
   unique version codes.
5. **First uploads are manual** — Google requires the first bundle on a track to be uploaded
   through the console. Build locally ([Local signed build](#local-signed-build)), then create the
   phone internal release with `app-release.aab` and the Wear OS internal release with
   `wear-release.aab`. Add the same internal-tester email list to both tracks.
6. **Create the GitHub environment** — repo **Settings → Environments → New environment** named
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

Either way the workflow runs Gradle tests + lint, computes both unique version codes, decodes the
keystore secret to a runner temp file, builds both `bundleRelease` outputs signed via the same
`ANDROID_KEYSTORE_*` environment variables, verifies the package/signing/capability pair, and
uploads to the phone `internal` and Wear `wear:qa` tracks with
[r0adkll/upload-google-play](https://github.com/r0adkll/upload-google-play) (pinned by digest;
Google publishes no official Play-upload action, and this is the best-maintained community one).

## Local signed build

```bash
just android-keystore                     # once; writes .local/android/upload-keystore.jks
export ANDROID_KEYSTORE_PATH="$PWD/.local/android/upload-keystore.jks"
export ANDROID_KEYSTORE_PASSWORD='...'
export ANDROID_KEY_ALIAS=upload
export ANDROID_KEY_PASSWORD='...'
cd Apps/Android && ./gradlew :app:bundleRelease :wear:bundleRelease :wear:verifyWearReleaseArtifact
# → app/build/outputs/bundle/release/app-release.aab
# → wear/build/outputs/bundle/release/wear-release.aab
```

With the `ANDROID_KEYSTORE_*` variables unset, both `bundleRelease` tasks still succeed and
produce **unsigned** bundles, useful for structure checks. Play rejects them, so signing is
required for any real upload. `just android-release-check` validates that either both APKs are
unsigned or both carry the same signing certificate. The debug path (`just android-build` /
`android-check`) never needs signing variables.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Workflow skipped | Fork — it only runs on `erik-sutton95/openzcine` |
| `ANDROID_KEYSTORE_BASE64 is not set` | `play` environment or its secrets missing |
| Upload fails with 403 / "not found" | Service account lacks release permission, or the app was never created in the console |
| "Package not found" on first CI upload | The mandatory manual first uploads (step 5) haven't happened yet |
| "Version code already used" | Raise `ANDROID_VERSION_CODE_OFFSET`, or explicitly set a collision-free `-PwearVersionCode` for a recovery build |
| Phone and watch cannot discover each other | Confirm both installed APKs use package `com.opencapture.openzcine` and the same signing certificate |
| Wear upload targets the phone track | Use the dedicated Wear internal track (`wear:qa` through the Publishing API) |
| Play rejects the bundle signature | Wrong keystore secrets, or Play App Signing expects a different upload key — reset the upload key via Play support |
