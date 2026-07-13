# OpenZCine Landing Page — Design Spec

**Date:** 2026-07-06
**Status:** Approved design, pending implementation plan
**Branch:** `landing-page` (worktree: `OpenZCine-wt-landing-page`)
**Working directory:** `$HOME/Work/OpenZCine-wt-landing-page`

## Purpose

A single-page, dark, cinematic marketing site for **OpenZCine** — the free, open-source field-monitor app for Nikon Z mirrorless cameras. Deployed free via GitHub Pages, kept in the repo alongside the app code. The page's job: convince cinematographers to join the TestFlight beta, and communicate the open-source identity.

## Context

- **App stage:** heading into TestFlight beta. iOS first (iPhone, iPad, Apple Watch); Android coming.
- **Camera support:** Nikon ZR initially, rolling out across the Z mirrorless line.
- **Concurrency:** built in an isolated worktree (`landing-page` branch, off `main`) so it doesn't conflict with concurrent UI work on `ui/general-improvements`.

## Brand (final, locked)

The landing page uses the **canonical OpenZCine brand** from `ios/Runner/Branding.swift` and the live-monitor `docs/design/prototypes/live-monitor/index.html`.

### Color tokens (OKLCh, matching the app)

| Token | Value | Hex (approx) | Usage |
|---|---|---|---|
| `--bg` | `oklch(15% 0.009 62)` | `#0A0908` | Page background — warm charcoal, throughout, no transition to light |
| `--bg-deep` | `oklch(10% 0.009 62)` | deeper warm | Footer, recessed areas |
| `--surface` | `oklch(23% 0.012 60)` | `#1D1813` | Card / device-mockup bodies — warm brown-charcoal |
| `--ink` | `oklch(94% 0.012 80)` | `#F2ECE2` | Primary text — warm off-white |
| `--muted` | `oklch(67% 0.013 72)` | warm muted | Secondary text |
| `--accent` | `oklch(82% 0.155 83)` | `#FFE100` | Nikon gold — **solid only, no gradients anywhere** |
| `--accent-soft` | `oklch(82% 0.155 83 / .16)` | gold @ 16% | Glow halos, hover washes |
| `--rec` | `oklch(63% 0.225 27)` | red | REC motif — live indicator on mockups, the `●` before section labels |
| `--hairline` | `rgba(247,239,225,0.10)` | — | Borders, dividers |

### Typography

- **Primary:** Geist (Google Fonts), weights 400/500/600/700
- **Mono:** Geist Mono (Google Fonts) for scope readouts, technical labels, version strings
- Loaded with `font-display: swap`; `preconnect` to Google Fonts

### Panel style — Liquid-glass

Translucent warm surfaces with backdrop blur (the "Apple liquid glass" effect the app already uses). Used for: scope overlays on device mockups, the sticky nav, feature pills, floating CTAs.

```css
--glass:        rgba(22,19,15,0.52);
--glass-bright: rgba(40,35,28,0.55);
--blur:         blur(22px) saturate(1.15);
```

Applied via `background: var(--glass); backdrop-filter: var(--blur);` (with `-webkit-` prefix).

### Logo

`AppIcon-1024.png` from `ios/Runner/Assets.xcassets/AppIcon.appiconset/` — the latest app icon. Copied to `/site/assets/icon.png` (also used as the `og-image` base).

## Architecture

### Tech approach

**Hand-rolled static site.** No framework, no build step, no Node toolchain. A contributor fixing a typo edits HTML directly and opens a PR — nothing to install.

- `index.html` — all copy and structure
- `assets/app.css` — all styling (tokens at top)
- `assets/app.js` — scroll-scrub binding + reveal animations
- GSAP + ScrollTrigger loaded from CDN (~50KB) for the one scrub effect
- Fonts (Geist, Geist Mono) from Google Fonts CDN

### Hosting & deployment

**GitHub Pages via GitHub Actions, separate from the existing Vercel `website/` setup.** The repo already has `website/` configured for Vercel (OAuth callback, `apple-app-site-association`, privacy page). The landing page does **not** touch `website/` — it lives in `/site` and is deployed by a GitHub Actions workflow that uploads **only** `/site`. This is critical: the repo's `docs/` folder holds internal engineering notes that aren't part of the public site, so we deliberately do **not** serve from `docs/`.

```
OpenZCine/  (this repo)
├── site/                          ← ONLY this is published to GitHub Pages
│   ├── index.html
│   ├── assets/
│   │   ├── app.css
│   │   ├── app.js
│   │   ├── icon.png               ← AppIcon-1024, copied from ios assets
│   │   ├── og-image.png           ← social share card
│   │   ├── scrub.mp4              ← scroll-scrub video (~8-10s, placeholder at first)
│   │   ├── scrub-poster.png       ← static fallback frame
│   │   └── screenshots/           ← feature section stills
│   └── robots.txt
├── docs/                          ← internal engineering docs, NEVER published
├── website/                       ← EXISTING, untouched (Vercel: OAuth + privacy)
└── .github/workflows/
    └── deploy-pages.yml           ← uploads site/ only, via Actions
```

**Setup:** GitHub repo → Settings → Pages → **Source: "GitHub Actions"** (NOT "Deploy from a branch"). The `deploy-pages.yml` workflow handles the build + deploy on push to `main`. URL: `https://<user>.github.io/<repo>/` (custom domain addable later via a `CNAME` file).

**Deploy Action** (`.github/workflows/deploy-pages.yml`): on push to `main` (paths: `site/**`), assert all `assets/` paths referenced in `index.html` resolve (with a whitelist for the not-yet-captured placeholders), then upload `site/` as the Pages artifact. Catches broken links/images before they ship, and never touches `docs/`.

### Navigation

Sticky top nav, liquid-glass background (blur intensifies on scroll):
- **Left:** OpenZCine wordmark + icon
- **Right:** anchor links — `Scopes`, `Export`, `Open Source`, `Download`
- **Far right:** `★ GitHub` link + `Join the beta` button (gold)
- Collapses to a hamburger on mobile

## Page structure — 7 sections

Top to bottom, all on the dark warm background. Two sections get **spotlight** treatment (more vertical space, larger visuals, the gold glow). Order locked with user.

### 1. Hero (opener)
- Big headline: "The open field monitor for Nikon Z."
- One-line value prop
- **Primary CTA:** "Join the TestFlight beta" → TestFlight link (placeholder until provided)
- **Secondary CTA:** "★ Star on GitHub"
- **Scroll-scrub video showpiece** lives here (see "Scroll-scrub" below): landscape-iPhone mockup scrubs through live monitor footage as the user scrolls

### 2. ★ Pro Monitoring Scopes (SPOTLIGHT — credibility core)
The headline feature. Full-bleed section showing real scope overlays on a live image. This is the differentiator vs. toy apps and matches the commercial reference's credibility.
- Waveform monitor
- Histogram (RGB/Luma)
- Vectorscope
- False color
- Focus peaking
- Zebras
- Aspect/framing guides

### 3. Playback & Monitoring (supporting)
On-device footage review — scrubbing clips, marking in/out, the live monitoring experience. Still image or short autoplay loop.

### 4. Advanced Export & Camera-to-Cloud (supporting, visually rich)
The "ship it" story:
- Camera-to-Cloud (frame.io integration)
- Native iOS share
- **LUT baking** on export — built-in LUTs, RED LUTs, custom `.cube` LUTs

### 5. ★ 100% Free & Open Source (SPOTLIGHT — identity core)
The differentiator vs. the commercial reference app. Free forever, community-driven, **Apache 2.0 licensed** (per the repo's `LICENSE`). Includes a "★ Star the repo" CTA.

### 6. Platforms & Cameras (supporting, two-column)
- **Platforms:** iPhone · iPad · Apple Watch (today); Android (coming)
- **Cameras:** Nikon ZR (first); full Z mirrorless line (roadmap)

### 7. Download / Final CTA (closer)
Mirror of the hero CTA for scroll-lazy visitors:
- Big "Join the TestFlight beta" button
- GitHub star link
- Quiet footer: Apache 2.0 license, links, credits
- **Footer must include the Nikon trademark disclaimer** (from `NOTICE`): "Not affiliated with or endorsed by Nikon Corporation. 'Nikon', 'Nikon Z', and 'ZR' are trademarks of Nikon Corporation, used for identification only." This is legally important given the camera-specific marketing.

## Scroll-scrub video (the showpiece)

One Apple-style scroll-scrubbed video — the single premium motion moment. As the user scrolls, the landscape-iPhone mockup scrubs forward through real app footage.

### How it works
- One pre-rendered `.mp4` (~8–10s, 1080p, optimized to ~3–5MB) at `/docs/assets/scrub.mp4`
- GSAP + ScrollTrigger (CDN, ~50KB) pins the device mockup in place and binds the video's `currentTime` to the page scroll position over a ~600px trigger zone
- Scroll down → footage plays forward; scroll up → reverses
- ~30 lines of vanilla JS tie `scrollY` → `video.currentTime`
- The video loads lazily (only when the hero approaches the viewport), so initial page paint is fast

### Footage content (sequence)
1. Scopes appear on the live image
2. A focus pull
3. A LUT applied

*(User approved this sequence.)*

### Reduced-motion / failure fallback
If the user has "Reduce Motion" enabled (or the video fails to load), fall back to **a static poster frame** (`scrub-poster.png`, the first frame as a still image). No autoplay, no scrubbing. The page still tells the complete story without motion.

### Asset workflow (placeholder → real)
During implementation, ship a `placeholder.mp4` + poster so the page works immediately. To replace with real footage, drop a file at `/docs/assets/scrub.mp4` — done. All asset paths are predictable and documented in a comment at the top of `index.html`.

## Performance budget

- **Target:** first paint < 1s on a decent connection; Lighthouse 95+
- **HTML/CSS/JS:** minimal, total well under 50KB gzipped
- **Heavy asset:** the scrub `.mp4` (~3–5MB) is the only large file; loads lazily
- **Images:** optimized WebP/JPEG; icon and OG image are small PNGs
- **Fonts:** Geist via Google Fonts with `font-display: swap`

## Responsiveness

- **Desktop:** full hero with the landscape device mockup, multi-column feature grids
- **Tablet:** device mockup scales, grids collapse to fewer columns
- **Mobile:** single column; device mockup shows portrait/vertical; scrub pinned zone is shorter; nav collapses to hamburger
- Note: the app itself is primarily used in landscape (16:9 shooting), hence landscape device mockups on desktop/tablet. The page accommodates portrait for the mobile-page case.

## Maintenance

- **No build step** → contributors edit HTML/CSS directly, open a PR. No `npm install`, no toolchain.
- **Content in one place:** `index.html` holds the copy.
- **Asset swap:** predictable paths (`/docs/assets/scrub.mp4`, `screenshots/`, `icon.png`), documented at the top of `index.html`.

## Testing (lightweight)

- **Manual:** serve locally with `python3 -m http.server` from `/docs`; check desktop + mobile widths; verify the scrub effect; verify reduced-motion fallback (toggle macOS System Settings → Accessibility → Display → Reduce Motion).
- **Automated (optional, via deploy Action):** HTML validation + asset-path resolution check. No browser E2E — overkill for a single static page.

## Open questions / items to confirm at implementation time

1. **TestFlight link:** the hero "Join the beta" CTA needs a destination. Use a placeholder (`#`) until the TestFlight URL or a beta-signup form is provided. The button is wired so swapping the link is a one-line edit.
2. **GitHub repo URL:** the `★ GitHub` links need the actual repo URL.
3. **OG image:** `icon.png` works as a base, but a dedicated `og-image.png` (1200×630) with the wordmark + tagline will share better on social. Can be generated during implementation.

*(License resolved during self-review: Apache 2.0. Nikon trademark disclaimer required in footer — noted in Section 7.)*

## Out of scope (YAGNI)

- Static site generator (Astro/11ty/Jekyll) — a single page doesn't justify a build step
- Blog / changelog / docs subsite — can migrate to Astro later if the site grows
- Custom domain wiring — supported trivially via a `CNAME` file when ready, not needed for launch
- Analytics — can add privacy-friendly analytics (e.g. Plausible) later; not in the initial build
- Email capture / waitlist — the TestFlight link serves as the beta funnel for now
