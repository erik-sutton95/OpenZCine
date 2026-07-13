#!/usr/bin/env bash
# Set iOS marketing version and build number in ios/Config/Version.xcconfig.
#
# Usage:
#   MARKETING_VERSION=0.2.0 BUILD_NUMBER=142 ./scripts/ios-set-version.sh
#
# When omitted, MARKETING_VERSION is read from the existing xcconfig; BUILD_NUMBER defaults to 1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/ios/Config/Version.xcconfig"

read_xcconfig_value() {
  local key="$1"
  local file="$2"
  sed -n "s/^${key} = \\(.*\\)/\\1/p" "$file" | head -1
}

MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

if [[ -z "$MARKETING_VERSION" && -f "$VERSION_FILE" ]]; then
  MARKETING_VERSION="$(read_xcconfig_value MARKETING_VERSION "$VERSION_FILE")"
fi

if [[ -z "$BUILD_NUMBER" && -f "$VERSION_FILE" ]]; then
  BUILD_NUMBER="$(read_xcconfig_value CURRENT_PROJECT_VERSION "$VERSION_FILE")"
fi

MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if ! [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "MARKETING_VERSION must be semver major.minor.patch (got: $MARKETING_VERSION)" >&2
  exit 1
fi

if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be a positive integer (got: $BUILD_NUMBER)" >&2
  exit 1
fi

mkdir -p "$(dirname "$VERSION_FILE")"
cat >"$VERSION_FILE" <<EOF
// App semver and build number — single source of truth for local builds and CI.
//
// Keep MARKETING_VERSION stable across TestFlight builds; bump it only for a new version train.
// CI overwrites CURRENT_PROJECT_VERSION on each TestFlight upload (monotonic build numbers).
MARKETING_VERSION = ${MARKETING_VERSION}
CURRENT_PROJECT_VERSION = ${BUILD_NUMBER}
EOF

echo "iOS version set to ${MARKETING_VERSION} (${BUILD_NUMBER})"
