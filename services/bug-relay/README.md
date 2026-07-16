# OpenZCine anonymous bug-report relay

This Cloudflare Worker accepts a deliberately small, anonymous bug-report payload from the native
OpenZCine apps and creates a labelled issue in
[`erik-sutton95/OpenZCine`](https://github.com/erik-sutton95/OpenZCine). It is not a general
feedback endpoint: feature requests continue to go to account-backed GitHub Discussions.

The public endpoint is:

```text
POST https://reports.openzcine.app/v1/bug-reports
POST https://reports.openzcine.app/v2/bug-reports
```

There are no CORS headers because browsers are not a supported client. Version 1 accepts only
JSON, a UUID `Idempotency-Key`, and the following schema. Unknown fields are rejected.
`workers.dev` is disabled in the deployment configuration; attach only the custom domain during
production provisioning.

```json
{
  "schemaVersion": 1,
  "summary": "A short title",
  "whatHappened": "What the reporter saw.",
  "stepsToReproduce": "Optional steps.",
  "frequency": "sometimes",
  "context": {
    "platform": "ios",
    "appVersion": "1.0.0",
    "buildNumber": "42",
    "osVersion": "iOS 18.0",
    "deviceClass": "phone",
    "connection": "wifi"
  }
}
```

The v1 maximum request body is 12 KiB. The report intentionally excludes diagnostics, screenshots,
attachments, contact details, camera/network details, and arbitrary identifiers. GitHub issues
created by the relay are public and labelled `bug`, `needs-triage`, and `source:anonymous`.

## Version 2 attachment contract

`POST /v2/bug-reports` is a fixed-length `multipart/form-data` request with the same UUID
`Idempotency-Key`. It has exactly one UTF-8 JSON `report` part (at most 16,384 bytes) using
`schemaVersion: 2`, plus zero to three `screenshot` parts. The whole multipart request must be no
larger than 3,211,264 bytes; every screenshot is at most 1,048,576 bytes and must declare
`image/png`.

The optional `activityLog` JSON field is an array of at most 200 closed OpenZCine event names. It
does not accept arbitrary log text, timestamps, device names, paths, network values, or identifiers.
The relay rejects unknown event values.

Each screenshot is parsed server-side before storage. It must be a 1–2560px, 8-bit RGBA,
non-interlaced PNG with valid CRCs; the Worker writes a newly canonical PNG containing only `IHDR`,
`IDAT`, and `IEND` chunks. It discards the original filename and PNG metadata. This does not alter
or inspect visible screenshot pixels: the native app must make clear that screenshots can still show
sensitive or identifying information and are public when included in an anonymous issue.

Canonical images are stored in the private R2 `BUG_REPORT_MEDIA` bucket under opaque UUID-derived
keys. The public GitHub issue embeds only fixed Worker URLs under
`/v2/bug-report-media/<uuid>/<slot>`; the original bytes and filename are never stored or linked.

## Local checks

The unit tests use injected fakes and never contact GitHub or Cloudflare:

```sh
cd services/bug-relay
npm test
```

## Manual production provisioning

Actual Cloudflare and GitHub setup is a maintainer operation. Do not add credentials to this
repository, mobile builds, CI variables visible to untrusted pull requests, or issue text.

1. Create a private GitHub App owned by `erik-sutton95`. Configure installation so it can be
   installed only on that account, then install it only for the `erik-sutton95/OpenZCine`
   repository. Give it repository **Issues: Read and write** permission; Metadata read access is
   supplied automatically. Do not grant Contents, Discussions, Pull requests, Actions, Members,
   Administration, or organization permissions.
2. Generate one GitHub App private key. The Worker accepts either GitHub's `RSA PRIVATE KEY` PEM or
   an unencrypted PKCS#8 `PRIVATE KEY` PEM. Record the App ID and installation ID in the password
   manager, not in source control.
3. Before first traffic, create the source label remotely and confirm the other two labels exist:

   ```sh
   gh label create 'source:anonymous' --color '5319E7' \
     --description 'Submitted through the anonymous in-app bug form' \
     --repo erik-sutton95/OpenZCine
   gh label list --repo erik-sutton95/OpenZCine
   ```

4. Authenticate Wrangler to the production Cloudflare account. In `wrangler.jsonc`, replace the
   sample `namespace_id` `2001` with an account-unique Worker Rate Limit namespace ID. Keep the
   binding name and its 3 requests per 60 second policy unchanged.
5. Create the private R2 bucket named `openzcine-bug-report-media` in the same Cloudflare account.
   Keep the `BUG_REPORT_MEDIA` binding name unchanged. Configure a **30-day** R2 lifecycle
   expiration as a backstop for a failed deletion, and state that public-attachment retention
   period explicitly in the app privacy notice. Expiry removes the image from the public issue as
   well, so do not configure the lifecycle policy without that documented retention choice.
6. Set all credentials as Worker secrets from this directory. Paste each value only into the
   Wrangler prompt; commands and shell history must not contain a secret value.

   ```sh
   npx wrangler@4 secret put GITHUB_APP_ID --config wrangler.jsonc
   npx wrangler@4 secret put GITHUB_INSTALLATION_ID --config wrangler.jsonc
   npx wrangler@4 secret put GITHUB_APP_PRIVATE_KEY --config wrangler.jsonc
   ```

7. Deploy the Worker:

   ```sh
   npx wrangler@4 deploy --config wrangler.jsonc
   ```

8. In Cloudflare Dashboard, add the custom domain `reports.openzcine.app` to this Worker under
   **Workers & Pages → openzcine-bug-relay → Settings → Domains & Routes**. The `openzcine.app`
   zone must be managed by Cloudflare. Verify that a `POST` to the path above reaches the Worker
   and that a `GET` returns a small `405` JSON response.
9. Before production launch, create a Cloudflare WAF rate-limiting rule for host
   `reports.openzcine.app` and both report paths (`/v1/bug-reports` and `/v2/bug-reports`), keyed
   by IP, with a daily threshold (for example, 20 requests per 24 hours) and a Block or Managed
   Challenge action. This is a second abuse control; it does not replace the Worker binding's 3 per
   60 seconds limit.
9. Update and publish the app privacy notice before enabling the client-side endpoint. It must say
   that submission is optional, the issue is public, and no report body or client IP is logged by
   this service. The Durable Object retains only an issue receipt and a cryptographic request
   fingerprint for at most 24 hours to make retries idempotent.

If a secret is rotated, update it with the same `wrangler secret put` command and deploy again.
The GitHub App remains server-side: neither its private key nor an installation token may be
shipped in the iOS or Android application.

## Operational behavior

- The Worker does not call `console.log` with request fields, issue content, or client IPs.
- `CF-Connecting-IP` is passed only to the Cloudflare rate-limit binding and is never stored.
- A Durable Object keyed by the UUID serializes same-key submissions and saves an issue receipt for
  24 hours. The first completed request returns `201`; a same-payload retry returns `200` with the
  same issue receipt. Failed issue creation is not cached.
- Before a v2 request can write to R2, the Durable Object reserves its canonical payload hash. A
  changed attachment for the same UUID is rejected before it can overwrite media. Newly created R2
  objects are deleted if the GitHub issue call fails; the configured lifecycle rule is a backstop
  for the rare case where that deletion cannot complete.
- Errors are intentionally generic: `invalid_request`, `rate_limited`, or `unavailable`. The
  Worker never returns GitHub error bodies to an app.
