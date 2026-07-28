#!/usr/bin/env bash
# Validates native-library packaging by inspecting archive entries only. It
# never extracts an APK/AAB, so it is safe to run on CI artifacts.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: verify-android-native-libs.sh --staged-dir <directory> --apk-dir <directory> --aab-dir <directory>

The staged directory must be the Gradle-generated arm64-v8a directory created
by android-stage-swift-core.sh. Every staged .so must appear in both artifacts.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

staged_dir=""
apk_directory=""
aab_directory=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged-dir)
            staged_dir="$2"
            shift 2
            ;;
        --apk-dir)
            apk_directory="$2"
            shift 2
            ;;
        --aab-dir)
            aab_directory="$2"
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

[[ -d "$staged_dir" ]] || fail "staged directory is missing: $staged_dir"
[[ -d "$apk_directory" ]] || fail "APK directory is missing: $apk_directory"
[[ -d "$aab_directory" ]] || fail "AAB directory is missing: $aab_directory"
command -v unzip >/dev/null || fail "unzip is required to inspect package contents"

apk_candidates=()
while IFS= read -r candidate; do
    apk_candidates+=("$candidate")
done < <(find "$apk_directory" -maxdepth 1 -type f -name '*.apk' -print)
[[ ${#apk_candidates[@]} -eq 1 ]] || fail \
    "expected one release APK in $apk_directory, found ${#apk_candidates[@]}"
apk="${apk_candidates[0]}"

aab_candidates=()
while IFS= read -r candidate; do
    aab_candidates+=("$candidate")
done < <(find "$aab_directory" -maxdepth 1 -type f -name '*.aab' -print)
[[ ${#aab_candidates[@]} -eq 1 ]] || fail \
    "expected one release AAB in $aab_directory, found ${#aab_candidates[@]}"
aab="${aab_candidates[0]}"

expected="$(mktemp)"
apk_entries="$(mktemp)"
aab_entries="$(mktemp)"
trap 'rm -f "$expected" "$apk_entries" "$aab_entries"' EXIT

find "$staged_dir" -maxdepth 1 -type f -name '*.so' -exec basename {} \; | LC_ALL=C sort > "$expected"
[[ -s "$expected" ]] || fail "no staged native libraries found in $staged_dir"
grep -Fxq 'libOpenZCineAndroid.so' "$expected" || fail "staged core library is missing"

unzip -Z1 "$apk" > "$apk_entries"
unzip -Z1 "$aab" > "$aab_entries"

verify_archive() {
    local archive_kind="$1"
    local entries="$2"
    local prefix="$3"
    local library

    while IFS= read -r library; do
        grep -Fxq "${prefix}${library}" "$entries" || fail \
            "$archive_kind is missing required arm64-v8a library: $library"
    done < "$expected"

    # A release bundle must remain explicitly arm64-only until another ABI is
    # built and hardware-verified. This protects against a stale secondary
    # jniLibs directory quietly expanding the Play artifact.
    if grep -E '^((base/)?lib/)' "$entries" | grep -Ev "^${prefix//\//\\/}" >/dev/null; then
        fail "$archive_kind contains a native library outside arm64-v8a"
    fi

    printf 'Verified %s required arm64-v8a libraries in %s\n' \
        "$(wc -l < "$expected" | tr -d ' ')" "$archive_kind"
}

verify_archive "APK" "$apk_entries" "lib/arm64-v8a/"
verify_archive "AAB" "$aab_entries" "base/lib/arm64-v8a/"

# ── Bundled on-device OCR (issue #267) ──────────────────────────────────────
# The camera-AP scanner uses the *bundled* ML Kit Latin recognizer, so its model
# assets and native pipeline must be inside the shrunk release artifact and its
# initialization provider must survive manifest merging. Without all three the
# scanner reports "text recognition is not ready" on a device that is otherwise
# perfectly capable, and pairing loses its OCR path.
verify_mlkit() {
    local archive_kind="$1"
    local entries="$2"
    local library_prefix="$3"
    local asset_prefix="$4"

    grep -Fxq "${library_prefix}libmlkit_google_ocr_pipeline.so" "$entries" || fail \
        "$archive_kind is missing the bundled ML Kit OCR native pipeline"
    # The Latin recognizer's own model, not just the shared graph definitions.
    grep -q "^${asset_prefix}mlkit-google-ocr-models/gocr/gocr_models/line_recognition.*Latn" \
        "$entries" || fail "$archive_kind is missing the bundled Latin OCR model assets"
}

verify_mlkit "APK" "$apk_entries" "lib/arm64-v8a/" "assets/"
verify_mlkit "AAB" "$aab_entries" "base/lib/arm64-v8a/" "base/assets/"

# The provider is what calls MlKitContext.initializeIfNeeded before any
# getClient(). Its authority string lives in the APK's binary manifest string
# pool, so this needs no aapt2 and works on a CI artifact.
apk_manifest_strings="$(mktemp)"
trap 'rm -f "$expected" "$apk_entries" "$aab_entries" "$apk_manifest_strings"' EXIT
unzip -p "$apk" AndroidManifest.xml | LC_ALL=C tr -cd '\11\12\15\40-\176' > "$apk_manifest_strings"
grep -q 'MlKitInitProvider' "$apk_manifest_strings" || fail \
    "release manifest lost com.google.mlkit.common.internal.MlKitInitProvider"

printf 'Verified bundled ML Kit Latin OCR model, native pipeline, and init provider\n'
