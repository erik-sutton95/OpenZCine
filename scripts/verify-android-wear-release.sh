#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --phone-apk-dir DIR --wear-apk-dir DIR --wear-aab-dir DIR --phone-version-code N --wear-version-code N" >&2
  exit 2
}

phone_apk_dir=""
wear_apk_dir=""
wear_aab_dir=""
expected_phone_code=""
expected_wear_code=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phone-apk-dir) phone_apk_dir="$2"; shift 2 ;;
    --wear-apk-dir) wear_apk_dir="$2"; shift 2 ;;
    --wear-aab-dir) wear_aab_dir="$2"; shift 2 ;;
    --phone-version-code) expected_phone_code="$2"; shift 2 ;;
    --wear-version-code) expected_wear_code="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$phone_apk_dir" && -n "$wear_apk_dir" && -n "$wear_aab_dir" ]] || usage
[[ -n "$expected_phone_code" && -n "$expected_wear_code" ]] || usage

sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
aapt2="$(find "$sdk_root/build-tools" -type f -name aapt2 -perm -111 | sort -V | tail -1)"
apksigner="$(find "$sdk_root/build-tools" -type f -name apksigner -perm -111 | sort -V | tail -1)"
[[ -x "$aapt2" ]] || { echo "aapt2 not found below $sdk_root/build-tools" >&2; exit 1; }
[[ -x "$apksigner" ]] || { echo "apksigner not found below $sdk_root/build-tools" >&2; exit 1; }

select_apk() {
  local directory="$1"
  local expected_code="$2"
  local candidate
  while IFS= read -r candidate; do
    local badging
    badging="$($aapt2 dump badging "$candidate")"
    if [[ "$badging" == *"versionCode='$expected_code'"* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$directory" -maxdepth 1 -type f -name '*release*.apk' | sort)
  echo "No release APK with versionCode $expected_code found in $directory" >&2
  return 1
}

phone_apk="$(select_apk "$phone_apk_dir" "$expected_phone_code")"
wear_apk="$(select_apk "$wear_apk_dir" "$expected_wear_code")"
wear_aab="$(find "$wear_aab_dir" -maxdepth 1 -type f -name '*.aab' | sort | head -1)"
[[ -f "$wear_aab" ]] || { echo "Wear release AAB not found in $wear_aab_dir" >&2; exit 1; }

package_name() {
  "$aapt2" dump badging "$1" | sed -n "s/^package: name='\([^']*\)'.*/\1/p"
}

phone_package="$(package_name "$phone_apk")"
wear_package="$(package_name "$wear_apk")"
[[ -n "$phone_package" && "$phone_package" == "$wear_package" ]] || {
  echo "Phone/Wear package mismatch: '$phone_package' vs '$wear_package'" >&2
  exit 1
}
[[ "$expected_phone_code" != "$expected_wear_code" ]] || {
  echo "Phone and Wear version codes must be unique" >&2
  exit 1
}

wear_badging="$($aapt2 dump badging "$wear_apk")"
grep -Fq "uses-feature: name='android.hardware.type.watch'" <<<"$wear_badging" || {
  echo "Wear release APK lost android.hardware.type.watch" >&2
  exit 1
}

wear_manifest="$($aapt2 dump xmltree --file AndroidManifest.xml "$wear_apk")"
grep -Fq 'com.google.android.wearable.standalone' <<<"$wear_manifest" || {
  echo "Wear release APK lost the standalone metadata" >&2
  exit 1
}
grep -Eq 'TYPE_INT_BOOLEAN.*0x0|value.*false' <<<"$wear_manifest" || {
  echo "Wear release APK is not explicitly non-standalone" >&2
  exit 1
}

wear_resources="$($aapt2 dump resources "$wear_apk")"
grep -Fq 'android_wear_capabilities' <<<"$wear_resources" || {
  echo "Wear capability resource was removed from the release APK" >&2
  exit 1
}
grep -Fq 'openzcine_wear_relay_v1' <<<"$wear_resources" || {
  echo "Wear capability value was removed from the release APK" >&2
  exit 1
}
phone_resources="$($aapt2 dump resources "$phone_apk")"
grep -Fq 'android_wear_capabilities' <<<"$phone_resources" || {
  echo "Phone capability resource was removed from the release APK" >&2
  exit 1
}
grep -Fq 'openzcine_phone_relay_v1' <<<"$phone_resources" || {
  echo "Phone capability value was removed from the release APK" >&2
  exit 1
}

wear_permissions="$($aapt2 dump permissions "$wear_apk")"
for permission in \
  android.permission.CAMERA \
  android.permission.RECORD_AUDIO \
  android.permission.INTERNET \
  android.permission.BLUETOOTH \
  android.permission.BLUETOOTH_CONNECT \
  android.permission.BLUETOOTH_SCAN \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.READ_EXTERNAL_STORAGE \
  android.permission.WRITE_EXTERNAL_STORAGE \
  android.permission.MANAGE_EXTERNAL_STORAGE; do
  if grep -Fq "$permission" <<<"$wear_permissions"; then
    echo "Wear release APK unexpectedly declares $permission" >&2
    exit 1
  fi
done

wear_aab_entries="$(unzip -Z1 "$wear_aab")"
grep -Fxq 'base/manifest/AndroidManifest.xml' <<<"$wear_aab_entries" || {
  echo "Wear AAB has no base manifest" >&2
  exit 1
}
grep -Fxq 'BundleConfig.pb' <<<"$wear_aab_entries" || {
  echo "Wear AAB has no BundleConfig.pb" >&2
  exit 1
}

signer_digest() {
  "$apksigner" verify --print-certs "$1" 2>/dev/null |
    sed -n 's/^Signer #1 certificate SHA-256 digest: //p'
}

phone_digest="$(signer_digest "$phone_apk" || true)"
wear_digest="$(signer_digest "$wear_apk" || true)"
if [[ -n "$phone_digest" || -n "$wear_digest" ]]; then
  [[ -n "$phone_digest" && "$phone_digest" == "$wear_digest" ]] || {
    echo "Phone/Wear signing certificate mismatch" >&2
    exit 1
  }
fi

echo "Verified Wear release pair:"
echo "  package: $phone_package"
echo "  phone versionCode: $expected_phone_code"
echo "  Wear versionCode: $expected_wear_code"
echo "  signer: ${phone_digest:-unsigned local structure build}"
