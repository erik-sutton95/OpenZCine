#!/usr/bin/env python3
"""Per-suite and per-task timing tables for the CI job summary, as Markdown on stdout.

    ci-test-timing.py swift-testing LOG
        Swift package tests, from `swift test` output (Swift Testing).
    ci-test-timing.py xcresult BUNDLE...
        iOS unit tests, from one or more xcresult bundles.
    ci-test-timing.py gradle TIMING [ROOT...]
        Gradle tasks, from the list scripts/ci-gradle-task-timing.gradle writes, plus the JUnit
        suites under each ROOT's build/test-results.

The tables only report what ran; they never fail a job. A missing or empty input prints a note.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ElementTree
from collections import defaultdict
from pathlib import Path

TOP = 25

# The name is either quoted (a display name) or a bare type or function name.
NAME = r'(?:"(?P<quoted>.+)"|(?P<plain>\S+))'
VERDICT = r"(?P<verb>passed|failed) after (?P<secs>[\d.]+) seconds"
# `✔ Suite "Display name" passed after 1.234 seconds.` or `✘ Suite TypeName failed after ...`
SWIFT_SUITE = re.compile(rf"^. Suite {NAME} {VERDICT}")
# Parameterized tests add `with N test cases` before the verdict.
SWIFT_TEST = re.compile(rf"^. Test {NAME}(?: with \d+ test cases?)? {VERDICT}")
SWIFT_SKIP = re.compile(rf"^. Test {NAME} skipped")
SWIFT_RUN = re.compile(
    rf"^. Test run with (?P<tests>\d+) tests? in (?P<suites>\d+) suites? {VERDICT}"
)


def table(headers: list[str], rows: list[list[str]]) -> str:
    """A Markdown table; numeric columns are right-aligned."""
    align = (
        [
            "---:" if all(re.fullmatch(r"[\d.,]+", row[index]) for row in rows) else "---"
            for index in range(len(headers))
        ]
        if rows
        else ["---"] * len(headers)
    )
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(align) + " |"]
    # A test name may contain a pipe; escaped, it stays inside its cell.
    lines += ["| " + " | ".join(cell.replace("|", "\\|") for cell in row) + " |" for row in rows]
    return "\n".join(lines)


def seconds(value: float) -> str:
    return f"{value:.1f}"


def swift_testing(log: str) -> str:
    """Suites by wall time, slowest tests and run totals from Swift Testing console output."""
    suites, tests, skipped, runs = [], [], 0, []
    for line in log.splitlines():
        if match := SWIFT_RUN.match(line):
            runs.append(match)
        elif match := SWIFT_SUITE.match(line):
            suites.append((match["quoted"] or match["plain"], match["verb"], float(match["secs"])))
        elif match := SWIFT_TEST.match(line):
            tests.append((match["quoted"] or match["plain"], match["verb"], float(match["secs"])))
        elif SWIFT_SKIP.match(line):
            skipped += 1
    if not runs and not suites:
        return "### Swift package tests\n\nNo Swift Testing results in the log.\n"
    out = ["### Swift package tests", ""]
    for run in runs:
        out.append(
            f"- Run: {run['tests']} tests in {run['suites']} suites {run['verb']} after "
            f"{seconds(float(run['secs']))} s"
        )
    out.append(
        f"- Test results: {sum(1 for t in tests if t[1] == 'passed')} passed, "
        f"{sum(1 for t in tests if t[1] == 'failed')} failed, {skipped} skipped"
    )
    out += ["", "Suites run in parallel, so their wall times overlap.", ""]
    rows = [[name, verb, seconds(secs)] for name, verb, secs in sorted(suites, key=lambda s: -s[2])]
    out += [table(["Suite", "Result", "Wall s"], rows[:TOP]), ""]
    rows = [[name, verb, seconds(secs)] for name, verb, secs in sorted(tests, key=lambda t: -t[2])]
    out += ["Slowest tests:", "", table(["Test", "Result", "Wall s"], rows[:10]), ""]
    return "\n".join(out)


def xcresult_cases(nodes: list[dict], suite: str | None = None):
    """Yields (suite, test case node) for every test case, keyed by its outermost suite."""
    for node in nodes:
        kind = node.get("nodeType")
        if kind == "Test Case":
            yield suite or "(no suite)", node
        else:
            outer = suite or (node.get("name") if kind == "Test Suite" else None)
            yield from xcresult_cases(node.get("children", []), outer)


def xcresult(name: str, tests: dict) -> str:
    """Suites by summed test time, slowest cases and result counts from `xcresulttool` JSON."""
    by_suite: dict[str, dict] = defaultdict(lambda: defaultdict(float))
    cases = []
    for suite, case in xcresult_cases(tests.get("testNodes", [])):
        duration = float(case.get("durationInSeconds", 0))
        result = case.get("result", "Unknown")
        by_suite[suite]["seconds"] += duration
        by_suite[suite][result] += 1
        cases.append((f"{suite}/{case.get('name', '?')}", result, duration))
    if not cases:
        return f"### {name}\n\nNo test cases in the result bundle.\n"
    totals: dict[str, int] = defaultdict(int)
    for _, result, _ in cases:
        totals[result] += 1
    out = [
        f"### {name}",
        "",
        f"- {len(cases)} test cases: "
        + ", ".join(f"{count} {result.lower()}" for result, count in sorted(totals.items())),
        f"- Summed test time: {seconds(sum(c[2] for c in cases))} s",
        "",
    ]
    rows = [
        [
            suite,
            str(int(sum(v for k, v in stats.items() if k != "seconds"))),
            str(int(stats.get("Failed", 0))),
            str(int(stats.get("Skipped", 0))),
            seconds(stats["seconds"]),
        ]
        for suite, stats in sorted(by_suite.items(), key=lambda item: -item[1]["seconds"])
    ]
    out += [table(["Suite", "Tests", "Failed", "Skipped", "Test s"], rows[:TOP]), ""]
    rows = [
        [case, result, seconds(secs)] for case, result, secs in sorted(cases, key=lambda c: -c[2])
    ]
    out += ["Slowest tests:", "", table(["Test", "Result", "s"], rows[:10]), ""]
    return "\n".join(out)


def gradle_tasks(timing: str) -> str:
    """Slowest tasks and time per task name (summed across projects) from the init script's list."""
    tasks = []
    for line in timing.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[1].isdigit():
            tasks.append((parts[0], int(parts[1]) / 1000, parts[2]))
    if not tasks:
        return "### Gradle tasks\n\nNo task timings were recorded.\n"
    outcomes: dict[str, int] = defaultdict(int)
    for _, _, outcome in tasks:
        outcomes[outcome] += 1
    out = [
        "### Gradle tasks",
        "",
        f"- {len(tasks)} tasks: "
        + ", ".join(f"{count} {outcome.lower()}" for outcome, count in sorted(outcomes.items())),
        f"- Summed task time: {seconds(sum(t[1] for t in tasks))} s (parallel workers overlap)",
        "",
    ]
    rows = [
        [path, outcome, seconds(secs)] for path, secs, outcome in sorted(tasks, key=lambda t: -t[1])
    ]
    out += [table(["Task", "Outcome", "s"], rows[:TOP]), ""]
    by_name: dict[str, list[float]] = defaultdict(list)
    for path, secs, _ in tasks:
        by_name[path.rsplit(":", 1)[-1]].append(secs)
    rows = [
        [name, str(len(times)), seconds(sum(times))]
        for name, times in sorted(by_name.items(), key=lambda item: -sum(item[1]))
    ]
    out += [
        "By task name, across projects:",
        "",
        table(["Task name", "Projects", "s"], rows[:15]),
        "",
    ]
    return "\n".join(out)


def junit_suites(paths: list[Path]) -> str:
    """JVM test suites by time from Gradle's JUnit XML reports."""
    suites = []
    for path in paths:
        try:
            # Gradle's own reports from this job; expat does not fetch external entities.
            root = ElementTree.parse(path).getroot()
        except ElementTree.ParseError:
            continue
        # <module>/build/test-results/<task>/TEST-*.xml
        module = path.parents[3].name if len(path.parents) > 3 else "?"
        variant = path.parent.name
        for suite in [root] if root.tag == "testsuite" else root.iter("testsuite"):
            suites.append(
                (
                    f"{module} {variant}",
                    suite.get("name", "?"),
                    int(suite.get("tests", 0)),
                    int(suite.get("failures", 0)) + int(suite.get("errors", 0)),
                    int(suite.get("skipped", 0)),
                    float(suite.get("time", 0)),
                )
            )
    if not suites:
        return "### JVM test suites\n\nNo JUnit reports were found.\n"
    out = [
        "### JVM test suites",
        "",
        f"- {len(suites)} suites, {sum(s[2] for s in suites)} tests, "
        f"{sum(s[3] for s in suites)} failed, {sum(s[4] for s in suites)} skipped, "
        f"{seconds(sum(s[5] for s in suites))} s summed",
        "",
    ]
    by_module: dict[str, list] = defaultdict(lambda: [0, 0, 0.0])
    for module, _, count, _, _, secs in suites:
        by_module[module][0] += 1
        by_module[module][1] += count
        by_module[module][2] += secs
    rows = [
        [module, str(stats[0]), str(stats[1]), seconds(stats[2])]
        for module, stats in sorted(by_module.items(), key=lambda item: -item[1][2])
    ]
    out += [table(["Module and variant", "Suites", "Tests", "s"], rows), ""]
    rows = [
        [name, module, str(count), str(failed), seconds(secs)]
        for module, name, count, failed, _, secs in sorted(suites, key=lambda s: -s[5])
    ]
    out += [
        "Slowest suites:",
        "",
        table(["Suite", "Module and variant", "Tests", "Failed", "s"], rows[:TOP]),
        "",
    ]
    return "\n".join(out)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] not in {"swift-testing", "xcresult", "gradle"}:
        print(__doc__, file=sys.stderr)
        return 2
    command, inputs = argv[0], argv[1:]
    if command == "swift-testing":
        path = Path(inputs[0])
        print(
            swift_testing(path.read_text(errors="replace"))
            if path.is_file()
            else f"### Swift package tests\n\nNo log at `{path}`.\n"
        )
    elif command == "xcresult":
        for bundle in map(Path, inputs):
            if not bundle.exists():
                # A step that never ran (the nightly-only quarantine run on a PR) leaves none.
                print(f"### {bundle.name}\n\nNo result bundle: that run did not happen.\n")
                continue
            raw = subprocess.run(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                capture_output=True,
                text=True,
                check=False,
            )
            if raw.returncode != 0:
                print(f"### {bundle.name}\n\n`xcresulttool` could not read it.\n")
                continue
            print(xcresult(bundle.name, json.loads(raw.stdout)))
    else:
        timing = Path(inputs[0])
        print(gradle_tasks(timing.read_text() if timing.is_file() else ""))
        reports = sorted(
            p for root in inputs[1:] for p in Path(root).glob("**/build/test-results/**/TEST-*.xml")
        )
        # Only a job that ran JVM tests has reports; the others print the task table alone.
        if reports:
            print(junit_suites(reports))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
