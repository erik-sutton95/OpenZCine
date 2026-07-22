#!/usr/bin/env bash
# Validate concise, reviewed Google Play release notes.
set -euo pipefail

notes_path="${1:-Apps/Android/distribution/whatsnew/whatsnew-en-US}"
max_characters=500

fail() {
  printf 'Play release notes check failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$notes_path" ]] || fail "missing ${notes_path}"

character_count="$(wc -m < "$notes_path" | tr -d '[:space:]')"
((character_count > 0)) || fail "${notes_path} is empty"
((character_count <= max_characters)) ||
  fail "${notes_path} is ${character_count} characters; Google Play allows ${max_characters}"

if ! awk '
  BEGIN { bullets = 0; invalid = 0 }
  /^[[:space:]]*$/ { next }
  /^- .+/ { bullets++; next }
  { invalid = 1 }
  END { if (invalid || bullets < 1 || bullets > 5) exit 1 }
' "$notes_path"; then
  fail "use 1-5 plain-text bullet points"
fi

if grep -Eiq '^- (feat|fix|perf|refactor|chore|build|test|style)(\([^)]+\))?!?:' "$notes_path"; then
  fail "contains a Conventional Commit title instead of tester-facing copy"
fi

if grep -Eq '#[0-9]+|(^|[[:space:](])[0-9a-f]{7,40}([[:space:])]|$)|\.(swift|kt|kts|sh|yml|yaml)([^[:alpha:]]|$)' "$notes_path"; then
  fail "contains an issue, commit, or source-file reference"
fi

printf 'Play release notes check passed (%s characters).\n' "$character_count"
