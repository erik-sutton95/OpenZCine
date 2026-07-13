# TestFlight CI

Automated TestFlight builds run when code changes merge to `main`. The workflow archives the iOS app,
assigns a monotonic build number, and uploads to App Store Connect.

## Flow

```text
feature PR → CI (simulator build + tests) → merge to main → TestFlight workflow → App Store Connect
```

- **Pull requests** run [`ci.yml`](../.github/workflows/ci.yml) — simulator build and Swift tests only
  (no signing secrets on untrusted forks).
- **Merges to `main`** run [`testflight.yml`](../.github/workflows/testflight.yml) when non-doc code
  changed — Release archive, version stamp, TestFlight upload.
- **Manual builds** — use **Actions → TestFlight → Run workflow** to upload from `main` (optional
  marketing-version override).

## Version numbers

| Field | Source | Example |
| --- | --- | --- |
| **Marketing version** (TestFlight “Version”) | `MARKETING_VERSION` in `ios/Config/Version.xcconfig` | `0.1.0` |
| **Build number** (TestFlight “Build”) | `100 + workflow run number` | `101`, `102`, … |

TestFlight shows **0.1.0 (101)**, then **0.1.0 (102)**, and so on. Keeping the marketing version
stable lets subsequent uploads remain in the same TestFlight version train while the monotonic
build number identifies each upload.

This follows Apple's version-scoped TestFlight review model: the first external build of a version
requires review, while subsequent builds of that version may not require another full review. See
[TestFlight App Review](https://developer.apple.com/help/glossary/testflight-app-review/).

Bump `MARKETING_VERSION` in `ios/Config/Version.xcconfig` only when intentionally starting a new
version train, such as moving from `0.1.0` to `0.2.0`. CI writes the computed build number into its
working copy before archiving; that change is **not** committed back.

The manual workflow's marketing-version input is an escape hatch for a deliberate one-off override.
The normal release path is to change `Version.xcconfig` in a reviewed pull request so later uploads
continue using the same version.

Adjust `IOS_BUILD_NUMBER_OFFSET` in `testflight.yml` if it falls below your latest App Store Connect
build (currently offset `100`, above manual build `9`).

Local helpers:

```bash
just ios-version                        # print committed version
just ios-set-version 0.2.0 42           # set version locally
just testflight                         # manual archive + upload (needs API key)
```

## One-time GitHub setup

### 1. App Store Connect API key (upload)

1. [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
2. Create a key with **App Manager** (or Admin) role.
3. Download the `.p8` file once — it cannot be re-downloaded.

### 2. Distribution signing secrets (archive + export)

GitHub Actions cannot rely on Xcode “cloud signing” for this project — export fails with
`Cloud signing permission error` even when the API key is valid. CI uses **manual signing** with
your existing Apple Distribution certificate and App Store provisioning profile. CI creates or
reuses the matching Watch App Store profile through the Apple API and downloads it for each build.

On the Mac where TestFlight uploads already work:

#### A. Export the distribution certificate (.p12)

1. Open **Keychain Access** → **My Certificates**
2. Find **Apple Distribution: …** (the cert used for OpenZCine)
3. Right-click → **Export** → save as `OpenZCine-Distribution.p12` with a strong password

#### B. Download the iPhone App Store provisioning profile

1. [Certificates, Identifiers & Profiles → Profiles](https://developer.apple.com/account/resources/profiles/list)
2. Download the **App Store** profile for `com.opencapture.openzcine`

#### C. Base64-encode for GitHub secrets

```bash
base64 -i OpenZCine-Distribution.p12 | pbcopy    # → IOS_DISTRIBUTION_CERTIFICATE_BASE64
base64 -i OpenZCine_AppStore.mobileprovision | pbcopy  # → IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64
```

Add to the **`testflight`** environment (or repository secrets):

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID (e.g. `AB12CD34EF`) |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer UUID from App Store Connect |
| `APP_STORE_CONNECT_API_PRIVATE_KEY` | Full contents of `AuthKey_<KEY_ID>.p8` |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 of the `.p12` file |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password you set when exporting the `.p12` |
| `IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64` | Base64 of the `.mobileprovision` file |

When the distribution certificate expires (~1 year), export a new `.p12` and update the secrets.

### 3. GitHub Environment (recommended)

Create an environment named **`testflight`** under **Settings → Environments**:

- Restrict deployment to `main` (or require maintainer approval).
- Attach all six secrets above to the environment.

The workflow references `environment: testflight`. If the environment does not exist yet, GitHub
falls back to repository-level secrets (still works).

## Local manual upload

Same path CI uses, without GitHub:

```bash
export APP_STORE_CONNECT_API_KEY_ID=...
export APP_STORE_CONNECT_API_ISSUER_ID=...
export APP_STORE_CONNECT_API_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
export IOS_DISTRIBUTION_CERTIFICATE_BASE64="$(base64 -i OpenZCine-Distribution.p12)"
export IOS_DISTRIBUTION_CERTIFICATE_PASSWORD='...'
export IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64="$(base64 -i profile.mobileprovision)"
./scripts/ios-testflight-upload.sh
```

Or open `build/ios/OpenZCine.xcarchive` in Xcode Organizer after `just ios-export`.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Workflow skipped on fork | Expected — only runs on `erik-sutton95/openzcine` |
| “Build number already used” | Raise `IOS_BUILD_NUMBER_OFFSET` |
| `CI TestFlight requires distribution signing secrets` | Add the three `IOS_DISTRIBUTION_*` secrets |
| Watch profile API request fails | Give the App Store Connect API key access to Certificates, Identifiers & Profiles |
| `Cloud signing permission error` on export | Automatic signing path — add distribution secrets (§2) |
| `No Apple Distribution signing identity found` | Wrong `.p12` exported, or expired certificate |
| Upload succeeds but no TestFlight build | Wait for App Store processing; check email for compliance prompts |

Release notes are generated in the workflow summary (`scripts/ios-release-notes.sh`). The script
rewrites recent git history into plain-language **What's new** and **Please test** sections for
TestFlight testers (internal CI/build commits are omitted). Paste the output into App Store Connect
**What to Test** if needed — automated ASC localization API integration can be added later.

Preview locally:

```bash
./scripts/ios-release-notes.sh 25
```
