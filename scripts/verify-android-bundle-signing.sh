#!/usr/bin/env bash
# Require both Play bundles to be signed by the configured upload-key alias.
set -euo pipefail

fail() {
  printf 'Android bundle signing check failed: %s\n' "$1" >&2
  exit 1
}

[[ $# -ge 1 ]] || fail "pass at least one .aab path"
: "${ANDROID_KEYSTORE_PATH:?ANDROID_KEYSTORE_PATH is required}"
: "${ANDROID_KEYSTORE_PASSWORD:?ANDROID_KEYSTORE_PASSWORD is required}"
: "${ANDROID_KEY_ALIAS:?ANDROID_KEY_ALIAS is required}"

fingerprint_from_keystore="$({
  keytool -list -v \
    -keystore "$ANDROID_KEYSTORE_PATH" \
    -storepass "$ANDROID_KEYSTORE_PASSWORD" \
    -alias "$ANDROID_KEY_ALIAS"
} | sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':')"

[[ -n "$fingerprint_from_keystore" ]] || fail "could not read the upload-key SHA-256 fingerprint"

for bundle_path in "$@"; do
  [[ -f "$bundle_path" ]] || fail "missing ${bundle_path}"
  jarsigner -verify "$bundle_path" >/dev/null || fail "${bundle_path} has an invalid JAR signature"

  fingerprint_from_bundle="$({ keytool -printcert -jarfile "$bundle_path"; } |
    sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':')"
  [[ -n "$fingerprint_from_bundle" ]] || fail "could not read the signer for ${bundle_path}"
  [[ "$fingerprint_from_bundle" == "$fingerprint_from_keystore" ]] ||
    fail "${bundle_path} is not signed by alias ${ANDROID_KEY_ALIAS}"

  printf 'Verified %s (signer SHA-256 %s).\n' "$bundle_path" "$fingerprint_from_bundle"
done
