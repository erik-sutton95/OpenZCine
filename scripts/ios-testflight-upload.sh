#!/usr/bin/env bash
# Archive and upload OpenZCine to TestFlight (CI and maintainer use).
#
# App Store Connect API credentials (upload):
#   APP_STORE_CONNECT_API_KEY_ID
#   APP_STORE_CONNECT_API_ISSUER_ID
#   APP_STORE_CONNECT_API_PRIVATE_KEY  (optional — installs the .p8 when set)
#
# Distribution signing (CI archive/export):
#   IOS_DISTRIBUTION_CERTIFICATE_BASE64
#   IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
#   IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64
#   IOS_WATCH_DISTRIBUTION_PROVISIONING_PROFILE_BASE64  (optional local override)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

archive_path="build/ios/OpenZCine.xcarchive"
export_path="build/ios/export"
mkdir -p build/ios

manual_signing=0
# DEVELOPMENT_TEAM applies to all targets (including SPM packages). Manual signing remains
# target-scoped through the iPhone and Watch CI xcconfig files.
signing_args=(DEVELOPMENT_TEAM=4V4EGQ6LZA)
if [[ -n "${IOS_DISTRIBUTION_CERTIFICATE_BASE64:-}" ]]; then
  manual_signing=1
fi

xcode_auth_args=()
if [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
  if [[ -n "${APP_STORE_CONNECT_API_PRIVATE_KEY:-}" ]]; then
    "$ROOT/scripts/ios-install-asc-api-key.sh"
  fi
  key_path="${APP_STORE_CONNECT_API_KEY_PATH:-${HOME}/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8}"
  if [[ ! -f "$key_path" ]]; then
    echo "App Store Connect API key not found at ${key_path}" >&2
    exit 1
  fi
  export APP_STORE_CONNECT_API_KEY_PATH="$key_path"
  if [[ "$manual_signing" -eq 0 ]]; then
    xcode_auth_args=(
      -allowProvisioningUpdates
      -authenticationKeyPath "$key_path"
      -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID"
      -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID"
    )
  fi
fi

if [[ "$manual_signing" -eq 1 ]]; then
  # shellcheck source=scripts/ios-install-distribution-signing.sh
  . "$ROOT/scripts/ios-install-distribution-signing.sh"
fi

if [[ "$manual_signing" -eq 0 && "${CI:-}" == "true" ]]; then
  echo "CI TestFlight requires distribution signing secrets." >&2
  echo "Automatic cloud signing is unreliable on GitHub Actions for this project." >&2
  echo "See docs/testflight-ci.md § Distribution signing secrets." >&2
  exit 1
fi

if [[ "$manual_signing" -eq 1 ]]; then
  export_plist="build/ios/ExportOptions-manual.plist"
  cat >"$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>4V4EGQ6LZA</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.opencapture.openzcine</key>
    <string>${IOS_PROVISIONING_PROFILE_NAME}</string>
    <key>com.opencapture.openzcine.watch</key>
    <string>${IOS_WATCH_PROVISIONING_PROFILE_NAME}</string>
  </dict>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF
else
  export_plist="ios/ExportOptions.plist"
fi

echo "Archiving Release build…"
xcodebuild -project ios/Runner.xcodeproj \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  "${signing_args[@]}" \
  "${xcode_auth_args[@]+"${xcode_auth_args[@]}"}" \
  archive

echo "Exporting (${export_plist})…"
rm -rf "$export_path"
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_plist" \
  "${signing_args[@]}" \
  "${xcode_auth_args[@]+"${xcode_auth_args[@]}"}"

# Xcode names the IPA after the app's display name (OpenZCine.ipa), not the target.
ipa_path="$(find "$export_path" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "$ipa_path" ]]; then
  echo "No .ipa found in $export_path" >&2
  exit 1
fi

echo "IPA: $ipa_path"

if [[ "${CI:-}" == "true" || "${IOS_UPLOAD_VIA_ALTOOL:-}" == "1" ]]; then
  echo "Uploading IPA via altool…"
  if [[ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
    echo "Set APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID for upload." >&2
    exit 1
  fi
  xcrun altool --upload-app -f "$ipa_path" -t ios \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
fi

echo "TestFlight upload complete."
