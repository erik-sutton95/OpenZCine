#!/bin/sh
# Xcode Cloud: validate the reviewed TestFlight "What to Test" notes for distributed builds.
# Xcode Cloud picks up WhatToTest.<locale>.txt from the tracked TestFlight folder next to
# the ci_scripts folder (i.e. ios/TestFlight/).
set -eu

if [ -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH"
  ./scripts/ios-release-notes.sh
fi

# Every successful Cloud archive carries the reporting destination; dSYMs go to openzcine-ios
# when SENTRY_UPLOAD_ENABLED=true (OpenCine scripts/sentry, as Pocket and Insta).
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] \
    && [ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH"
  python3 ../OpenCine/scripts/sentry/sentry-verify-ios-dsn.py \
    --plist "${CI_ARCHIVE_PATH}/Products/Applications/Runner.app/Info.plist" --require
  if [ "${SENTRY_UPLOAD_ENABLED:-}" = "true" ]; then
    install_dir="${CI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}}/opc-sentry-cli"
    bash ../OpenCine/scripts/sentry/sentry-install.sh --install-dir "$install_dir"
    PATH="${install_dir}:${PATH}"
    export PATH
    python3 ../OpenCine/scripts/sentry/sentry-upload.py --platform ios --project openzcine-ios
  fi
fi
