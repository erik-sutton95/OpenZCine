#!/usr/bin/env bash
# Cross-compiles the portable Swift camera core for the one ABI OpenZCine ships
# today, then stages its complete dynamic-library closure for Android Gradle.
#
# This is deliberately a build input, not a source-tree artifact: Gradle passes
# a directory under app/build/generated/, so a clean checkout cannot
# accidentally package an ignored, stale src/main/jniLibs/ directory.
set -euo pipefail

readonly SWIFT_VERSION="6.3.3"
readonly DEFAULT_SWIFT_SDK="swift-6.3.3-RELEASE_android"
readonly DEFAULT_TARGET="aarch64-unknown-linux-android29"
readonly PRODUCT="OpenZCineAndroid"

usage() {
    cat <<'EOF'
Usage: android-stage-swift-core.sh --output <jniLibs-directory>

Environment overrides:
  SWIFT_EXECUTABLE       Path to the matching Swift 6.3.3 binary.
  SWIFT_ANDROID_SDK_ID   Installed Swift SDK ID (default: swift-6.3.3-RELEASE_android).
  SWIFT_ANDROID_TARGET   Swift target triple (default: aarch64-unknown-linux-android29).

The target is intentionally arm64-only: Android ABI name arm64-v8a.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || fail "--output needs a directory"
            output="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$output" ]] || {
    usage >&2
    fail "--output is required"
}

if [[ -n "${SWIFT_EXECUTABLE:-}" ]]; then
    swift="$SWIFT_EXECUTABLE"
elif [[ -x "${SWIFT_INSTALLATION:-}/bin/swift" ]]; then
    # skiptools/swift-android-action exports the installed host toolchain through
    # GITHUB_ENV as SWIFT_INSTALLATION. Prefer it to the runner's system Swift:
    # the Android SDK must be driven by its exact matching host toolchain.
    swift="$SWIFT_INSTALLATION/bin/swift"
elif [[ -x "$HOME/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain/usr/bin/swift" ]]; then
    # Swiftly puts the requested macOS release toolchain here.
    swift="$HOME/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain/usr/bin/swift"
else
    swift="$(command -v swift || true)"
fi

[[ -n "$swift" && -x "$swift" ]] || fail \
    "Swift ${SWIFT_VERSION} was not found; set SWIFT_EXECUTABLE to that toolchain's swift binary"

swift_version="$($swift --version)"
[[ "$swift_version" == *"${SWIFT_VERSION}"* ]] || fail \
    "Swift ${SWIFT_VERSION} is required by the Android SDK; found: ${swift_version%%$'\n'*}"

toolchain_bin="$(cd "$(dirname "$swift")" && pwd -P)"
objcopy="$toolchain_bin/llvm-objcopy"
objdump="$toolchain_bin/llvm-objdump"
[[ -x "$objcopy" ]] || fail "llvm-objcopy is missing beside $swift"
[[ -x "$objdump" ]] || fail "llvm-objdump is missing beside $swift"

sdk_id="${SWIFT_ANDROID_SDK_ID:-$DEFAULT_SWIFT_SDK}"
target="${SWIFT_ANDROID_TARGET:-$DEFAULT_TARGET}"
case "$target" in
    aarch64-unknown-linux-android*) ;;
    *) fail "OpenZCine currently ships only arm64-v8a; refusing target $target" ;;
esac

sdk_configuration="$($swift sdk configure --show-configuration "$sdk_id" "$target")" || fail \
    "Swift Android SDK $sdk_id is not configured for $target"
sdk_root="$(printf '%s\n' "$sdk_configuration" | awk -F': ' '/^sdkRootPath:/{print $2; exit}')"
swift_resources="$(printf '%s\n' "$sdk_configuration" | awk -F': ' '/^swiftResourcesPath:/{print $2; exit}')"
[[ -d "$sdk_root" ]] || fail "Swift SDK root is missing: $sdk_root"
[[ -d "$swift_resources/android" ]] || fail "Swift runtime is missing: $swift_resources/android"

runtime="$swift_resources/android"
ndk_libraries="$sdk_root/usr/lib/aarch64-linux-android"
[[ -d "$ndk_libraries" ]] || fail "Android NDK libraries are missing: $ndk_libraries"

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

"$swift" build --swift-sdk "$target" -c release --product "$PRODUCT"
build_directory="$($swift build --swift-sdk "$target" -c release --show-bin-path)"
product="$build_directory/lib${PRODUCT}.so"
[[ -f "$product" ]] || fail "Swift product was not built: $product"

output="$(mkdir -p "$output" && cd "$output" && pwd -P)"
temporary_output="${output}.staging.$$"
rm -rf "$temporary_output"
mkdir -p "$temporary_output"
trap 'rm -rf "$temporary_output"' EXIT

"$objcopy" --strip-all "$product" "$temporary_output/lib${PRODUCT}.so"

# Copy the dynamic-library closure. Dependencies not present in the Swift
# runtime or NDK sysroot must be bionic system libraries; keep the allowlist
# narrow so a new Swift runtime dependency cannot silently ship broken.
is_android_system_library() {
    case "$1" in
        libc.so|libdl.so|liblog.so|libm.so|libz.so) return 0 ;;
        *) return 1 ;;
    esac
}

changed=1
while [[ "$changed" == 1 ]]; do
    changed=0
    for library in "$temporary_output"/*.so; do
        [[ -f "$library" ]] || continue
        while IFS= read -r dependency; do
            [[ -n "$dependency" ]] || continue
            [[ -f "$temporary_output/$dependency" ]] && continue
            if [[ -f "$runtime/$dependency" ]]; then
                cp "$runtime/$dependency" "$temporary_output/$dependency"
                changed=1
            elif [[ -f "$ndk_libraries/$dependency" ]]; then
                cp "$ndk_libraries/$dependency" "$temporary_output/$dependency"
                changed=1
            elif ! is_android_system_library "$dependency"; then
                fail "unresolved non-system dependency $dependency required by $(basename "$library")"
            fi
        done < <("$objdump" -p "$library" | awk '/NEEDED/{print $2}')
    done
done

[[ -s "$temporary_output/lib${PRODUCT}.so" ]] || fail "staged core library is missing"

# Build a stable manifest used by the final APK/AAB verifier. It intentionally
# records every .so in the closure rather than a hand-maintained subset.
find "$temporary_output" -maxdepth 1 -type f -name '*.so' -exec basename {} \; | LC_ALL=C sort \
    > "$temporary_output/native-libraries.txt"
[[ -s "$temporary_output/native-libraries.txt" ]] || fail "Swift runtime closure is empty"

rm -rf "$output"
mv "$temporary_output" "$output"
trap - EXIT

printf 'Staged %s native libraries for arm64-v8a → %s\n' \
    "$(wc -l < "$output/native-libraries.txt" | tr -d ' ')" "$output"
