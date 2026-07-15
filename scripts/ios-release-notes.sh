#!/usr/bin/env bash
# Print the reviewed TestFlight "What to Test" copy.
set -euo pipefail

notes_path="${1:-ios/TestFlight/WhatToTest.en-US.txt}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${script_dir}/ios-release-notes-check.sh" "$notes_path" >&2
cat "$notes_path"
