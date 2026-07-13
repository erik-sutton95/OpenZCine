#!/usr/bin/env bash
# Compute TestFlight CI version numbers.
#
# Default marketing version: the stable version committed in ios/Config/Version.xcconfig.
# CI increments only the build number so later builds stay in the same TestFlight version train.
#
# Env:
#   IOS_BUILD_NUMBER_OFFSET  (default 100)
#   GITHUB_RUN_NUMBER
#   MARKETING_VERSION_INPUT  optional full override (e.g. 0.2.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/ios/Config/Version.xcconfig"

base="$(sed -n 's/^MARKETING_VERSION = //p' "$VERSION_FILE" | head -1)"
base="${base:-0.1.0}"

offset="${IOS_BUILD_NUMBER_OFFSET:-100}"
run_number="${GITHUB_RUN_NUMBER:-1}"
build_number=$(( offset + run_number ))

if [[ -n "${MARKETING_VERSION_INPUT:-}" ]]; then
  marketing_version="${MARKETING_VERSION_INPUT}"
else
  marketing_version="${base}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "marketing_version=${marketing_version}" >>"$GITHUB_OUTPUT"
  echo "build_number=${build_number}" >>"$GITHUB_OUTPUT"
fi

echo "TestFlight version: ${marketing_version} (build ${build_number})"

MARKETING_VERSION="${marketing_version}" BUILD_NUMBER="${build_number}" "$ROOT/scripts/ios-set-version.sh"
