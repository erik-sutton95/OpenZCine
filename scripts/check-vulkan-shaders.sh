#!/usr/bin/env bash
# Guards the checked-in Vulkan SPIR-V against its GLSL source.
#
# The .spv files under app/src/main/assets/shaders/vulkan/ are committed artefacts and NOTHING
# in the Gradle build recompiles them. Editing feed.frag alone therefore ships the OLD shader on
# the preferred live-feed backend, silently and with a green build. This check fails instead.
#
# Regenerate with: just android-shaders
set -euo pipefail

cd "$(dirname "$0")/.."

SRC_DIR="Apps/Android/app/src/main/cpp/live_feed_vk/shaders"
OUT_DIR="Apps/Android/app/src/main/assets/shaders/vulkan"

if ! command -v glslc >/dev/null 2>&1; then
    echo "check-vulkan-shaders: glslc not found; skipping (install shaderc, or run in CI)" >&2
    exit 0
fi

status=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for src in "$SRC_DIR"/*.vert "$SRC_DIR"/*.frag; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    stage="${name##*.}"
    expected="$OUT_DIR/$name.spv"

    if [ ! -f "$expected" ]; then
        echo "check-vulkan-shaders: missing compiled artefact $expected" >&2
        status=1
        continue
    fi

    glslc -fshader-stage="$stage" "$src" -o "$tmp/$name.spv"
    if ! cmp -s "$tmp/$name.spv" "$expected"; then
        echo "check-vulkan-shaders: $expected is stale relative to $src" >&2
        echo "  the live-feed backend would run the OLD shader — run: just android-shaders" >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "check-vulkan-shaders: compiled SPIR-V matches its GLSL source"
fi
exit "$status"
