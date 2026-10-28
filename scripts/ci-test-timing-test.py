#!/usr/bin/env python3
"""Regression tests for scripts/ci-test-timing.py, on fixtures shaped like real CI output."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

# Loading the script must not leave a __pycache__ directory in the repository.
sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("ci-test-timing.py")
spec = importlib.util.spec_from_file_location("ci_test_timing", SCRIPT)
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)

SWIFT_LOG = """\
Test Suite 'All tests' started at 2026-10-28 14:35:09.041.
◇ Suite "Focus peaking on real ZR frames" started.
✔ Test "Low paints less than High on the same real frame" passed after 15.743 seconds.
✔ Test cubeIsFinite(look:) with 4 test cases passed after 0.198 seconds.
✘ Test "The sweep stays within its reviewed baseline" recorded an issue at Peaking.swift:228:17
✘ Test "The sweep stays within its reviewed baseline" failed after 35.489 seconds with 1 issue.
➜ Test "Needs hardware" skipped: "no camera"
✘ Suite "Focus peaking on real ZR frames" failed after 35.490 seconds with 1 issue.
✔ Suite FeedEffectsWireTests passed after 2.362 seconds.
✘ Test run with 3 tests in 2 suites failed after 35.490 seconds with 1 issue.
✔ Test run with 32 tests in 5 suites passed after 2.362 seconds.
"""

XCRESULT = {
    "testNodes": [
        {
            "name": "Runner",
            "nodeType": "Test Plan",
            "children": [
                {
                    "name": "RunnerTests",
                    "nodeType": "Unit test bundle",
                    "children": [
                        {
                            "name": "MediaTimecodeTests",
                            "nodeType": "Test Suite",
                            "children": [
                                {
                                    "name": "testExport()",
                                    "nodeType": "Test Case",
                                    "result": "Passed",
                                    "durationInSeconds": 35.4,
                                },
                                {
                                    "name": "testSkip()",
                                    "nodeType": "Test Case",
                                    "result": "Skipped",
                                    "durationInSeconds": 0.1,
                                },
                            ],
                        },
                        {
                            "name": "PeakingTests",
                            "nodeType": "Test Suite",
                            "children": [
                                {
                                    "name": "Nested",
                                    "nodeType": "Test Suite",
                                    "children": [
                                        {
                                            "name": "matches()",
                                            "nodeType": "Test Case",
                                            "result": "Failed",
                                            "durationInSeconds": 2.0,
                                            "children": [
                                                {"name": "boom", "nodeType": "Failure Message"}
                                            ],
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                }
            ],
        }
    ],
}

GRADLE_TIMING = """\
:app:stageSwiftCore\t312000\tEXECUTED
:app:compileDebugKotlin\t95000\tEXECUTED
:opencine:nikon:compileDebugKotlin\t41000\tFROM-CACHE
:app:testDebugUnitTest\t120500\tEXECUTED
:wear:preBuild\t1\tUP-TO-DATE
not a task line
"""

JUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="com.opencapture.openzcine.FooTest" tests="4" skipped="1" failures="1"
    errors="0" time="3.25">
    <testcase name="a" classname="com.opencapture.openzcine.FooTest" time="3.0"/>
</testsuite>
"""


class SwiftTestingTests(unittest.TestCase):
    def test_reports_runs_suites_and_results(self):
        out = timing.swift_testing(SWIFT_LOG)
        self.assertIn("3 tests in 2 suites failed after 35.5 s", out)
        self.assertIn("32 tests in 5 suites passed after 2.4 s", out)
        self.assertIn("2 passed, 1 failed, 1 skipped", out)
        self.assertIn("| cubeIsFinite(look:) | passed | 0.2 |", out)
        # Slowest suite first, display names and plain type names both parsed.
        self.assertLess(
            out.index("Focus peaking on real ZR frames | failed | 35.5"),
            out.index("FeedEffectsWireTests | passed | 2.4"),
        )
        self.assertNotIn("recorded an issue", out)

    def test_pipes_in_names_stay_inside_their_cell(self):
        out = timing.swift_testing(
            '✔ Test "a | b" passed after 1.0 seconds.\n'
            "✔ Test run with 1 test in 1 suite passed after 1.0 seconds.\n"
        )
        self.assertIn("| a \\| b | passed | 1.0 |", out)

    def test_empty_log_says_so(self):
        self.assertIn("No Swift Testing results", timing.swift_testing("Build complete!\n"))


class XcresultTests(unittest.TestCase):
    def test_groups_cases_by_outermost_suite(self):
        out = timing.xcresult("Runner.xcresult", XCRESULT)
        self.assertIn("3 test cases: 1 failed, 1 passed, 1 skipped", out)
        self.assertIn("| MediaTimecodeTests | 2 | 0 | 1 | 35.5 |", out)
        self.assertIn("| PeakingTests | 1 | 1 | 0 | 2.0 |", out)
        self.assertIn("| MediaTimecodeTests/testExport() | Passed | 35.4 |", out)

    def test_empty_bundle_says_so(self):
        self.assertIn("No test cases", timing.xcresult("x.xcresult", {"testNodes": []}))


class GradleTests(unittest.TestCase):
    def test_tasks_sorted_and_grouped_by_name(self):
        out = timing.gradle_tasks(GRADLE_TIMING)
        self.assertIn("5 tasks: 3 executed, 1 from-cache, 1 up-to-date", out)
        self.assertLess(
            out.index(":app:stageSwiftCore | EXECUTED | 312.0"),
            out.index(":app:testDebugUnitTest | EXECUTED | 120.5"),
        )
        self.assertIn("| compileDebugKotlin | 2 | 136.0 |", out)

    def test_junit_suites_by_module(self):
        with tempfile.TemporaryDirectory() as root:
            report = Path(root, "app/build/test-results/testDebugUnitTest/TEST-Foo.xml")
            report.parent.mkdir(parents=True)
            report.write_text(JUNIT)
            out = timing.junit_suites([report])
        self.assertIn("1 suites, 4 tests, 1 failed, 1 skipped, 3.2 s summed", out)
        self.assertIn("| app testDebugUnitTest | 1 | 4 | 3.2 |", out)
        self.assertIn(
            "| com.opencapture.openzcine.FooTest | app testDebugUnitTest | 4 | 1 | 3.2 |", out
        )

    def test_missing_inputs_say_so(self):
        self.assertIn("No task timings", timing.gradle_tasks(""))
        self.assertIn("No JUnit reports", timing.junit_suites([]))


if __name__ == "__main__":
    unittest.main()
