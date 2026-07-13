#!/usr/bin/env bash
# PreToolUse hook — blocks edits to proprietary trees and secret files.
# Repo hard rule (AGENTS.md): never edit/commit vendor/ or ref/.
set -euo pipefail

input=$(cat)
file_path=$(printf '%s' "$input" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)

[ -z "$file_path" ] && exit 0

case "$file_path" in
  */vendor/*|vendor/*|*/ref/*|ref/*)
    echo "BLOCKED: $file_path is under a proprietary tree (vendor/ or ref/). Never edit these." >&2
    exit 2 ;;
  *.env|*.env.*|*.secret|*secrets.*|*/Secrets.swift|*/GoogleService-Info.plist|*/.git/*|*/Podfile.lock)
    echo "BLOCKED: $file_path is a protected secret/config file." >&2
    exit 2 ;;
esac
exit 0
