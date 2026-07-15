# Frame.io integration setup

OpenZCine can upload clips to Frame.io with **OAuth 2.0 (PKCE)** via **Adobe IMS** — the Frame.io V4
API does not accept tokens from the legacy Frame.io developer portal (`applications.frame.io`). There
is no client secret. Both mobile shells can upload a LUT-baked export or finalized cached original;
Android keeps its optional metadata sidecar in app-private storage after a confirmed upload. A
one-time Adobe Developer Console registration is required.

> **Requires iOS 17.4+** for the Frame.io feature (`ASWebAuthenticationSession`). The rest of the app
> still targets iOS 17.0.

## 1. Register an OAuth app in Adobe Developer Console (one time)

1. Sign in to the [Adobe Developer Console](https://developer.adobe.com/console).
2. **Create new project** (e.g. `OpenZCine`).
3. **Add API** → search for **Frame.io API** → add it to the project.
4. Under **Credentials**, choose **OAuth Native App** (PKCE — no client secret). Do **not** use Single
   Page App for either mobile shell.
5. Open the credential → copy **Client ID** and the full **Default redirect URI**.

Adobe **auto-generates** the Native App redirect URI. It is **not** a URL you choose — it looks like:

```text
adobe+{unique-id}://adobeid/{your-client-id}
```

Example shape (your `{unique-id}` will differ):

```text
adobe+7639bi…://adobeid/727e9081b73a46b286d6f491ed0ff602
```

Copy the redirect URI **character-for-character** from the console. The authorize request,
`redirect_uri` token exchange field, `Info.plist`, and iOS URL-scheme registration must all match
exactly.

Your Frame.io account must be a **V4 account linked to the same Adobe ID** you sign in with. In
Frame.io → Settings → Authentication, it should show “Manage on Adobe”. A valid Adobe IMS login that
isn't linked to Frame.io still returns **HTTP 401** on every V4 API call.

## 2. Configure the app — without committing credentials

Values are supplied through a **gitignored xcconfig**, never committed to the public repo:

```sh
cp ios/Runner/Frameio.local.xcconfig.example ios/Runner/Frameio.local.xcconfig
```

Edit `Frameio.local.xcconfig` with the three fields from your Adobe credential:

```xcconfig
FRAMEIO_CLIENT_ID = 727e9081b73a46b286d6f491ed0ff602
FRAMEIO_REDIRECT_URI = adobe+7639bi…://adobeid/727e9081b73a46b286d6f491ed0ff602
FRAMEIO_URL_SCHEME = adobe+7639bi…
```

| Field | Source |
| --- | --- |
| `FRAMEIO_CLIENT_ID` | **Client ID** on the credential page |
| `FRAMEIO_REDIRECT_URI` | Full **Default redirect URI** (copy/paste entire string) |
| `FRAMEIO_URL_SCHEME` | Everything **before** `://` in the redirect URI (usually `adobe+…`) |

`Info.plist` reads `$(FRAMEIO_CLIENT_ID)`, `$(FRAMEIO_REDIRECT_URI)`, and registers
`$(FRAMEIO_URL_SCHEME)` under `CFBundleURLSchemes` so iOS can hand the Adobe redirect back to the app.
The committed `Frameio.xcconfig` defaults these to empty — fresh clones build without Frame.io until
you add the local file.

**Checklist before testing:**

- [ ] All three `FRAMEIO_*` values in `Frameio.local.xcconfig` are filled in
- [ ] `FRAMEIO_URL_SCHEME` matches the scheme portion of `FRAMEIO_REDIRECT_URI`
- [ ] Redirect URI in xcconfig matches Adobe Console exactly (including `adobe+` and `/adobeid/…`)
- [ ] App deleted and reinstalled after changing redirect/scheme (clears stale Keychain tokens)

## Android configuration: deliberately fail closed

Android uses the same Adobe IMS PKCE flow, but it does **not** inherit the iOS credential or invent
a client identity. A fresh Android build has an intentionally unusable manifest callback and
shows **Not configured** in Settings → Storage. Native Share continues to work independently.

An Adobe Developer Console maintainer must register or approve the Android **OAuth Native App**
client, add the Frame.io API, and provide the exact public client ID and callback URI for the Android
package. There is still no client secret.

Copy the ignored local file, then fill in only the values supplied by Adobe:

```sh
cp Apps/Android/frameio.local.properties.example Apps/Android/frameio.local.properties
```

```properties
frameio.clientId=
frameio.redirectUri=
```

For CI or one-off builds, the same values may be passed as Gradle properties
(`-Pframeio.clientId=… -Pframeio.redirectUri=…`) or environment variables
(`FRAMEIO_CLIENT_ID`, `FRAMEIO_REDIRECT_URI`). Gradle derives the manifest scheme and host from the
URI; do not add a separate hand-maintained callback value. Explicit Gradle properties take precedence,
then environment values, then the ignored local file. Neither file nor a real client ID belongs in git.

The committed fallback is `openzcine-frameio-unconfigured://unconfigured`. It is intentionally not
an Adobe registration and must never be released as a usable sign-in path.

### Android external authority and hardware checklist

The following work is external to code completion and must be performed by an Adobe Developer Console
maintainer and an Android hardware tester:

- **[VERIFY-ON-HW]** Register/approve the Android OAuth Native App with the exact client ID and
  custom-scheme redirect URI, then inject those values only through the local/CI configuration above.
- **[VERIFY-ON-HW]** Install the configured signed APK, test both cold launch and an existing task,
  and confirm the browser callback returns to OpenZCine only for the exact registered URI.
- **[VERIFY-ON-HW]** Confirm a rejected, stale, or state-mismatched redirect never stores a token;
  confirm a successful token and pending PKCE state remain only in Android Keystore-encrypted storage.
- **[VERIFY-ON-HW]** While the process is bound to a Nikon camera access point, verify sign-in,
  project loading, and refresh are blocked without releasing the camera binding. In Media, verify an
  upload cannot release the binding until the operator accepts the separate **Leave camera Wi-Fi?**
  confirmation.
- **[VERIFY-ON-HW]** With a real saved Nikon profile, verify the confirmed delivery hop disconnects
  the protocol session before releasing its process binding, waits for validated internet, retains
  the selected clips and destination, then rejoins that exact saved profile. Confirm **Camera
  rejoined** appears only after a fresh connected-session result. Repeat for cancellation, internet
  timeout, failed upload, and failed rejoin. A demo fixture or incomplete saved profile must never
  release a network.
- **[VERIFY-ON-HW]** Upload one disposable, fully completed cached artifact and verify the Create
  File → HTTPS parts → status-poll sequence. Confirm a growing `.part` cache file and arbitrary
  filesystem paths are refused, and that the existing native Share chooser still works afterward.
- **[VERIFY-ON-HW]** Deliver one supported video with both a built-in LUT and an imported, approved
  LUT. Confirm the uploaded H.264/AAC MP4 contains the selected look, the staged original is unchanged,
  the temporary export is removed, and unsupported codec or HDR input fails closed without uploading
  a partial export.
- **[VERIFY-ON-HW]** Enable metadata and confirm the app-private `.meta.json` file is written only
  after upload completion and contains the approved clip, camera, project-name, size, and applied-LUT
  fields. Confirm it contains no token, callback, URL, or Frame.io account/workspace/project/folder ID.
- **[VERIFY-ON-HW]** Capture the Settings and Media delivery states on the supported Android device
  sizes, including the densest multi-selection state, and inspect every screen edge for clipping or
  truncated controls before treating the UI as visually verified.

## 3. Use it

### iOS

Open a clip in the Media player or select clips in the media grid → tap **Share**. Choose **Frame.io**,
then pick a destination **project** from the dropdown (or tap **Create new project** below it). Your
selection is remembered for later uploads in the same session and across app launches. Configure
delivery options (LUT bake, metadata, re-upload) and start the upload — progress appears on the clip.

First Frame.io use triggers Adobe IMS sign-in (`ASWebAuthenticationSession`); the token is stored in
the iOS Keychain and refreshed automatically (via `offline_access`).

### Android

After the maintainer has configured the Android OAuth client, sign in from **Settings → Storage**.
Select one or more complete cached clips in the media grid, tap **FRAME.IO**, then load or create and
choose a project. The selected project is retained across launches. For each delivery, choose whether
to bake the currently selected approved monitor LUT into a temporary MP4 and whether to record the
approved metadata sidecar. Delivery creates the Frame.io file, uploads its HTTPS parts, polls its
completion state, then removes the temporary export without changing the staged original.

Android accepts only a finalized `cacheDir/share/ready` copy that native Share uses. A LUT bake is
available only for a supported video proxy; unsupported formats fail closed. The metadata sidecar is
local and app-private, not a second cloud upload. Re-upload controls, alternate export formats, and
on-demand caching of camera-only selections are not part of this Android slice.

When the app is bound to a real saved Nikon camera access point, tap **Hop to internet** and accept
the separate confirmation before Android disconnects the session or releases the process binding.
OpenZCine keeps the current delivery context while it waits for validated internet. After upload,
cancellation, or timeout, it rejoins the exact saved profile and reports success only if the protocol
session reconnects. Fixture sessions and profiles without a saved encrypted credential cannot hop.
Native Share stays available as the independent fallback.

## What's verified vs. needs external authority

- **Unit-tested (no account needed):** PKCE (RFC 7636 S256), the authorize/token request construction
  against Adobe IMS, redirect scheme parsing, and the V4 JSON model decoding
  (`Tests/OpenZCineCoreTests/Frameio*Tests.swift`); plus Android artifact allowlisting, LUT-cube
  mapping and temporary-export policy, secret-free metadata encoding, explicit-hop consent, timeout
  recovery, fixture refusal, and connected-session rejoin evidence.
- **[VERIFY-ON-HW]:** the live sign-in + the upload (Create File → S3 `PUT`). Create File
  accepts only `name` and `file_size` in the request body (V4 rejects `media_type` there); set
  `Content-Type` on the S3 `PUT` to match the file. The exact V4 endpoint paths for projects and
  Create File are modeled from the public docs and may need a small `CodingKeys`/path tweak against
  the first live responses — flagged inline in `FrameioClient.swift` / `FrameioModels.swift`.

## Optional: HTTPS redirect

An `https://…` redirect with Associated Domains (`webcredentials`) + AASA is supported by the auth
coordinator for SPA-style credentials. Adobe **Native App** credentials use the custom `adobe+…`
scheme instead — no website or AASA required.

## Follow-ups (intentionally not in this slice)

- Comments / review-links after upload.
- Android Frame.io re-upload controls, alternate delivery formats, and on-demand caching of a
  camera-only selection before the internet hop.
