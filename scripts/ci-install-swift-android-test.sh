#!/usr/bin/env bash
# Regression tests for how scripts/ci-install-swift-android.sh recovers from a failed
# `swift sdk install`, against a stand-in swift that follows a script of install outcomes.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

mkdir "$temp_dir/bin"
cat > "$temp_dir/bin/swift" <<'EOF'
#!/usr/bin/env bash
# INSTALLS lists one outcome per `sdk install` call:
#   ok        installs the whole bundle
#   crash-ok  installs the whole bundle, then crashes
#   listed    leaves a bundle SwiftPM lists (info.json) without its files, then crashes
#   dir       leaves an empty bundle directory, then crashes
bundle="$HOME/.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle"
case "$1 ${2:-}" in
  "--version "*) echo "Swift version 6.3.3 (swift-6.3.3-RELEASE)" ;;
  "sdk list") [ ! -f "$bundle/info.json" ] || echo "swift-6.3.3-RELEASE_android" ;;
  "sdk configure") ;;
  "sdk install")
    echo install >> "$CALLS"
    if [ -e "$bundle" ]; then
      echo "error: $bundle already exists" >&2
      exit 1
    fi
    count="$(grep -c install "$CALLS")"
    outcome="$(echo "$INSTALLS" | cut -d, -f"$count")"
    mkdir -p "$bundle"
    case "$outcome" in
      ok | crash-ok)
        touch "$bundle/info.json"
        mkdir -p "$bundle/swift-android/scripts"
        printf '#!/bin/sh\n' > "$bundle/swift-android/scripts/setup-android-sdk.sh"
        chmod +x "$bundle/swift-android/scripts/setup-android-sdk.sh"
        [ "$outcome" = ok ] || exit 139
        ;;
      listed) touch "$bundle/info.json"; exit 139 ;;
      *) exit 139 ;;
    esac
    ;;
  *) echo "unexpected swift call: $*" >&2; exit 2 ;;
esac
EOF
printf '#!/bin/sh\n' > "$temp_dir/bin/llvm-objcopy"
printf '#!/bin/sh\n' > "$temp_dir/bin/llvm-objdump"
chmod +x "$temp_dir/bin/"*
export PATH="$temp_dir/bin:$PATH" CALLS="$temp_dir/calls" ANDROID_NDK_HOME="$temp_dir/ndk"
unset GITHUB_ENV GITHUB_PATH XDG_CONFIG_HOME

# expect <pass|fail> <install calls> <outcomes>
expect() {
  local verdict=0
  rm -rf "${temp_dir:?}/home" "$CALLS"
  mkdir "$temp_dir/home"
  touch "$CALLS"
  HOME="$temp_dir/home" INSTALLS="$3" "$script_dir/ci-install-swift-android.sh" \
    > "$temp_dir/out" 2>&1 || verdict=1
  local calls
  calls="$(grep -c install "$CALLS" || true)"
  if [ "$verdict" != "$([ "$1" = pass ] && echo 0 || echo 1)" ] || [ "$calls" != "$2" ]; then
    printf 'Outcomes %s: expected %s after %s installs, got exit %s after %s\n' \
      "$3" "$1" "$2" "$verdict" "$calls" >&2
    cat "$temp_dir/out" >&2
    exit 1
  fi
}

expect pass 1 ok
# A crash after a complete install needs no second install.
expect pass 1 crash-ok
# A listed bundle without its files is removed and installed again.
expect pass 2 listed,ok
# So is a bare directory, which would otherwise make the reinstall fail.
expect pass 2 dir,ok
# A second failure fails the step.
expect fail 2 dir,dir
expect fail 2 listed,listed

echo "ci-install-swift-android.sh tests passed."
