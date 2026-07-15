#!/usr/bin/env bash
# Validate that TestFlight notes are concise, actionable, and safe for non-developer testers.
set -euo pipefail

notes_path="${1:-ios/TestFlight/WhatToTest.en-US.txt}"
max_characters=4000

fail() {
  printf 'TestFlight notes check failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$notes_path" ]] || fail "missing ${notes_path}"

character_count="$(wc -m < "$notes_path" | tr -d '[:space:]')"
if ((character_count > max_characters)); then
  fail "${notes_path} is ${character_count} characters; App Store Connect allows ${max_characters}"
fi

if ! awk '
  BEGIN {
    section = 0
    changed_headings = 0
    test_headings = 0
    changed_bullets = 0
    test_bullets = 0
    invalid = 0
  }
  $0 == "What\047s changed" {
    changed_headings++
    if (section != 0) invalid = 1
    section = 1
    next
  }
  $0 == "Please test" {
    test_headings++
    if (section != 1) invalid = 1
    section = 2
    next
  }
  /^[[:space:]]*$/ { next }
  /^- .+/ {
    if (section == 1) changed_bullets++
    else if (section == 2) test_bullets++
    else invalid = 1
    next
  }
  { invalid = 1 }
  END {
    if (changed_headings != 1 || test_headings != 1 || invalid) exit 1
    if (changed_bullets < 1 || changed_bullets > 5) exit 1
    if (test_bullets < 1 || test_bullets > 4) exit 1
  }
' "$notes_path"; then
  fail "use exactly 'What's changed' and 'Please test', with 1-5 change bullets and 1-4 test bullets"
fi

if grep -Eiq '^- (feat|fix|perf|refactor|chore|build|test|style)(\([^)]+\))?!?:' "$notes_path"; then
  fail "contains a Conventional Commit title instead of tester-facing copy"
fi

if grep -Eiq '(^|[^[:alnum:]])(android|website|landing page|guid|ptp-ip|jni|nsd|api|ci|workflow|swiftui|kotlin|facade|scaffold|socket lifecycle|render spike|migration|pbxproj|xcodebuild)([^[:alnum:]]|$)' "$notes_path"; then
  fail "contains implementation jargon; describe the visible behavior instead"
fi

if grep -Eq '#[0-9]+|(^|[[:space:](])[0-9a-f]{7,40}([[:space:])]|$)|\.(swift|kt|kts|sh|yml|yaml)([^[:alpha:]]|$)' "$notes_path"; then
  fail "contains an issue, commit, or source-file reference"
fi

printf 'TestFlight notes check passed (%s characters).\n' "$character_count"
