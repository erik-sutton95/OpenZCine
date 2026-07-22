# Landing-page assets

This directory contains deploy-ready assets only. Raw screenshots, layered design files, and
full-resolution exports belong under the gitignored `.local/marketing/` tree and must not be added
to `site/`.

## Runtime assets

- `icon.png` is the canonical OpenZCine app icon copied from the iOS asset catalog.
- `screens/*.webp` are optimized landing-page mockups loaded by `site/index.html`.
- `screens/hero-set.webp` is the AI-generated hero backdrop. The page discloses that origin next to
  the image.
- `screens/ipad-monitor-v2.webp` combines an OpenZCine simulator capture with an AI-generated iPad
  hardware mockup. Its prominent faces are privacy-obscured for the public site.
- `frameio-mark.svg` identifies the optional Frame.io integration. Frame.io and its mark belong to
  Adobe and are used only for product identification.

The app-screen mockups are OpenZCine UI exports. Any family footage visible inside them is
owner-supplied and has faces intentionally blurred for the public site.

## Local source layout

Keep editable and high-resolution inputs outside Git under:

```text
.local/marketing/
├── iphone/captures/
├── iphone/exports/
├── landing-page/sources/screens/
├── sources/
└── watch/
```

Regenerate a WebP after editing its local PNG source with a command such as:

```sh
cwebp -q 82 -alpha_q 90 -resize 1600 0 source.png -o site/assets/screens/output.webp
```

The deployed `site/` tree should remain free of PSD files, full-resolution PNG sources, personal
capture filenames, and other non-runtime material.

GitHub Pages replaces `TESTFLIGHT_URL` from the public repository variable of the same name. The
deployment fails unless it is a valid `https://testflight.apple.com/join/...` URL. Run
`just site-check` before committing landing-page changes.
