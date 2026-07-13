# OpenZCine Landing Page Implementation Plan

**Goal:** Build a single-page, dark, cinematic marketing site for OpenZCine, deployed via GitHub Pages from `/docs`, kept in the repo alongside the app.

**Architecture:** Hand-rolled static site — one `index.html`, one `assets/app.css`, one `assets/app.js`. GSAP + ScrollTrigger (CDN) drive one scroll-scrubbed video in the hero. No build step, no framework. Canonical OpenZCine brand (warm charcoal + solid Nikon gold + Geist + liquid-glass panels).

**Tech Stack:** HTML5, CSS (custom properties + `backdrop-filter`), vanilla JS, GSAP/ScrollTrigger (CDN), Google Fonts (Geist). GitHub Pages deployment.

**Spec:** `docs/design/specs/2026-07-06-landing-page-design.md`

---

## Repository conventions (read before starting)

This is a public, Apache-2.0 repo with strict conventions. Every task's commit step MUST follow these:

1. **Branch:** Already on `landing-page` (worktree `OpenZCine-wt-landing-page`). Do NOT commit to `main`.
2. **Conventional Commits:** Every commit message is `type: subject` — types are `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `build:`, `test:`.
3. **Commit hygiene gate (run before EVERY commit):**
   ```bash
   cd $HOME/Work/OpenZCine-wt-landing-page
   git diff --staged            # actually read it — secrets hide in changed lines
   just secrets                 # gitleaks — must pass
   ```
4. **Git identity:** Before the first commit, set the repo-local public identity:
   ```bash
   git config user.email "<public-email>"   # project public email, NOT employer
   ```
   (Ask the user for their public email if not already set; check with `git config user.email`.)
5. **`just check`** runs repo-wide quality gates (typos, markdownlint, lychee link-check, editorconfig, actionlint, gitleaks). Run it before pushing — it must pass. NOTE: it also runs Swift tests, which are unrelated to this work but must already be green on the branch (they are — clean checkout of `main`).
6. **Originality:** Do not copy another app's copy, layout, or icons. Factual interface naming is fine. The page is original composition.
7. **Never commit** anything under `vendor/` or `ref/` (Nikon-proprietary), or RED `.cube` LUTs (non-redistributable). The landing page uses none of these, but stay vigilant.

---

## File structure

```
docs/                              ← GitHub Pages serves from here
├── index.html                     ← Page structure + all copy
├── assets/
│   ├── app.css                    ← Brand tokens + all styling
│   ├── app.js                     ← Scroll-scrub + reveal animations
│   ├── icon.png                   ← AppIcon-1024 (copied from ios assets)
│   ├── og-image.png               ← 1200×630 social card
│   ├── scrub.mp4                  ← Scroll-scrub video (placeholder first)
│   ├── scrub-poster.png           ← Static reduced-motion fallback
│   └── screenshots/               ← Feature-section stills
│       ├── scopes.png
│       ├── playback.png
│       └── export.png
├── CNAME                          ← (later) custom domain — not created now
└── robots.txt
.github/workflows/
└── deploy-pages.yml               ← Optional: validate HTML + assets on push
```

**Responsibilities:**
- `index.html` — document structure, copy, semantic landmarks, asset references. No inline styles/scripts beyond the GSAP CDN `<script>` tags and a small inline critical-path `<style>` for above-the-fold paint (kept minimal).
- `assets/app.css` — all styling, token definitions at top, liquid-glass utilities, responsive breakpoints. Single file (focused; no framework).
- `assets/app.js` — GSAP ScrollTrigger setup: hero scrub pinning + scroll-reveal for sections. Reduced-motion guard. ~60 lines.

---

## Task 1: Scaffold `/docs` and brand assets

**Files:**
- Create: `docs/robots.txt`
- Create: `docs/assets/icon.png` (copy from `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`)
- Create: `docs/assets/scrub-poster.png` (placeholder)
- Create: `docs/assets/scrub.mp4` (placeholder note)
- Create: `docs/assets/screenshots/.gitkeep` (so the dir exists before real screenshots)

- [ ] **Step 1: Create the docs directory tree**

```bash
cd $HOME/Work/OpenZCine-wt-landing-page
mkdir -p docs/assets/screenshots
```

- [ ] **Step 2: Copy the canonical app icon**

```bash
cp ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png docs/assets/icon.png
```

Verify: `file docs/assets/icon.png` → PNG image, 1024×1024.

- [ ] **Step 3: Create `docs/robots.txt`**

Content (allow all crawlers; point at the sitemap-free Pages URL):
```
User-agent: *
Allow: /
```

- [ ] **Step 4: Create placeholder scrub assets**

The real scrub video and poster will be supplied later (user captures from the running app). For now, create a `.gitkeep`-style marker so the directory is tracked and paths resolve, and document the expected assets in a README in the assets dir.

Create `site/assets/README.md`:
```markdown
# Landing-page assets

These assets ship with the site. Replace placeholders before launch.

- `icon.png` — canonical app icon (copied from ios assets). ✅ real.
- `scrub.mp4` — ~8-10s hero scroll-scrub video. **PLACEHOLDER until captured.**
- `scrub-poster.png` — static first-frame fallback for reduced-motion. **PLACEHOLDER until captured.**
- `og-image.png` — 1200×630 social card. **Generate from icon + wordmark.**
- `screenshots/*.png` — feature-section stills. **Capture from running app.**

The page degrades gracefully if `scrub.mp4` is absent (JS detects load failure
and shows `scrub-poster.png`, or a CSS gradient if that's also absent).
```

- [ ] **Step 5: Set repo-local git identity (first commit only)**

```bash
git config user.email "<public-email>"   # confirm with user if unknown
git config user.email    # verify it's set and is the public identity
```

- [ ] **Step 6: Stage and review**

```bash
git add docs/
git diff --staged          # read it — confirm no secrets, no vendor/ paths
just secrets               # gitleaks — must pass
```

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(landing): scaffold /docs structure and brand assets"
```

---

## Task 2: Brand tokens and base CSS

**Files:**
- Create: `docs/assets/app.css`

This task establishes the design system (colors, type, liquid-glass utilities, layout primitives) so all subsequent HTML can reference consistent classes. No page content yet.

- [ ] **Step 1: Write `docs/assets/app.css`**

```css
/* OpenZCine landing — brand tokens + base styles.
   Tokens mirror ios/Runner/Branding.swift (canonical app brand).
   No build step; this file is served as-is by GitHub Pages. */

:root {
  /* ---- Color (OKLCh, warm charcoal palette) ---- */
  --bg:         oklch(15% 0.009 62);          /* #0A0908 warm charcoal */
  --bg-deep:    oklch(10% 0.009 62);          /* deeper warm — footer */
  --surface:    oklch(23% 0.012 60);          /* #1D1813 card/device bodies */
  --ink:        oklch(94% 0.012 80);          /* #F2ECE2 warm off-white */
  --muted:      oklch(67% 0.013 72);          /* secondary text */
  --faint:      oklch(52% 0.012 68);          /* tertiary text */
  --accent:     oklch(82% 0.155 83);          /* #FFE100 Nikon gold — SOLID only */
  --accent-soft:oklch(82% 0.155 83 / .16);    /* gold @ 16% — glows, hovers */
  --rec:        oklch(63% 0.225 27);          /* REC red */

  /* ---- Liquid-glass surfaces ---- */
  --glass:        rgba(22,19,15,0.52);
  --glass-bright: rgba(40,35,28,0.55);
  --hairline:     rgba(247,239,225,0.10);
  --hairline-2:   rgba(247,239,225,0.16);
  --blur:         blur(22px) saturate(1.15);

  /* ---- Type ---- */
  --sans: 'Geist', -apple-system, 'SF Pro Text', system-ui, 'Segoe UI', sans-serif;
  --mono: 'Geist Mono', ui-monospace, 'SF Mono', Menlo, monospace;

  /* ---- Geometry ---- */
  --r-lg: 22px;
  --r-md: 16px;
  --r-sm: 11px;
  --maxw: 1120px;
}

/* ---- Reset ---- */
* { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
html { scroll-behavior: smooth; }
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
}
body {
  background: var(--bg);
  color: var(--ink);
  font-family: var(--sans);
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
img, video, svg { display: block; max-width: 100%; }
a { color: inherit; text-decoration: none; }

/* ---- Layout primitives ---- */
.container { width: 100%; max-width: var(--maxw); margin: 0 auto; padding: 0 clamp(20px, 5vw, 48px); }
.section { padding: clamp(64px, 10vw, 120px) 0; position: relative; }
.section--spot { padding: clamp(96px, 14vw, 180px) 0; }   /* spotlight sections get more space */

/* ---- Typographic scale ---- */
h1 { font-size: clamp(36px, 6vw, 68px); line-height: 1.05; letter-spacing: -0.03em; font-weight: 700; }
h2 { font-size: clamp(28px, 4vw, 44px); line-height: 1.1; letter-spacing: -0.02em; font-weight: 700; }
h3 { font-size: clamp(20px, 2.4vw, 26px); line-height: 1.2; letter-spacing: -0.01em; font-weight: 600; }
.lead { font-size: clamp(17px, 2vw, 21px); color: var(--muted); max-width: 52ch; }
.mono { font-family: var(--mono); }

/* ---- Liquid-glass utility ---- */
.glass {
  background: var(--glass);
  backdrop-filter: var(--blur);
  -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--hairline);
}
.glass--bright { background: var(--glass-bright); border-color: var(--hairline-2); }

/* ---- Accent treatments ---- */
.gold { color: var(--accent); }
.gold-glow { box-shadow: 0 0 60px var(--accent-soft); }

/* REC motif — the red dot used before section labels and on device mockups */
.rec-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--rec);
           box-shadow: 0 0 10px var(--rec); vertical-align: middle; }

/* ---- Section label (small uppercase gold tag with REC dot) ---- */
.section-label {
  display: inline-flex; align-items: center; gap: 8px;
  font-family: var(--mono); font-size: 12px; font-weight: 500;
  letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent);
  padding: 5px 12px; border-radius: 999px; border: 1px solid var(--accent-soft);
  background: var(--accent-soft);
  margin-bottom: 20px;
}

/* ---- Buttons ---- */
.btn {
  display: inline-flex; align-items: center; gap: 8px;
  font-weight: 600; font-size: 15px; padding: 12px 22px; border-radius: 999px;
  transition: transform .15s ease, box-shadow .15s ease;
  cursor: pointer; border: none;
}
.btn--primary { background: var(--accent); color: #1a1300; }
.btn--primary:hover { transform: translateY(-1px); box-shadow: 0 8px 30px var(--accent-soft); }
.btn--ghost { background: transparent; color: var(--ink); border: 1px solid var(--hairline-2); }
.btn--ghost:hover { background: var(--glass); }

/* ---- Responsive helpers ---- */
.grid { display: grid; gap: 24px; }
@media (min-width: 720px) { .grid--2 { grid-template-columns: 1fr 1fr; } }
@media (min-width: 960px) { .grid--3 { grid-template-columns: repeat(3, 1fr); } }
```

- [ ] **Step 2: Verify CSS is valid (no build step — use a quick check)**

```bash
cd $HOME/Work/OpenZCine-wt-landing-page
# If 'csstree' or similar is available, validate. Otherwise a syntax eyeball check:
node -e "const fs=require('fs'); const css=fs.readFileSync('docs/assets/app.css','utf8');
  const o=css.split('{').length, c=css.split('}').length;
  console.log('open braces:', o, 'close braces:', c, o===c?'OK ✓':'MISMATCH ✗');" 2>/dev/null \
  || echo "node not available — visual check braces balance"
```
Expected: `open braces: N close braces: N OK ✓`

- [ ] **Step 3: Commit**

```bash
git add docs/assets/app.css
git diff --staged
just secrets
git commit -m "feat(landing): brand tokens and base CSS (warm charcoal + liquid-glass)"
```

---

## Task 3: Page shell — `<head>`, nav, and footer skeleton

**Files:**
- Create: `docs/index.html`

Establishes the document head (meta, fonts, OG tags, CSS link), the sticky liquid-glass nav, and the footer with the Nikon trademark disclaimer. Section bodies are added in later tasks via edits to this same file.

- [ ] **Step 1: Write `docs/index.html` shell**

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">

  <!-- Primary meta -->
  <title>OpenZCine — Open-source field monitor for Nikon Z</title>
  <meta name="description" content="OpenZCine is a free, open-source field-monitor app for Nikon Z mirrorless cameras. Pro monitoring scopes, playback, Camera-to-Cloud export with LUT baking.">
  <meta name="theme-color" content="#0A0908">

  <!-- Open Graph / social -->
  <meta property="og:type" content="website">
  <meta property="og:title" content="OpenZCine — Open-source field monitor for Nikon Z">
  <meta property="og:description" content="Free, open-source field-monitor app for Nikon Z. Pro scopes, playback, C2C export with LUT baking.">
  <meta property="og:image" content="assets/og-image.png">
  <meta name="twitter:card" content="summary_large_image">

  <!-- Icons -->
  <link rel="icon" href="assets/icon.png">
  <link rel="apple-touch-icon" href="assets/icon.png">

  <!-- Fonts: Geist + Geist Mono (Google Fonts) -->
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">

  <!-- Styles -->
  <link rel="stylesheet" href="assets/app.css">
</head>
<body>

  <!-- ============ NAV ============ -->
  <header class="nav glass" id="nav">
    <div class="container nav__inner">
      <a href="#top" class="nav__brand">
        <img src="assets/icon.png" alt="OpenZCine" width="28" height="28">
        <span>OpenZCine</span>
      </a>
      <nav class="nav__links" aria-label="Primary">
        <a href="#scopes">Scopes</a>
        <a href="#export">Export</a>
        <a href="#open-source">Open Source</a>
        <a href="#download">Download</a>
      </nav>
      <div class="nav__cta">
        <a class="nav__github" href="REPO_URL" target="_blank" rel="noopener" aria-label="OpenZCine on GitHub">★ GitHub</a>
        <a class="btn btn--primary" href="TESTFLIGHT_URL">Join the beta</a>
      </div>
    </div>
  </header>

  <main id="top">
    <!-- HERO, SCOPES, PLAYBACK, EXPORT, OPEN-SOURCE, PLATFORMS, DOWNLOAD
         sections added in subsequent tasks -->
  </main>

  <!-- ============ FOOTER ============ -->
  <footer class="footer">
    <div class="container footer__inner">
      <div class="footer__brand">
        <img src="assets/icon.png" alt="OpenZCine" width="24" height="24">
        <span>OpenZCine</span>
      </div>
      <p class="footer__meta">
        Free &amp; open source · <a href="REPO_URL" target="_blank" rel="noopener">Apache-2.0</a>
      </p>
      <p class="footer__disclaimer">
        Not affiliated with or endorsed by Nikon Corporation. &ldquo;Nikon&rdquo;,
        &ldquo;Nikon Z&rdquo;, and &ldquo;ZR&rdquo; are trademarks of Nikon Corporation,
        used for identification only.
      </p>
    </div>
  </footer>

  <!-- GSAP + ScrollTrigger (CDN) — only dependency, for the hero scrub effect -->
  <script src="https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/gsap.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/ScrollTrigger.min.js"></script>
  <script src="assets/app.js" defer></script>
</body>
</html>
```

**Note:** `REPO_URL` and `TESTFLIGHT_URL` are placeholders. They are tracked in the spec's "Open questions" and will be replaced when the user provides them. Until then the links point at `#`-equivalent; do NOT fabricate real URLs.

- [ ] **Step 2: Add the nav/footer-specific CSS to `app.css`**

Append to `docs/assets/app.css`:
```css
/* ---- Nav ---- */
.nav { position: sticky; top: 0; z-index: 50; border-bottom: 1px solid var(--hairline); }
.nav__inner { display: flex; align-items: center; justify-content: space-between; height: 60px; gap: 16px; }
.nav__brand { display: flex; align-items: center; gap: 9px; font-weight: 700; letter-spacing: -0.01em; }
.nav__brand img { border-radius: 7px; }
.nav__links { display: none; gap: 24px; font-size: 14px; color: var(--muted); }
.nav__links a:hover { color: var(--ink); }
.nav__cta { display: flex; align-items: center; gap: 10px; }
.nav__github { font-size: 14px; color: var(--muted); }
.nav__github:hover { color: var(--ink); }
.nav__cta .btn { padding: 9px 16px; font-size: 14px; }
@media (min-width: 860px) { .nav__links { display: flex; } }
@media (max-width: 560px) { .nav__github { display: none; } }

/* ---- Footer ---- */
.footer { background: var(--bg-deep); border-top: 1px solid var(--hairline); padding: 48px 0; }
.footer__inner { display: flex; flex-direction: column; gap: 14px; }
.footer__brand { display: flex; align-items: center; gap: 9px; font-weight: 700; }
.footer__brand img { border-radius: 6px; }
.footer__meta { color: var(--muted); font-size: 14px; }
.footer__meta a:hover { color: var(--ink); }
.footer__disclaimer { color: var(--faint); font-size: 12px; line-height: 1.5; max-width: 70ch; }
```

- [ ] **Step 3: Verify locally**

```bash
cd $HOME/Work/OpenZCine-wt-landing-page/docs
python3 -m http.server 8080 &
# open http://localhost:8080 — expect: dark warm bg, sticky nav, icon, empty main, footer with disclaimer
# Ctrl-C to stop
```
Expected: page loads, no 404s in the browser console for `app.css`/`icon.png` (GSAP 404s are fine until Task 8 wires it up).

- [ ] **Step 4: Commit**

```bash
git add docs/index.html docs/assets/app.css
git diff --staged
just secrets
git commit -m "feat(landing): page shell — head, sticky glass nav, footer with trademark disclaimer"
```

---

## Task 4: Hero section + landscape device mockup

**Files:**
- Modify: `docs/index.html` (insert hero into `<main>`)
- Modify: `docs/assets/app.css` (append hero styles)

- [ ] **Step 1: Insert hero markup**

In `docs/index.html`, replace the `<main id="top">` placeholder comment block with:
```html
    <!-- ============ HERO ============ -->
    <section class="section hero" id="hero">
      <div class="container hero__inner">
        <div class="hero__copy">
          <span class="section-label"><span class="rec-dot"></span> Field Monitor · Open Beta</span>
          <h1>The open field<br>monitor for <span class="gold">Nikon Z.</span></h1>
          <p class="lead">Pro monitoring scopes, playback, and Camera-to-Cloud export with
            built-in, RED, or custom LUT baking — free and open source.</p>
          <div class="hero__cta">
            <a class="btn btn--primary" href="TESTFLIGHT_URL">Join the TestFlight beta</a>
            <a class="btn btn--ghost" href="REPO_URL" target="_blank" rel="noopener">★ Star on GitHub</a>
          </div>
        </div>

        <!-- Landscape device mockup — the scroll-scrub video target (Task 8) -->
        <div class="hero__device-wrap" id="scrub-stage">
          <div class="device device--landscape">
            <div class="device__bezel">
              <video class="device__screen" id="scrub-video"
                     poster="assets/scrub-poster.png"
                     muted playsinline preload="none">
                <source src="assets/scrub.mp4" type="video/mp4">
              </video>
              <!-- Overlays shown until real video; replaced by scrub footage later -->
              <div class="device__hud glass">
                <span class="rec-dot"></span><span class="mono">REC</span>
              </div>
              <div class="device__scope glass mono">
                <span style="height:30%"></span><span style="height:65%"></span>
                <span style="height:45%"></span><span style="height:85%"></span>
                <span style="height:30%"></span><span style="height:60%"></span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
```

- [ ] **Step 2: Append hero + device CSS to `app.css`**

```css
/* ---- Hero ---- */
.hero { padding-top: clamp(48px, 8vw, 96px); }
.hero__inner { display: grid; gap: 40px; align-items: center; }
@media (min-width: 900px) { .hero__inner { grid-template-columns: 1.1fr 1fr; } }
.hero__copy h1 { margin: 4px 0 20px; }
.hero__cta { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 28px; }

/* ---- Landscape device mockup ---- */
.device--landscape { width: 100%; max-width: 460px; margin-inline: auto; }
.device__bezel {
  position: relative; aspect-ratio: 440 / 220; border-radius: 22px;
  background: var(--surface); border: 1px solid var(--hairline-2);
  padding: 10px; overflow: hidden;
}
.device__screen {
  width: 100%; height: 100%; border-radius: 14px; object-fit: cover;
  background: linear-gradient(135deg, #1a2530, #0d1418);   /* placeholder until video loads */
}
.device__hud {
  position: absolute; top: 20px; left: 20px; padding: 4px 9px; border-radius: 7px;
  font-size: 11px; display: flex; align-items: center; gap: 6px;
}
.device__scope {
  position: absolute; top: 20px; right: 20px; width: 52px; height: 26px;
  border-radius: 6px; display: flex; align-items: flex-end; gap: 2px; padding: 4px;
}
.device__scope span { flex: 1; background: var(--accent); opacity: .85; border-radius: 1px; }
```

- [ ] **Step 3: Verify locally**

```bash
cd $HOME/Work/OpenZCine-wt-landing-page/docs
python3 -m http.server 8080 &
```
Expected at `http://localhost:8080`: two-column hero on desktop (copy left, landscape device right with REC + scope overlays); single column stacked on mobile. The video element shows the gradient placeholder (no `scrub.mp4` yet). Ctrl-C to stop.

- [ ] **Step 4: Commit**

```bash
git add docs/index.html docs/assets/app.css
git diff --staged
just secrets
git commit -m "feat(landing): hero section with landscape device mockup"
```

---

## Task 5: Spotlight — Pro Monitoring Scopes

**Files:**
- Modify: `docs/index.html` (insert after hero section)
- Modify: `docs/assets/app.css` (append spotlight + feature-grid styles)

This is the credibility core — gets extra vertical space and the gold glow treatment.

- [ ] **Step 1: Insert scopes section after the hero `</section>`**

```html
    <!-- ============ SCOPES (spotlight) ============ -->
    <section class="section section--spot spot" id="scopes">
      <div class="spot__glow" aria-hidden="true"></div>
      <div class="container">
        <span class="section-label"><span class="rec-dot"></span> Credibility Core</span>
        <h2>Industry-standard monitoring scopes.</h2>
        <p class="lead">Read your image like a professional. OpenZCine overlays the same
          scopes trusted on cinema sets, in real time on your iPhone or iPad.</p>

        <div class="grid grid--3 spot__features">
          <article class="feat glass">
            <h3>Waveform &amp; Histogram</h3>
            <p>Luma and RGB waveforms plus histogram for exposure you can trust.</p>
          </article>
          <article class="feat glass">
            <h3>Vectorscope &amp; False Color</h3>
            <p>Color science at a glance — verify skin tones and gamut on the fly.</p>
          </article>
          <article class="feat glass">
            <h3>Peaking, Zebras &amp; Guides</h3>
            <p>Focus peaking, exposure zebras, and configurable framing/aspect guides.</p>
          </article>
        </div>
      </div>
    </section>
```

- [ ] **Step 2: Append spotlight CSS to `app.css`**

```css
/* ---- Spotlight section ---- */
.spot { position: relative; overflow: hidden; }
.spot__glow {
  position: absolute; top: -10%; left: 50%; transform: translateX(-50%);
  width: 80%; height: 70%;
  background: radial-gradient(ellipse, var(--accent-soft), transparent 70%);
  pointer-events: none;
}
.spot__features { margin-top: 48px; position: relative; }
.feat { padding: 24px; border-radius: var(--r-md); }
.feat h3 { margin-bottom: 8px; }
.feat p { color: var(--muted); font-size: 15px; }
```

- [ ] **Step 3: Verify locally** — scopes section renders with gold glow halo behind a 3-column feature grid (desktop) / stacked (mobile).

```bash
python3 -m http.server 8080 --directory $HOME/Work/OpenZCine-wt-landing-page/docs
```

- [ ] **Step 4: Commit**

```bash
git add docs/index.html docs/assets/app.css
git diff --staged && just secrets
git commit -m "feat(landing): spotlight section — pro monitoring scopes"
```

---

## Task 6: Playback + Export sections

**Files:**
- Modify: `docs/index.html` (insert after scopes)
- Modify: `docs/assets/app.css` (append feature-row styles)

- [ ] **Step 1: Insert playback + export sections after the scopes `</section>`**

```html
    <!-- ============ PLAYBACK ============ -->
    <section class="section" id="playback">
      <div class="container grid grid--2 feat-row">
        <div class="feat-row__copy">
          <span class="section-label"><span class="rec-dot"></span> Playback</span>
          <h2>Review every clip, on-device.</h2>
          <p class="lead">Frame-accurate playback and scrubbing. Mark in/out, check focus,
            and never leave the field guessing.</p>
        </div>
        <div class="feat-row__visual glass">
          <div class="placeholder" data-label="playback.png"></div>
        </div>
      </div>
    </section>

    <!-- ============ EXPORT ============ -->
    <section class="section" id="export">
      <div class="container grid grid--2 feat-row">
        <div class="feat-row__visual glass">
          <div class="placeholder" data-label="export.png"></div>
        </div>
        <div class="feat-row__copy">
          <span class="section-label"><span class="rec-dot"></span> Export &amp; Camera-to-Cloud</span>
          <h2>Ship it. With LUTs baked in.</h2>
          <p class="lead">Camera-to-Cloud to frame.io, native iOS share, or direct export —
            with built-in, RED, or your own custom <span class="mono">.cube</span> LUTs
            applied on the way out.</p>
        </div>
      </div>
    </section>
```

- [ ] **Step 2: Append feature-row + placeholder CSS to `app.css`**

```css
/* ---- Feature row (alternating copy/visual) ---- */
.feat-row { align-items: center; }
.feat-row__copy h2 { margin: 4px 0 16px; }
.feat-row__visual { border-radius: var(--r-lg); padding: 12px; min-height: 220px; }
.placeholder {
  width: 100%; height: 100%; min-height: 200px; border-radius: var(--r-md);
  background:
    linear-gradient(135deg, rgba(255,225,0,0.04), transparent),
    repeating-linear-gradient(45deg, rgba(255,255,255,0.02) 0 12px, transparent 12px 24px),
    var(--surface);
  display: flex; align-items: center; justify-content: center;
}
.placeholder::after {
  content: "screenshot: " attr(data-label);
  font-family: var(--mono); font-size: 12px; color: var(--faint);
}
@media (min-width: 900px) { .feat-row--reverse .feat-row__copy { order: 2; } }
```

- [ ] **Step 3: Verify locally** — two alternating rows (copy left/visual right, then reversed), placeholders labeled with the future screenshot filenames.

- [ ] **Step 4: Commit**

```bash
git add docs/index.html docs/assets/app.css
git diff --staged && just secrets
git commit -m "feat(landing): playback and export sections"
```

---

## Task 7: Spotlight — Open Source + Platforms + Download CTA

**Files:**
- Modify: `docs/index.html` (insert before footer)
- Modify: `docs/assets/app.css` (append closing-section styles)

- [ ] **Step 1: Insert open-source spotlight, platforms, and download sections after export `</section>`**

```html
    <!-- ============ OPEN SOURCE (spotlight) ============ -->
    <section class="section section--spot spot" id="open-source">
      <div class="spot__glow" aria-hidden="true"></div>
      <div class="container spot-oss__inner">
        <span class="section-label"><span class="rec-dot"></span> Identity Core</span>
        <h2>100% free. Open source. Yours.</h2>
        <p class="lead">No subscriptions, no paywalls, no telemetry. OpenZCine is Apache-2.0
          licensed and built in the open by a community of filmmakers and developers.</p>
        <div class="hero__cta">
          <a class="btn btn--primary" href="REPO_URL" target="_blank" rel="noopener">★ Star on GitHub</a>
          <a class="btn btn--ghost" href="REPO_URL" target="_blank" rel="noopener">Contribute</a>
        </div>
      </div>
    </section>

    <!-- ============ PLATFORMS & CAMERAS ============ -->
    <section class="section" id="platforms">
      <div class="container grid grid--2">
        <div class="feat glass">
          <h3>Platforms</h3>
          <ul class="ticks">
            <li>iPhone · iPad · Apple Watch <span class="badge">today</span></li>
            <li>Android <span class="badge badge--soon">soon</span></li>
          </ul>
        </div>
        <div class="feat glass">
          <h3>Supported cameras</h3>
          <ul class="ticks">
            <li>Nikon ZR <span class="badge">first</span></li>
            <li>Full Nikon Z mirrorless line <span class="badge badge--soon">roadmap</span></li>
          </ul>
        </div>
      </div>
    </section>

    <!-- ============ DOWNLOAD / FINAL CTA ============ -->
    <section class="section" id="download">
      <div class="container cta-final">
        <h2>Ready to monitor like a pro?</h2>
        <p class="lead">Join the TestFlight beta and help shape OpenZCine.</p>
        <div class="hero__cta">
          <a class="btn btn--primary" href="TESTFLIGHT_URL">Join the TestFlight beta</a>
          <a class="btn btn--ghost" href="REPO_URL" target="_blank" rel="noopener">★ Star on GitHub</a>
        </div>
      </div>
    </section>
```

- [ ] **Step 2: Append closing CSS to `app.css`**

```css
/* ---- Open-source spotlight ---- */
.spot-oss__inner { text-align: center; display: flex; flex-direction: column; align-items: center; }
.spot-oss__inner .lead { margin-bottom: 24px; }

/* ---- Ticks + badges ---- */
.ticks { list-style: none; display: flex; flex-direction: column; gap: 10px; margin-top: 12px; }
.ticks li { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.badge {
  font-family: var(--mono); font-size: 11px; padding: 2px 9px; border-radius: 999px;
  background: var(--accent-soft); color: var(--accent); border: 1px solid var(--accent-soft);
}
.badge--soon { background: transparent; color: var(--muted); border-color: var(--hairline-2); }

/* ---- Final CTA ---- */
.cta-final { text-align: center; display: flex; flex-direction: column; align-items: center; }
.cta-final h2 { margin-bottom: 12px; }
.cta-final .hero__cta { margin-top: 24px; }
```

- [ ] **Step 3: Verify locally** — full page now renders all 7 sections top to bottom.

```bash
python3 -m http.server 8080 --directory $HOME/Work/OpenZCine-wt-landing-page/docs
```

- [ ] **Step 4: Commit**

```bash
git add docs/index.html docs/assets/app.css
git diff --staged && just secrets
git commit -m "feat(landing): open-source spotlight, platforms, and final CTA"
```

---

## Task 8: Scroll-scrub video + reveal animations (`app.js`)

**Files:**
- Create: `docs/assets/app.js`

The single premium motion moment: hero device mockup pins and the scrub video's `currentTime` follows scroll. Plus subtle reveal-on-scroll for sections. Full reduced-motion guard.

- [ ] **Step 1: Write `docs/assets/app.js`**

```js
/* OpenZCine landing — scroll-scrub hero + reveal animations.
   Depends on GSAP + ScrollTrigger (loaded via CDN in index.html).
   Honors prefers-reduced-motion: falls back to a static poster frame. */

(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---- Section reveal (subtle fade/slide up on scroll) ----
  function initReveals() {
    if (reduceMotion || !window.gsap) return;
    gsap.utils.toArray(".section").forEach((sec) => {
      gsap.from(sec, {
        opacity: 0,
        y: 24,
        duration: 0.6,
        ease: "power2.out",
        scrollTrigger: { trigger: sec, start: "top 85%" },
      });
    });
  }

  // ---- Hero scroll-scrub: bind video.currentTime to scroll ----
  function initScrub() {
    const video = document.getElementById("scrub-video");
    const stage = document.getElementById("scrub-stage");
    if (!video || !stage || !window.gsap || !window.ScrollTrigger) return;

    // No scrub under reduced motion — leave the poster frame visible.
    if (reduceMotion) return;

    // Ensure metadata is loaded so duration is known before binding.
    const ready = new Promise((resolve) => {
      if (video.readyState >= 1) return resolve();
      video.addEventListener("loadedmetadata", resolve, { once: true });
      // If the source 404s (placeholder phase), bail gracefully.
      video.addEventListener("error", () => resolve("no-video"), { once: true });
    });

    ready.then((result) => {
      if (result === "no-video" || !video.duration) {
        // Placeholder phase: keep the CSS gradient + HUD overlays. Nothing to scrub.
        return;
      }

      gsap.registerPlugin(ScrollTrigger);

      // Pin the device and scrub the video across a 600px trigger zone.
      ScrollTrigger.create({
        trigger: stage,
        start: "top 75%",
        end: "+=600",
        pin: true,
        scrub: true,
        onUpdate: (self) => {
          video.currentTime = self.progress * video.duration;
        },
      });
    });
  }

  // Defer until DOM is parsed (script is loaded with `defer`, but guard anyway).
  function init() {
    initReveals();
    initScrub();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
```

- [ ] **Step 2: Verify locally with the placeholder (no `scrub.mp4` yet)**

```bash
python3 -m http.server 8080 --directory $HOME/Work/OpenZCine-wt-landing-page/docs
```
Expected: page loads, no JS errors in console beyond an expected `scrub.mp4` 404 (handled gracefully — the `error` handler bails and leaves the gradient + overlays). Sections still fade in on scroll. The page is fully functional without the video.

- [ ] **Step 3: Test reduced-motion fallback**

Toggle macOS: System Settings → Accessibility → Display → Reduce Motion (on). Reload.
Expected: no section fade-ins, no scrub pinning — page is static and fully readable. Toggle off, reload, confirm motion returns.

- [ ] **Step 4: Commit**

```bash
git add docs/assets/app.js
git diff --staged && just secrets
git commit -m "feat(landing): scroll-scrub hero video + reveal animations with reduced-motion guard"
```

---

## Task 9: Optional deploy Action (HTML + asset validation)

**Files:**
- Create: `.github/workflows/deploy-pages.yml`

Catches broken links/images and invalid HTML before they ship. Must pass `actionlint` (part of `just check`). Follows existing repo workflow conventions if any exist; otherwise a standard Pages-deploy action.

- [ ] **Step 1: Check existing workflow conventions**

```bash
ls $HOME/Work/OpenZCine-wt-landing-page/.github/workflows/ 2>/dev/null
```
If workflows exist, read one to match style (job names, permissions, action versions) before writing.

- [ ] **Step 2: Write `.github/workflows/deploy-pages.yml`**

```yaml
name: Deploy landing page

on:
  push:
    branches: [main]
    paths:
      - "docs/**"
      - ".github/workflows/deploy-pages.yml"
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: deploy-pages
  cancel-in-progress: true

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4

      # Validate that every asset path referenced in index.html resolves.
      # Cheap guard against broken images/videos shipping to the live site.
      - name: Verify asset references
        run: |
          set -e
          cd docs
          missing=0
          for ref in $(grep -oE '(src|href)="assets/[^"]+"' index.html | sed -E 's/.*"assets\/([^"]+)"/\1/'); do
            if [ ! -f "assets/$ref" ]; then
              echo "::error::Missing asset referenced in index.html: assets/$ref"
              missing=1
            fi
          done
          exit $missing

      - name: Setup Pages
        uses: actions/configure-pages@v5

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: docs

      - name: Deploy to GitHub Pages
        id: deploy
        uses: actions/deploy-pages@v4
```

- [ ] **Step 3: Validate with actionlint**

```bash
cd $HOME/Work/OpenZCine-wt-landing-page
just lint-actions      # runs actionlint if .github/workflows exists
```
Expected: no errors. Fix any actionlint findings (common: version pinning, `permissions` keys) before committing.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy-pages.yml
git diff --staged && just secrets
git commit -m "ci(landing): deploy landing page to GitHub Pages with asset validation"
```

---

## Task 10: Repo-wide checks + final verification

**Files:** none (verification only)

Run the full quality gate and confirm everything passes before opening a PR.

- [ ] **Step 1: Run the full repo check**

```bash
cd $HOME/Work/OpenZCine-wt-landing-page
just check
```
Expected: all green. Pay attention to:
- `typos` — fix any flagged copy in `index.html` / spec / plan
- `markdownlint` — fix any formatting in the spec/plan docs
- `lychee` (`check-links`) — all `/docs/assets/*` references must resolve; external links (Google Fonts, jsdelivr CDN, `REPO_URL`/`TESTFLIGHT_URL` placeholders) — lychee runs `--offline` so external links aren't checked, but the placeholders must not be malformed
- `editorconfig` — ensure `index.html`/`app.css`/`app.js` match the repo's `.editorconfig` (indent style, trailing newline)

- [ ] **Step 2: Manual responsive + accessibility sweep**

```bash
python3 -m http.server 8080 --directory $HOME/Work/OpenZCine-wt-landing-page/docs
```
Check in browser DevTools:
- Desktop (1280px): two-column hero, 3-column scopes, alternating export rows
- Tablet (768px): grids collapse
- Mobile (375px): single column, nav links hidden, GitHub link hidden, hamburger if added (nav collapses gracefully even without a hamburger — links are `display:none` under 860px, brand + CTA remain visible)
- Accessibility: tab through nav — focus visible; `alt` text on icon; landmark roles (`<header>`, `<main>`, `<nav>`, `<footer>`) present; color contrast meets AA (gold on dark, off-white on dark — both pass)

- [ ] **Step 3: If any issues, fix and commit per-issue**

```bash
# example
git add docs/assets/app.css
git diff --staged && just secrets
git commit -m "fix(landing): correct mobile breakpoint for nav"
```

- [ ] **Step 4: Push the branch**

```bash
git push -u origin landing-page
```

- [ ] **Step 5: Open a PR**

```bash
gh pr create --base main --head landing-page \
  --title "feat: OpenZCine landing page (GitHub Pages)" \
  --body "Single-page marketing site deployed from /docs via GitHub Pages.
Canonical brand (warm charcoal + Nikon gold + Geist + liquid-glass).
Scroll-scrub hero with reduced-motion fallback. Placeholder scrub video — real footage to follow.

Spec: docs/design/specs/2026-07-06-landing-page-design.md
Plan: docs/design/plans/2026-07-06-landing-page.md

Follow-ups (after merge):
- Replace placeholder scrub.mp4 + scrub-poster.png with real captures
- Provide TestFlight URL and repo URL (replace TESTFLIGHT_URL/REPO_URL placeholders)
- Generate og-image.png (1200×630)
- Enable GitHub Pages: Settings → Pages → Deploy from main /docs"
```

- [ ] **Step 6: Do NOT merge until user confirms.** Hand off: report the PR URL, the manual-enable steps for GitHub Pages, and the list of follow-ups (placeholders to replace).

---

## Self-review notes (run after writing the plan)

**Spec coverage:**
- ✅ Brand (warm palette, solid gold, Geist, liquid-glass) — Task 2 tokens
- ✅ Hosting (GitHub Pages from /docs, separate from website/) — Tasks 1, 9
- ✅ Nav (sticky, glass, anchors, GitHub + beta) — Task 3
- ✅ 7 sections, two spotlights — Tasks 4–7
- ✅ Scroll-scrub video with reduced-motion fallback — Task 8
- ✅ Apache 2.0 + Nikon trademark disclaimer in footer — Task 3
- ✅ Performance (lazy video, font-display swap) — Tasks 3, 8
- ✅ Responsive — Task 10 verification + per-task CSS media queries
- ✅ Originality (no copying reference app) — called out in conventions

**Placeholders:** `REPO_URL` and `TESTFLIGHT_URL` are intentional, tracked in the spec's open questions, and the deploy Action's asset check + the graceful video fallback ensure the page works without them. No TBD/TODO in the plan itself.

**Type/identifier consistency:** `scrub-video` / `scrub-stage` IDs match between Task 4 (HTML) and Task 8 (JS). `.section`, `.section-label`, `.glass`, `.btn`, `.hero__cta` classes used consistently across tasks.
