#!/usr/bin/env bash
# Runs the existing debug-only SwiftCoreSmoke JNI round trip on one connected
# arm64 Android device. This is intentionally a device check: GitHub's hosted
# x86 runners cannot load the production arm64-v8a library.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: android-bridge-smoke.sh [--serial <adb-serial>] [--apk <debug-apk>]

Installs the supplied debug APK with adb -r (preserving app data), launches
OpenZCine, and requires the SwiftCoreSmoke core-version line in logcat.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

serial=""
apk=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --serial)
            [[ $# -ge 2 ]] || fail "--serial needs a device serial"
            serial="$2"
            shift 2
            ;;
        --apk)
            [[ $# -ge 2 ]] || fail "--apk needs a path"
            apk="$2"
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

command -v adb >/dev/null || fail "adb is required"
if [[ -z "$serial" ]]; then
    devices="$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')"
    device_count="$(printf '%s\n' "$devices" | awk 'NF {count += 1} END {print count + 0}')"
    [[ "$device_count" == 1 ]] || fail \
        "expected exactly one connected adb device; pass --serial when more than one is present"
    serial="$devices"
fi

adb_args=(-s "$serial")
if [[ -z "$apk" ]]; then
    repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
    apk="$repo_root/Apps/Android/app/build/outputs/apk/debug/app-debug.apk"
fi
[[ -f "$apk" ]] || fail "debug APK is missing: $apk (run just android-build first)"

adb "${adb_args[@]}" logcat -c
adb "${adb_args[@]}" install -r "$apk" >/dev/null
adb "${adb_args[@]}" shell am force-stop com.opencapture.openzcine
adb "${adb_args[@]}" shell am start -n com.opencapture.openzcine/.MainActivity >/dev/null

for _ in $(seq 1 20); do
    smoke_log="$(adb "${adb_args[@]}" logcat -d -s SwiftCoreSmoke:I '*:S')"
    if printf '%s\n' "$smoke_log" | grep -Fq 'core: OpenZCineCore swift-android/arm64'; then
        printf '%s\n' "$smoke_log"
        printf 'Verified Swift JNI bridge load on %s\n' "$serial"
        exit 0
    fi
    if printf '%s\n' "$smoke_log" | grep -Fq 'libOpenZCineAndroid.so not bundled'; then
        fail "APK launched without the Swift core library"
    fi
    sleep 1
done

fail "SwiftCoreSmoke did not report a loaded arm64 core within 20 seconds"
