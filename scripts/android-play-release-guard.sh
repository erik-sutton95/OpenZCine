#!/usr/bin/env bash
# Reject ambiguous or off-main Play releases before signing starts.
set -euo pipefail

version_file="Apps/Android/gradle.properties"
version_name="$(sed -n 's/^openzcine\.versionName=//p' "$version_file")"

fail() {
  printf 'Play release guard failed: %s\n' "$1" >&2
  exit 1
}

[[ -n "$version_name" ]] || fail "missing openzcine.versionName in ${version_file}"

case "${EVENT_NAME:-}" in
  workflow_dispatch)
    [[ "${REF_NAME:-}" == "main" ]] || fail "manual releases must run from main, not ${REF_NAME:-an unknown ref}"
    ;;
  push)
    expected_tag="android-v${version_name}"
    [[ "${REF_NAME:-}" == "$expected_tag" ]] || fail "tag must be ${expected_tag}, not ${REF_NAME:-an unknown ref}"
    git merge-base --is-ancestor HEAD origin/main || fail "release tag commit is not on main"
    ;;
  *)
    fail "unsupported event ${EVENT_NAME:-unknown}"
    ;;
esac

printf 'Play release ref accepted: %s (version %s).\n' "${REF_NAME:-}" "$version_name"
