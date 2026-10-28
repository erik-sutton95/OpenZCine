#!/usr/bin/env bash
# Regression tests for scripts/ios-test.sh, against a stand-in xcodebuild that records its calls.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

mkdir "$temp_dir/bin"
cat > "$temp_dir/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XCODEBUILD_CALLS"
[ -z "${XCODEBUILD_FAIL:-}" ]
EOF
chmod +x "$temp_dir/bin/xcodebuild"
export PATH="$temp_dir/bin:$PATH" IOS_TEST_DEVICE_ID=SIM-1 XCODEBUILD_CALLS="$temp_dir/calls"

run() {
  : > "$XCODEBUILD_CALLS"
  "$script_dir/ios-test.sh" "$@"
}

expect_calls() {
  local expected="$1"
  if [ "$(cat "$XCODEBUILD_CALLS")" != "$expected" ]; then
    printf 'Expected xcodebuild calls:\n%s\nGot:\n%s\n' "$expected" "$(cat "$XCODEBUILD_CALLS")" >&2
    exit 1
  fi
}

on_device="-project ios/Runner.xcodeproj -scheme Runner -destination platform=iOS Simulator,id=SIM-1"

# No arguments: one build for the test simulator, then the tests without rebuilding.
run
expect_calls "$on_device build-for-testing
$on_device test-without-building"

# Test-run options reach the test run alone; build options reach both calls.
run -resultBundlePath /tmp/r.xcresult -only-testing:RunnerTests/A -test-iterations 2 \
  -retry-tests-on-failure -derivedDataPath /tmp/dd OTHER_SWIFT_FLAGS=-DX
expect_calls "$on_device -derivedDataPath /tmp/dd OTHER_SWIFT_FLAGS=-DX build-for-testing
$on_device -resultBundlePath /tmp/r.xcresult -only-testing:RunnerTests/A -test-iterations 2 -retry-tests-on-failure -derivedDataPath /tmp/dd OTHER_SWIFT_FLAGS=-DX test-without-building"

# The environment's result bundle goes to the test run only.
IOS_TEST_RESULT_BUNDLE_PATH=/tmp/env.xcresult run
expect_calls "$on_device build-for-testing
$on_device -resultBundlePath /tmp/env.xcresult test-without-building"

# A failed build never starts the tests, and the failure is the script's exit status.
: > "$XCODEBUILD_CALLS"
if XCODEBUILD_FAIL=1 "$script_dir/ios-test.sh" 2>/dev/null; then
  echo "Expected a failed build to fail ios-test.sh" >&2
  exit 1
fi
expect_calls "$on_device build-for-testing"

# The log keeps both calls' output, and a failure still fails the script through the pipe.
: > "$XCODEBUILD_CALLS"
if XCODEBUILD_FAIL=1 IOS_TEST_LOG_PATH="$temp_dir/log" "$script_dir/ios-test.sh"; then
  echo "Expected a failed build to fail ios-test.sh with a log" >&2
  exit 1
fi

# An option that needs a value and has none is refused before anything runs.
: > "$XCODEBUILD_CALLS"
if "$script_dir/ios-test.sh" -resultBundlePath 2>/dev/null; then
  echo "Expected a missing option value to fail" >&2
  exit 1
fi
expect_calls ""

echo "ios-test.sh tests passed."
