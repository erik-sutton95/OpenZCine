# OpenZCine handbook

Astro [Starlight](https://starlight.astro.build/) site for OpenZCine: the Nikon Z
protocol, the iOS and Android apps, and how to build. Markdown in
`src/content/docs/` is the public source. Engineering notes in `docs/` stay in the
repository and are summarized here, not copied.

When protocol, app behavior or setup changes, update the matching page in the same
PR. Standard: `src/content/docs/contribute/documentation.md`.

Published at [opencapture.org/openzcine/docs](https://opencapture.org/openzcine/docs/).

## Local preview

```bash
cd handbook
npm ci
npm run dev
```

Then open [http://localhost:4321/](http://localhost:4321/). Local preview serves
the handbook at the site root.

| Command | Action |
| --- | --- |
| `npm run dev` | Dev server with live reload |
| `HANDBOOK_BASE=/openzcine/docs npm run build` | Production build to `dist/`, as opencapture.org serves it |
| `npm run preview` | Serve the last build |

CI builds the handbook when `handbook/**` changes. A merge to `main` that touches
`handbook/**` triggers the opencapture.org deploy.

## Dependency maintenance

Commit `package.json` and `package-lock.json` together. After a dependency update,
run `npm ci`, `npm audit` and the production-base build above. These dependencies
build the static handbook; build-time parsing and image vulnerabilities still
matter even when the deployed output has no Node server.

The scoped `postcss-nested` override selects `postcss-selector-parser` 7.1.6 to
address [GHSA-rj75-hqrm-r3gf](https://github.com/postcss/postcss-selector-parser/security/advisories/GHSA-rj75-hqrm-r3gf).
It preserves the existing Astro and Starlight versions. Validate the full build
when changing it, and remove the override when the parent supports a patched
parser directly.

The lock also selects `http-cache-semantics` 4.3.0, outside the current affected
range of [GHSA-ch52-4w7c-c8xp](https://github.com/advisories/GHSA-ch52-4w7c-c8xp).
A clean audit does not demonstrate a repair of the advisory's disputed revalidation
behavior. This handbook's Astro use is build-time remote-image cache expiry,
not an authenticated shared response cache. Keep the advisory distinction when
reviewing future dependency or deployment changes.
