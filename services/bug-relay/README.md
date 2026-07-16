# OpenZCine anonymous bug-report relay

This Cloudflare Worker accepts a deliberately small, anonymous bug-report payload from the native
OpenZCine apps and creates a labelled issue in
[`erik-sutton95/OpenZCine`](https://github.com/erik-sutton95/OpenZCine). It is not a general
feedback endpoint: feature requests continue to go to account-backed GitHub Discussions.

The public endpoint is:

```text
POST https://reports.openzcine.app/v1/bug-reports
```

There are no CORS headers because browsers are not a supported client. The Worker accepts only
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

The maximum request body is 12 KiB. The report intentionally excludes diagnostics, screenshots,
attachments, contact details, camera/network details, and arbitrary identifiers. GitHub issues
created by the relay are public and labelled `bug`, `needs-triage`, and `source:anonymous`.

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
5. Set all credentials as Worker secrets from this directory. Paste each value only into the
   Wrangler prompt; commands and shell history must not contain a secret value.

   ```sh
   npx wrangler@4 secret put GITHUB_APP_ID --config wrangler.jsonc
   npx wrangler@4 secret put GITHUB_INSTALLATION_ID --config wrangler.jsonc
   npx wrangler@4 secret put GITHUB_APP_PRIVATE_KEY --config wrangler.jsonc
   ```

6. Deploy the Worker:

   ```sh
   npx wrangler@4 deploy --config wrangler.jsonc
   ```

7. In Cloudflare Dashboard, add the custom domain `reports.openzcine.app` to this Worker under
   **Workers & Pages → openzcine-bug-relay → Settings → Domains & Routes**. The `openzcine.app`
   zone must be managed by Cloudflare. Verify that a `POST` to the path above reaches the Worker
   and that a `GET` returns a small `405` JSON response.
8. Before production launch, create a Cloudflare WAF rate-limiting rule for host
   `reports.openzcine.app` and path `/v1/bug-reports`, keyed by IP, with a daily threshold (for
   example, 20 requests per 24 hours) and a Block or Managed Challenge action. This is a second
   abuse control; it does not replace the Worker binding's 3 per 60 seconds limit.
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
- Errors are intentionally generic: `invalid_request`, `rate_limited`, or `unavailable`. The
  Worker never returns GitHub error bodies to an app.
