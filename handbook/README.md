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
