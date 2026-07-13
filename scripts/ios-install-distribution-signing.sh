#!/usr/bin/env bash
# Install the Apple Distribution certificate and App Store provisioning profiles for CI.
#
# Expects:
#   IOS_DISTRIBUTION_CERTIFICATE_BASE64
#   IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
#   IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64
#   IOS_WATCH_DISTRIBUTION_PROVISIONING_PROFILE_BASE64  (optional local override)
#
# Exports (via GITHUB_ENV when present):
#   IOS_PROVISIONING_PROFILE_NAME
#   IOS_WATCH_PROVISIONING_PROFILE_NAME
#   IOS_CODE_SIGN_IDENTITY
#   IOS_KEYCHAIN_PATH
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ -z "${IOS_DISTRIBUTION_CERTIFICATE_BASE64:-}" || -z "${IOS_DISTRIBUTION_CERTIFICATE_PASSWORD:-}" || -z "${IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64:-}" ]]; then
  echo "Missing distribution signing secrets." >&2
  echo "Add IOS_DISTRIBUTION_CERTIFICATE_BASE64, IOS_DISTRIBUTION_CERTIFICATE_PASSWORD," >&2
  echo "and IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64 to the testflight environment." >&2
  echo "See docs/testflight-ci.md for export instructions." >&2
  exit 1
fi

KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/ios-build.keychain-db"
KEYCHAIN_PASSWORD="${IOS_KEYCHAIN_PASSWORD:-$(openssl rand -base64 32)}"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security default-keychain -s "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"

cert_path="$(mktemp).p12"
profile_path="$(mktemp).mobileprovision"
profile_plist="$(mktemp).plist"
watch_profile_path="$(mktemp).mobileprovision"
watch_profile_plist="$(mktemp).plist"
trap 'rm -f "$cert_path" "$profile_path" "$profile_plist" "$watch_profile_path" "$watch_profile_plist"' EXIT

printf '%s' "$IOS_DISTRIBUTION_CERTIFICATE_BASE64" | base64 --decode >"$cert_path"
printf '%s' "$IOS_DISTRIBUTION_PROVISIONING_PROFILE_BASE64" | base64 --decode >"$profile_path"

security import "$cert_path" -P "$IOS_DISTRIBUTION_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
existing_keychains=()
while IFS= read -r keychain; do
  keychain="${keychain//\"/}"
  [[ -n "$keychain" ]] && existing_keychains+=("$keychain")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing_keychains[@]}"

certificate_sha256="$(
  security find-certificate -c 'Apple Distribution' -p "$KEYCHAIN_PATH" \
    | openssl x509 -outform DER \
    | shasum -a 256 \
    | awk '{print $1}'
)"
if [[ ! "$certificate_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Could not fingerprint the imported Apple Distribution certificate." >&2
  exit 1
fi

if [[ -n "${IOS_WATCH_DISTRIBUTION_PROVISIONING_PROFILE_BASE64:-}" ]]; then
  printf '%s' "$IOS_WATCH_DISTRIBUTION_PROVISIONING_PROFILE_BASE64" | base64 --decode >"$watch_profile_path"
else
  if [[ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" || -z "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
    echo "Creating the Watch profile requires the App Store Connect API key." >&2
    exit 1
  fi
  IOS_DISTRIBUTION_CERTIFICATE_SHA256="$certificate_sha256" \
    IOS_WATCH_PROFILE_OUTPUT_PATH="$watch_profile_path" \
    ruby "$ROOT/scripts/ios-create-watch-profile.rb"
fi

security cms -D -i "$profile_path" -o "$profile_plist"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist")"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
profile_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")"

security cms -D -i "$watch_profile_path" -o "$watch_profile_plist"
watch_profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$watch_profile_plist")"
watch_profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$watch_profile_plist")"
watch_profile_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$watch_profile_plist")"

if [[ "${profile_app_identifier#*.}" != "com.opencapture.openzcine" ]]; then
  echo "iPhone provisioning profile does not match com.opencapture.openzcine." >&2
  exit 1
fi
if [[ "${watch_profile_app_identifier#*.}" != "com.opencapture.openzcine.watch" ]]; then
  echo "Watch provisioning profile does not match com.opencapture.openzcine.watch." >&2
  exit 1
fi

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$profile_path" "$HOME/Library/MobileDevice/Provisioning Profiles/${profile_uuid}.mobileprovision"
cp "$watch_profile_path" "$HOME/Library/MobileDevice/Provisioning Profiles/${watch_profile_uuid}.mobileprovision"

identity="$(
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
    | grep 'Apple Distribution' \
    | head -1 \
    | sed -n 's/.*"\([^"]*\)".*/\1/p'
)"
identity="${identity:-Apple Distribution}"

export IOS_PROVISIONING_PROFILE_NAME="$profile_name"
export IOS_WATCH_PROVISIONING_PROFILE_NAME="$watch_profile_name"
export IOS_CODE_SIGN_IDENTITY="$identity"
export IOS_KEYCHAIN_PATH="$KEYCHAIN_PATH"

# Keep manual signing target-scoped. Passing it on the xcodebuild CLI also applies it to SPM
# resource bundles, which do not have provisioning profiles.
mkdir -p "$ROOT/ios/Config"
cat >"$ROOT/ios/Config/CI-Signing.xcconfig" <<EOF
// Generated by scripts/ios-install-distribution-signing.sh — do not commit.
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = ${identity}
PROVISIONING_PROFILE_SPECIFIER = ${profile_name}
EOF
cat >"$ROOT/ios/Config/CI-Watch-Signing.xcconfig" <<EOF
// Generated by scripts/ios-install-distribution-signing.sh — do not commit.
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = ${identity}
PROVISIONING_PROFILE_SPECIFIER = ${watch_profile_name}
EOF

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "IOS_PROVISIONING_PROFILE_NAME=${profile_name}"
    echo "IOS_WATCH_PROVISIONING_PROFILE_NAME=${watch_profile_name}"
    echo "IOS_CODE_SIGN_IDENTITY=${identity}"
    echo "IOS_KEYCHAIN_PATH=${KEYCHAIN_PATH}"
  } >>"$GITHUB_ENV"
fi

echo "Installed distribution profile: ${profile_name}"
echo "Installed Watch distribution profile: ${watch_profile_name}"
echo "Using signing identity: ${identity}"
