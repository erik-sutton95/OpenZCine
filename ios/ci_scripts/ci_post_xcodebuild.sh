#!/bin/sh
# Xcode Cloud: generate TestFlight "What to Test" notes for distributed builds.
# Xcode Cloud picks up WhatToTest.<locale>.txt from a TestFlight folder placed next to
# the ci_scripts folder (i.e. ios/TestFlight/).
set -eu

if [ -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH"
  # Xcode Cloud clones shallow; the notes script reads the last 25 commits.
  git fetch --deepen 25 || true
  mkdir -p ios/TestFlight
  ./scripts/ios-release-notes.sh 25 > ios/TestFlight/WhatToTest.en-US.txt
  cat ios/TestFlight/WhatToTest.en-US.txt
fi
