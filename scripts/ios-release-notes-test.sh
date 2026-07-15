#!/usr/bin/env bash
# Regression tests for the TestFlight notes contract.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="${script_dir}/ios-release-notes-check.sh"
printer="${script_dir}/ios-release-notes.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

expect_pass() {
  local fixture="$1"
  "$validator" "$fixture" >/dev/null
}

expect_fail() {
  local fixture="$1"
  if "$validator" "$fixture" >/dev/null 2>&1; then
    printf 'Expected TestFlight notes validation to fail: %s\n' "$fixture" >&2
    exit 1
  fi
}

cat > "${temp_dir}/valid.txt" <<'EOF'
What's changed

- Find and pair no longer gets stuck while looking for cameras through Personal Hotspot.

Please test

- Connect your Nikon camera to your iPhone's Personal Hotspot, then open Find and pair.
- Confirm the camera appears and completes pairing.
EOF
expect_pass "${temp_dir}/valid.txt"

printed_notes="$("$printer" "${temp_dir}/valid.txt" 2>/dev/null)"
if [[ "$printed_notes" == *"check passed"* || "$printed_notes" != *"Find and pair"* ]]; then
  printf 'Release-notes printer emitted validation output or lost the reviewed copy.\n' >&2
  exit 1
fi

cat > "${temp_dir}/jargon.txt" <<'EOF'
What's changed

- Repaired hotspot pairing after GUID migration.

Please test

- Try pairing a camera.
EOF
expect_fail "${temp_dir}/jargon.txt"

cat > "${temp_dir}/wrong-platform.txt" <<'EOF'
What's changed

- Added a new Android monitor layout.

Please test

- Open the monitor.
EOF
expect_fail "${temp_dir}/wrong-platform.txt"

cat > "${temp_dir}/commit-title.txt" <<'EOF'
What's changed

- feat(ios): add a better monitor shell

Please test

- Open the monitor.
EOF
expect_fail "${temp_dir}/commit-title.txt"

cat > "${temp_dir}/too-many.txt" <<'EOF'
What's changed

- First visible change.
- Second visible change.
- Third visible change.
- Fourth visible change.
- Fifth visible change.
- Sixth visible change.

Please test

- Try the updated behavior.
EOF
expect_fail "${temp_dir}/too-many.txt"

cat > "${temp_dir}/missing-action.txt" <<'EOF'
What's changed

- Pairing is more reliable through Personal Hotspot.

Please test
EOF
expect_fail "${temp_dir}/missing-action.txt"

printf 'TestFlight notes regression tests passed.\n'
