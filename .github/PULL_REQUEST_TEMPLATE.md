## What & why

<!-- What does this PR change, and why? Link any related issue. -->

## TestFlight notes

<!--
If this PR changes Sources/, Tests/, ios/, Package.swift, scripts/, or justfile, replace
ios/TestFlight/WhatToTest.en-US.txt with short copy for non-developer camera operators:
- 1-5 visible changes, written as outcomes rather than implementation details.
- 1-4 concrete actions under "Please test".
For an internal-only build, say that there are no tester-facing app changes and ask testers to
continue their normal camera workflow.
-->

## Google Play notes

<!--
If this PR changes the Android app/core or its build and release tooling, update
Apps/Android/distribution/whatsnew/whatsnew-en-US with 1-5 short, tester-facing bullets.
For internal-only work, say that there are no visible app changes and ask testers to continue
their normal camera workflow.
-->

## Checklist

- [ ] `just check` passes.
- [ ] Native production changes: `just native-check` passes, or the relevant platform check is noted.
- [ ] Legacy prototype/reference changes are intentionally included or left local.
- [ ] Commits follow Conventional Commits.
- [ ] No proprietary assets (`vendor/`, `ref/`) are included.
- [ ] Docs/CHANGELOG updated if behavior or setup changed.
- [ ] TestFlight-triggering changes include reviewed `ios/TestFlight/WhatToTest.en-US.txt` copy.
- [ ] Play-triggering changes include reviewed `Apps/Android/distribution/whatsnew/whatsnew-en-US` copy.
- [ ] iOS release PRs: bump `MARKETING_VERSION` in `ios/Config/Version.xcconfig` when appropriate.
