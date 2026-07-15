#!/bin/sh
# Xcode Cloud: validate the reviewed TestFlight "What to Test" notes for distributed builds.
# Xcode Cloud picks up WhatToTest.<locale>.txt from the tracked TestFlight folder next to
# the ci_scripts folder (i.e. ios/TestFlight/).
set -eu

if [ -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH"
  ./scripts/ios-release-notes.sh
fi
