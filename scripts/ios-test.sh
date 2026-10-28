#!/usr/bin/env bash
# Build the iOS app and its unit tests once for one iPhone simulator, then run them there without
# rebuilding (`just ios-test`). The simulator is IOS_TEST_DEVICE_ID, or the first available iPhone.
# IOS_TEST_RESULT_BUNDLE_PATH and IOS_TEST_LOG_PATH keep the result bundle and the combined log.
#
# Extra arguments are xcodebuild options. Options that only steer the test run (filters, repeats,
# timeouts, parallelism, diagnostics, result bundle and stream) go to test-without-building alone:
# a result bundle path given to the build as well would already exist when the tests start, and
# xcodebuild refuses that. Every other option (build settings, -configuration, -derivedDataPath,
# -testPlan, coverage, sanitizers) goes to both calls, as it did to the single `xcodebuild test`.
set -euo pipefail

build_args=()
test_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -retry-tests-on-failure | -run-tests-until-failure | -only-testing:* | -skip-testing:*)
      test_args+=("$1")
      shift
      ;;
    -resultBundlePath | -resultStreamPath | -resultBundleVersion | -only-testing | -skip-testing \
      | -only-test-configuration | -skip-test-configuration | -parallel-testing-enabled \
      | -parallel-testing-worker-count | -maximum-parallel-testing-workers \
      | -maximum-concurrent-test-device-destinations \
      | -maximum-concurrent-test-simulator-destinations | -test-timeouts-enabled \
      | -default-test-execution-time-allowance | -maximum-test-execution-time-allowance \
      | -test-iterations | -test-repetition-relaunch-enabled | -collect-test-diagnostics \
      | -testLanguage | -testRegion)
      if [ "$#" -lt 2 ]; then
        echo "ios-test: $1 needs a value" >&2
        exit 2
      fi
      test_args+=("$1" "$2")
      shift 2
      ;;
    *)
      build_args+=("$1")
      test_args+=("$1")
      shift
      ;;
  esac
done

device_id="${IOS_TEST_DEVICE_ID:-}"
if [ -z "$device_id" ]; then
  device_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && !found { print $2; found = 1 }')"
fi
if [ -z "$device_id" ]; then
  echo "No available iPhone simulator found." >&2
  exit 1
fi
if [ -n "${IOS_TEST_RESULT_BUNDLE_PATH:-}" ]; then
  test_args+=(-resultBundlePath "$IOS_TEST_RESULT_BUNDLE_PATH")
fi

# The empty-array guards keep bash 3.2 (macOS /bin/bash) happy under `set -u`.
xcodebuild_on_device() {
  xcodebuild -project ios/Runner.xcodeproj -scheme Runner \
    -destination "platform=iOS Simulator,id=$device_id" "$@"
}
build_and_test() {
  xcodebuild_on_device ${build_args[@]+"${build_args[@]}"} build-for-testing \
    && xcodebuild_on_device ${test_args[@]+"${test_args[@]}"} test-without-building
}
if [ -n "${IOS_TEST_LOG_PATH:-}" ]; then
  build_and_test 2>&1 | tee "$IOS_TEST_LOG_PATH"
else
  build_and_test
fi
