#!/usr/bin/env bash
# SessionStart hook — prints project context per the iOS dev guide.
set -euo pipefail

echo "== ${PROJECT_NAME:-OpenZCine} =="
# sed (not head) drains the stream so pipefail doesn't see a SIGPIPE failure;
# `|| true` keeps set -e from aborting when a tool is absent.
swift_ver=$(swift --version 2>/dev/null | sed -n '1p' || true)
xcode_ver=$(xcodebuild -version 2>/dev/null | sed -n '1p' || true)
echo "Swift:  ${swift_ver:-not found}"
echo "Xcode:  ${xcode_ver:-not found}"

if command -v swift-format >/dev/null 2>&1 || swift format --version >/dev/null 2>&1; then
  echo "swift-format: available"
else
  echo "swift-format: MISSING — run 'just setup'"
fi

booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted || true)
echo "Booted simulators: ${booted:-0}"
