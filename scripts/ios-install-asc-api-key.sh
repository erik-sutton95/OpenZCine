#!/usr/bin/env bash
# Install App Store Connect API key for xcodebuild -allowProvisioningUpdates and altool.
#
# Expects:
#   APP_STORE_CONNECT_API_KEY_ID
#   APP_STORE_CONNECT_API_ISSUER_ID
#   APP_STORE_CONNECT_API_PRIVATE_KEY  (full .p8 file contents)
set -euo pipefail

if [[ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" || -z "${APP_STORE_CONNECT_API_PRIVATE_KEY:-}" ]]; then
  echo "Missing App Store Connect API key environment variables." >&2
  exit 1
fi

key_dir="${HOME}/private_keys"
key_path="${key_dir}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
mkdir -p "$key_dir"
printf '%s\n' "$APP_STORE_CONNECT_API_PRIVATE_KEY" >"$key_path"
chmod 600 "$key_path"

export APP_STORE_CONNECT_API_KEY_PATH="$key_path"
echo "App Store Connect API key installed at ${key_path}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "APP_STORE_CONNECT_API_KEY_PATH=${key_path}" >>"$GITHUB_ENV"
fi
