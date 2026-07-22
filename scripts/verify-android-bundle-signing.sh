#!/usr/bin/env bash
# Require both Play bundles to be signed by the configured upload-key alias.
set -euo pipefail

fail() {
  printf 'Android bundle signing check failed: %s\n' "$1" >&2
  exit 1
}

resolve_java_tool() {
  local tool_name="$1"
  local java_home

  for java_home in "${JAVA_HOME:-}" /opt/homebrew/opt/openjdk /usr/local/opt/openjdk; do
    if [[ -n "$java_home" && -x "$java_home/bin/$tool_name" ]]; then
      printf '%s\n' "$java_home/bin/$tool_name"
      return
    fi
  done

  command -v "$tool_name" || fail "could not locate ${tool_name}; set JAVA_HOME to a JDK"
}

[[ $# -ge 1 ]] || fail "pass at least one .aab path"
: "${ANDROID_KEYSTORE_PATH:?ANDROID_KEYSTORE_PATH is required}"
: "${ANDROID_KEYSTORE_PASSWORD:?ANDROID_KEYSTORE_PASSWORD is required}"
: "${ANDROID_KEY_ALIAS:?ANDROID_KEY_ALIAS is required}"

keytool_path="$(resolve_java_tool keytool)"
jarsigner_path="$(resolve_java_tool jarsigner)"

fingerprint_from_keystore="$({
  "$keytool_path" -list -v \
    -keystore "$ANDROID_KEYSTORE_PATH" \
    -storepass "$ANDROID_KEYSTORE_PASSWORD" \
    -alias "$ANDROID_KEY_ALIAS"
} | sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':')"

[[ -n "$fingerprint_from_keystore" ]] || fail "could not read the upload-key SHA-256 fingerprint"

for bundle_path in "$@"; do
  [[ -f "$bundle_path" ]] || fail "missing ${bundle_path}"
  "$jarsigner_path" -verify "$bundle_path" >/dev/null ||
    fail "${bundle_path} has an invalid JAR signature"

  fingerprint_from_bundle="$({ "$keytool_path" -printcert -jarfile "$bundle_path"; } |
    sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':')"
  [[ -n "$fingerprint_from_bundle" ]] || fail "could not read the signer for ${bundle_path}"
  [[ "$fingerprint_from_bundle" == "$fingerprint_from_keystore" ]] ||
    fail "${bundle_path} is not signed by alias ${ANDROID_KEY_ALIAS}"

  printf 'Verified %s (signer SHA-256 %s).\n' "$bundle_path" "$fingerprint_from_bundle"
done
