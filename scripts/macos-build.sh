#!/usr/bin/env bash
# Build the Mac Catalyst camera module (Runner.app, bundle com.opencapture.openzcine.module) for the
# OpenCine desktop app, signed with the team's development identity. Extra arguments go to xcodebuild.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${MACOS_DERIVED_DATA_PATH:-$repo_root/build/macos/DerivedData}"
configuration="${MACOS_CONFIGURATION:-Debug}"
exec xcodebuild \
  -project "$repo_root/ios/Runner.xcodeproj" \
  -scheme Runner \
  -configuration "$configuration" \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  "$@" build
