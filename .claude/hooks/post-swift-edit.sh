#!/usr/bin/env bash
# PostToolUse hook — formats edited Swift files via the project formatter.
set -euo pipefail

input=$(cat)
file_path=$(printf '%s' "$input" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)

case "$file_path" in
  *.swift) ;;
  *) exit 0 ;;
esac

[ -f "$file_path" ] || exit 0
swift format --in-place "$file_path" 2>/dev/null \
  && echo "swift-format: formatted $file_path" \
  || echo "swift-format: skipped $file_path (formatter unavailable)"

# SwiftUI view files: emit a mandatory screenshot-verify reminder. The app is landscape-locked and
# ~400pt tall, so layout changes clip/overlap easily and MUST be visually checked before "done"
# (per CLAUDE.md). This fires deterministically so it doesn't depend on the agent remembering.
case "$file_path" in
  */ios/Runner/*.swift)
    if grep -q "import SwiftUI" "$file_path" 2>/dev/null; then
      echo "⚠️  UI-VERIFY REQUIRED — you edited a SwiftUI file ($(basename "$file_path"))."
      echo "    Before claiming this UI change done, you MUST:"
      echo "    1. Build to a DEDICATED -derivedDataPath (shared default DD may contain a stale binary)."
      echo "    2. Confirm the installed .app/Runner mtime is within ~1 min of now."
      echo "    3. Install + launch on the sim, screenshot, rotate 'sips -r -90' (landscape)."
      echo "    4. READ the image; check ALL FOUR EDGES for clipping / cutoff / overlap / truncation."
      echo "    5. Fix and re-screenshot until clean. No 'done'/'matches mockup' without this pass."
    fi
    ;;
esac
exit 0
