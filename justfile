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
    brew install typos-cli editorconfig-checker lychee markdownlint-cli2 actionlint gitleaks swift-format
    git config core.hooksPath .githooks

# ── Meta checks (run today; mirrored in CI) ─────────────────────────────────
# Run every repository quality check.
check: hygiene site-check typos lint-md check-links check-editorconfig lint-actions secrets check-demo-isolation swift-lint swift-test

# Reject tracked proprietary, secret-bearing, generated, or machine-specific files.
hygiene:
    ./scripts/check-repository-hygiene.sh

# Validate the deploy-ready landing-page tree and all local asset references.
site-check:
    ./scripts/check-site.sh

# Spell-check the repository.
typos:
    typos

# Lint all Markdown (exclusions in .markdownlint-cli2.jsonc).
lint-md:
    markdownlint-cli2 "**/*.md"

# Check that on-disk links resolve (offline; no network flakiness).
# Excludes proprietary dirs, internal planning artifacts (which embed sample docs),
# and the GitHub Pages landing page. `site-check` validates that static tree without
# following its external product links.
check-links:
    lychee --no-progress --offline --exclude-path vendor --exclude-path ref --exclude-path docs/design --exclude-path site .

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

# Demo/screenshot env hooks (ZC_DEMO_*, ZC_METAL_FEED, ZC_GPU_SCOPES) must stay inside
# ios/Runner/DemoHarness.swift, whose Release stubs compile them out of TestFlight builds.
# Doc-comment mentions elsewhere are allowed; code reads are not.
check-demo-isolation:
    ! grep -rn 'ZC_DEMO\|ZC_METAL_FEED\|ZC_GPU_SCOPES' Sources ios/Runner ios/OpenZCineWatch --include='*.swift' | grep -v '^ios/Runner/DemoHarness.swift:' | grep -vE ':[0-9]+: *///?' | grep .

# Run all Swift-only checks.
swift-check: swift-lint swift-test

# Build the native iOS app for the simulator.
ios-build:
    xcodebuild -project ios/Runner.xcodeproj -scheme Runner -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

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

# Run all native production checks that do not require camera hardware.
native-check: check-demo-isolation swift-check ios-build watch-build

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

# Build the Android app (debug APK).
android-build:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew assembleDebug

# Run Android JVM unit tests.
android-test:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew test

# Run all Android checks: build, unit tests, and Android lint.
android-check:
    cd Apps/Android && JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}" ./gradlew assembleDebug test lint

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
