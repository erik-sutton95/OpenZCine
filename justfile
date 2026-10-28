# OpenZCine task runner.
# `just` is the single entry point for repository tasks.
# Run `just` with no arguments to list available recipes.

# List all recipes
default:
    @just --list

# ── Setup ──────────────────────────────────────────────────────────────────
# Install the meta-check tools used by `just check` (macOS / Homebrew),
# and enable the repo's git hooks (pre-commit secret scan + proprietary guard).
setup:
    brew install node typos-cli editorconfig-checker lychee markdownlint-cli2 actionlint gitleaks swift-format
    git config core.hooksPath .githooks

# ── Meta checks (run today; mirrored in CI) ─────────────────────────────────
# Run every repository quality check.
check: hygiene testflight-notes-check play-notes-check ci-timing-test ios-test-script-test swift-android-install-test typos lint-md check-links check-editorconfig lint-actions secrets bug-relay-check check-demo-isolation check-vulkan-shaders check-gles-shaders swift-lint swift-test

# Reject tracked proprietary, secret-bearing, generated, or machine-specific files.
hygiene:
    ./scripts/check-repository-hygiene.sh

# Validate the reviewed TestFlight copy and its regression guardrails.
testflight-notes-check:
    ./scripts/ios-release-notes-check.sh
    ./scripts/ios-release-notes-test.sh

# Validate the reviewed Google Play tester-facing release notes.
play-notes-check:
    ./scripts/android-play-release-notes-check.sh

# Test the CI job-summary timing tables (scripts/ci-test-timing.py) on recorded output shapes.
ci-timing-test:
    python3 scripts/ci-test-timing-test.py

# Test how scripts/ios-test.sh splits options between the build and the test run.
ios-test-script-test:
    ./scripts/ios-test-test.sh

# Test how scripts/ci-install-swift-android.sh recovers from a failed Swift SDK install.
swift-android-install-test:
    ./scripts/ci-install-swift-android-test.sh

# Spell-check the repository.
typos:
    typos

# Lint all Markdown (exclusions in .markdownlint-cli2.jsonc).
lint-md:
    markdownlint-cli2 "**/*.md"

# Check that on-disk links resolve (offline; no network flakiness).
# Excludes proprietary dirs and internal planning artifacts (which embed sample docs).
check-links:
    lychee --no-progress --offline --exclude-path vendor --exclude-path ref --exclude-path docs/design .

# Verify files obey .editorconfig.
check-editorconfig:
    editorconfig-checker

# Lint GitHub Actions workflows (skips cleanly until any workflow exists).
lint-actions:
    #!/usr/bin/env bash
    if [ -d .github/workflows ]; then actionlint; else echo "No workflows yet — skipping actionlint."; fi

# Scan committed history for secrets (gitleaks; allowlist in .gitleaks.toml).
secrets:
    #!/usr/bin/env bash
    if command -v gitleaks >/dev/null 2>&1; then
        gitleaks detect --redact --no-banner --config .gitleaks.toml
    else
        echo "gitleaks not installed — run 'just setup'." >&2
        exit 1
    fi

# Validate the independently deployable, secret-free anonymous bug-report relay.
bug-relay-check:
    cd services/bug-relay && npm run check

# ── Native production stack ─────────────────────────────────────────────────
# Format shared Swift and iOS app sources.
swift-format:
    swift-format format --in-place --recursive Package.swift Sources Tests ios/Runner ios/RunnerTests ios/OpenZCineWatch

# Lint shared Swift and iOS app sources.
swift-lint:
    swift-format lint --strict --recursive Package.swift Sources Tests ios/Runner ios/RunnerTests ios/OpenZCineWatch

# Run shared Swift core tests.
swift-test:
    swift test

# Demo/screenshot env hooks (ZC_DEMO_*, ZC_METAL_FEED, ZC_GPU_SCOPES) and the shared review staging
# (OPV_UI_REVIEW_*, `ReviewLaunch`) must stay inside ios/Runner/DemoHarness.swift, whose Release
# stubs compile them out of TestFlight builds. Doc-comment mentions elsewhere are allowed; code
# reads are not.
check-demo-isolation:
    ! grep -rn 'ZC_DEMO\|ZC_METAL_FEED\|ZC_GPU_SCOPES\|OPV_UI_REVIEW_\|ReviewLaunch' Sources ios/Runner ios/OpenZCineWatch --include='*.swift' | grep -v '^ios/Runner/DemoHarness.swift:' | grep -vE ':[0-9]+: *///?' | grep .

# Run all Swift-only checks.
swift-check: swift-lint swift-test

# The shared conformance scenarios and kit suites (RunnerUIReview: RunnerUITests without the
# physical camera classes) on one simulator, made with accessibility enabled by
# ../OpenCine/scripts/ios-private-simulator.py create <name>.
conformance-ios udid result="":
    xcodebuild -project ios/Runner.xcodeproj -scheme RunnerUIReview -destination 'platform=iOS Simulator,id={{udid}}' -parallel-testing-enabled NO {{ if result != "" { "-resultBundlePath " + result } else { "" } }} test

# Build the native iOS app for the simulator.
ios-build:
    xcodebuild -project ios/Runner.xcodeproj -scheme Runner -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Build the iOS app and its unit tests once for the first available iPhone simulator
# (IOS_TEST_DEVICE_ID picks another), then run them there without rebuilding. Extra xcodebuild
# options are allowed: `just ios-test -only-testing:RunnerTests/SomeTests` builds once and runs
# one suite (scripts/ios-test.sh says which options reach which call).
ios-test *args:
    ./scripts/ios-test.sh {{args}}

# Build the watchOS companion app for the simulator.
watch-build:
    xcodebuild -project ios/Runner.xcodeproj -scheme OpenZCineWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Archive the iOS app for App Store / TestFlight distribution (requires signing).
ios-archive:
    #!/usr/bin/env bash
    set -euo pipefail
    archive_path="build/ios/OpenZCine.xcarchive"
    mkdir -p build/ios
    xcodebuild -project ios/Runner.xcodeproj \
      -scheme Runner \
      -configuration Release \
      -destination 'generic/platform=iOS' \
      -archivePath "$archive_path" \
      archive
    echo "Archive: $archive_path"

# Export an IPA from `ios-archive` output for App Store Connect upload.
ios-export: ios-archive
    #!/usr/bin/env bash
    set -euo pipefail
    archive_path="build/ios/OpenZCine.xcarchive"
    export_path="build/ios/export"
    rm -rf "$export_path"
    xcodebuild -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_path" \
      -exportOptionsPlist ios/ExportOptions.plist
    echo "IPA: $export_path/Runner.ipa"

# Print the committed iOS marketing version and build number.
ios-version:
    @sed -n 's/^MARKETING_VERSION = /Version: /p; s/^CURRENT_PROJECT_VERSION = /Build: /p' ios/Config/Version.xcconfig

# Set iOS version (example: `just ios-set-version 0.2.0 42`).
ios-set-version marketing_version build_number:
    MARKETING_VERSION="{{marketing_version}}" BUILD_NUMBER="{{build_number}}" ./scripts/ios-set-version.sh

# Archive, export, and upload to TestFlight (requires App Store Connect API key in env).
testflight:
    IOS_UPLOAD_VIA_ALTOOL=1 ./scripts/ios-testflight-upload.sh

# Offline Sentry release-tooling checks (OpenCine scripts/sentry) against this app's archive hook.
# No network, no uploads.
sentry-test:
    OPC_APP_ROOT=. OPC_APP_NAME=Runner bash ../OpenCine/scripts/sentry/sentry-test.sh

# Run all native production checks that do not require camera hardware. No `ios-build`: the
# OpenZCineWatch scheme builds the generic simulator Runner.app (arm64 and x86_64, unsigned) that
# embeds the Watch app, which is exactly what `ios-build` makes. Run with `just check native-check`
# so the recipes both gates share run once.
native-check: check-demo-isolation swift-check ios-test watch-build

# Format production Swift sources.
format: swift-format

# Lint production Swift sources.
lint: swift-lint

# Run production Swift tests.
test: swift-test

# Explain how to run the native production app without invoking prototype tooling.
run:
    #!/usr/bin/env bash
    echo "Open ios/Runner.xcodeproj in Xcode and run the Runner scheme on your iPhone."
    echo "For command-line verification, use: just ios-build or just native-check."

# Remove build artifacts.
clean:
    swift package clean

# ── Android production stack ────────────────────────────────────────────────
# JAVA_HOME falls back to the Homebrew OpenJDK so recipes work without shell setup.

# Build the Android app (debug APK). This also stages the Swift Android core
# into Gradle-owned build output; no ignored jniLibs input is used.
android-build:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew assembleDebug

# Run Android JVM unit tests.
android-test:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew test

# Build the shared Vulkan renderer and its derived Bitmap SPIR-V.
android-shaders:
    cd ../OpenCine/Android && ./gradlew :vulkan:assembleDebug

# Verify shared Vulkan presentation synchronization; shader compilation is part of android-check.
check-vulkan-shaders:
    ../OpenCine/scripts/android-vulkan-sync-test.sh

# Reject GLSL ES 1.00 reserved words in the GLES2 shaders. Nothing else compiles them before a
# device does, and the live surface answers a compile failure by rendering the plain feed.
check-gles-shaders:
    ../OpenCine/scripts/check-gles-shaders.sh

# Compile the Android instrumentation-test APK without requiring a device.
# `android-check` includes this gate so UI-test source never silently rots in CI.
android-ui-test-compile:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew :app:assembleDebugAndroidTest

# Run Android instrumentation/UI tests on a connected arm64-v8a device or emulator.
# The production app is arm64-only until another ABI has a verified Swift runtime.
android-ui-test:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew connectedDebugAndroidTest

# Run all Android checks: shader lint, build, unit tests, and Android lint.
android-check: check-gles-shaders
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew assembleDebug :app:assembleDebugAndroidTest :wear:assembleDebugAndroidTest test lint

# Generate the Play upload keystore into gitignored .local/ (never committed;
# refuses to overwrite). keytool prompts for the store password interactively.
android-keystore:
    #!/usr/bin/env bash
    set -euo pipefail
    out=".local/android/upload-keystore.jks"
    if [ -e "$out" ]; then
        echo "Refusing to overwrite existing $out — move it aside first if you really mean to regenerate." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$out")"
    export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}"
    "$JAVA_HOME/bin/keytool" -genkeypair -v \
        -keystore "$out" -alias upload \
        -keyalg RSA -keysize 2048 -validity 9125 \
        -dname "CN=OpenZCine Upload"
    echo ""
    echo "Created $out (gitignored). Next steps (details: docs/android-distribution.md):"
    echo "  1. Back the file + password up somewhere safe (losing it means a Play support reset)."
    echo "  2. GitHub 'play' environment secrets:"
    echo "       ANDROID_KEYSTORE_BASE64   base64 -i $out | pbcopy"
    echo "       ANDROID_KEYSTORE_PASSWORD the password you just entered"
    echo "       ANDROID_KEY_ALIAS         upload"
    echo "       ANDROID_KEY_PASSWORD      same as the store password"
    echo "  3. Local signed build: export ANDROID_KEYSTORE_PATH=\"\$PWD/$out\" plus the three vars above,"
    echo "     then: cd Apps/Android && ./gradlew bundleRelease"

# Cross-compile the shared Swift core + JNI facade for the explicitly supported
# arm64-v8a ABI. Gradle owns the generated .so directory, so this cannot rely on
# ignored src/main/jniLibs artifacts. Requires the Swift 6.3.3 toolchain and
# swift-6.3.3-RELEASE_android artifactbundle (see Apps/Android/README.md).
android-core:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew :app:stageSwiftCore

# Build both phone and Wear release artifact shapes, verify the phone's Swift
# runtime closure, and verify the signed/package-compatible Data Layer pair.
android-release-check:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew :app:verifyReleaseNativeLibraries :wear:verifyWearReleaseArtifact

# Device-only JNI load check. Builds the generated arm64 debug APK, installs it
# over the existing app without clearing data, and requires SwiftCoreSmoke's
# core-version line in logcat. Pass a serial with `just android-bridge-smoke <id>`.
android-bridge-smoke serial="":
    just android-build
    ./scripts/android-bridge-smoke.sh {{ if serial == "" { "" } else { "--serial " + serial } }}

# Build and install the debug APK on a connected device/emulator, then launch it.
# With several devices attached, pass the serial: `just android-install R58R92BL76K`.
android-install serial="":
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew assembleDebug
    "${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/platform-tools/adb" {{ if serial == "" { "" } else { "-s " + serial } }} install -r Apps/Android/app/build/outputs/apk/debug/app-debug.apk
    "${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/platform-tools/adb" {{ if serial == "" { "" } else { "-s " + serial } }} shell am start -n com.opencapture.openzcine/.MainActivity

# ── App-flow design (ExcaliDash) ────────────────────────────────────────────
# Start the local ExcaliDash server (http://localhost:6767).
flows-up:
    docker compose -f infra/excalidash/docker-compose.yml up -d

# Stop the local ExcaliDash server.
flows-down:
    docker compose -f infra/excalidash/docker-compose.yml down

# Snapshot ExcaliDash drawings back to docs/flows/*.excalidraw for git (do this + commit
# after a design session — the server is the live source of truth).
flows-pull:
    node scripts/flows-excalidash-sync.mjs pull

# FULL-REPLACE a drawing from its git file (resets any browser layout — deliberate regen only).
# For incremental edits agents use pushMerged() in scripts/flows-dash.mjs, which merges by
# element id, preserves untouched positions, and rebases on conflict instead of clobbering.
flows-push flow="":
    node scripts/flows-excalidash-sync.mjs push {{flow}}

# Print a drawing's live element count, version, and node ids (verify a write landed).
flows-verify flow:
    node scripts/flows-excalidash-sync.mjs verify {{flow}}
