# Local design and demo resources

Large or private working media stays in the gitignored `.local/` directory. This keeps the public
repository and deployment artifacts small while preserving a predictable local workflow.

```text
.local/
├── demo/feeds/                    # local stills used by the Debug demo harness
├── marketing/iphone/captures/     # raw simulator captures
├── marketing/iphone/exports/      # curated working exports
├── marketing/landing-page/sources/# full-resolution landing inputs
├── marketing/sources/             # layered PSD and other editable sources
├── marketing/watch/               # watch capture inputs
└── tooling-migrations/             # incomplete local agent-tool migrations
```

`ZC_DEMO_FEED_DIR` points directly at `.local/demo/feeds/`. The loader scans only files in that
directory, not nested folders, so marketing exports cannot become demo feeds accidentally.

Never force-add `.local/`. Before promoting an asset into `site/` or an app asset catalog, confirm
redistribution rights, remove private metadata, obscure identifying details where appropriate, and
export only the optimized runtime format.
