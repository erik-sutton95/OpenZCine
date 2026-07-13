# Frame.io integration setup

OpenZCine can upload clips (the LUT-baked export, or the cached original) to Frame.io from the Media
player's paperplane button. Auth is **OAuth 2.0 (PKCE)** via **Adobe IMS** — the Frame.io V4 API does
not accept tokens from the legacy Frame.io developer portal (`applications.frame.io`). There is no
client secret. A one-time Adobe Developer Console registration is required.

> **Requires iOS 17.4+** for the Frame.io feature (`ASWebAuthenticationSession`). The rest of the app
> still targets iOS 17.0.

## 1. Register an OAuth app in Adobe Developer Console (one time)

1. Sign in to the [Adobe Developer Console](https://developer.adobe.com/console).
2. **Create new project** (e.g. `OpenZCine`).
3. **Add API** → search for **Frame.io API** → add it to the project.
4. Under **Credentials**, choose **OAuth Native App** (PKCE — no client secret). Do **not** use Single
   Page App for the iOS shell.
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

## 3. Use it

Open a clip in the Media player or select clips in the media grid → tap **Share**. Choose **Frame.io**,
then pick a destination **project** from the dropdown (or tap **Create new project** below it). Your
selection is remembered for later uploads in the same session and across app launches. Configure
delivery options (LUT bake, metadata, re-upload) and start the upload — progress appears on the clip.

First Frame.io use triggers Adobe IMS sign-in (`ASWebAuthenticationSession`); the token is stored in
the iOS Keychain and refreshed automatically (via `offline_access`).

## What's verified vs. needs your credentials

- **Unit-tested (no account needed):** PKCE (RFC 7636 S256), the authorize/token request construction
  against Adobe IMS, redirect scheme parsing, and the V4 JSON model decoding
  (`Tests/OpenZCineCoreTests/Frameio*Tests.swift`).
- **`[verify-with-credentials]`:** the live sign-in + the upload (Create File → S3 `PUT`). Create File
  accepts only `name` and `file_size` in the request body (V4 rejects `media_type` there); set
  `Content-Type` on the S3 `PUT` to match the file. The exact V4 endpoint paths for projects and
  Create File are modeled from the public docs and may need a small `CodingKeys`/path tweak against
  the first live responses — flagged inline in `FrameioClient.swift` / `FrameioModels.swift`.

## Optional: HTTPS redirect

An `https://…` redirect with Associated Domains (`webcredentials`) + AASA is supported by the auth
coordinator for SPA-style credentials. Adobe **Native App** credentials use the custom `adobe+…`
scheme instead — no website or AASA required.

## Follow-ups (intentionally not in this slice)

- A Settings **Connect/Disconnect** row for Frame.io.
- **Granular upload progress** + **multipart** for clips large enough that Create File returns more
  than one `upload_url`.
- Comments / review-links after upload.
