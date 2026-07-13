---
name: ios-testing
description: Use when analyzing test coverage or generating XCTest/Swift Testing cases for the OpenZCine iOS codebase. Covers both the shared core (Tests/OpenZCineCoreTests/) and the iOS shell (ios/RunnerTests/).
---

# iOS Testing

You are a test-coverage expert for the **OpenZCine** project. Your goal is to identify untested code paths and produce well-structured test cases that bring business-logic coverage to 80 % or above.

## Test Targets

| Layer | Source | Test target |
| --- | --- | --- |
| Shared core | `Sources/OpenZCineCore/` | `Tests/OpenZCineCoreTests/` |
| iOS shell | `ios/Runner/` | `ios/RunnerTests/` |

## Test Commands

```bash
just test          # runs the full test suite
just swift-test    # runs only Swift Package tests (OpenZCineCoreTests)
just native-check  # build + test iOS shell
```

## Identifying Untested Paths

1. Read every public type and function in the target file.
2. List branches: `if`/`guard`/`switch` arms, error paths, edge cases (nil, empty, boundary values).
3. Cross-reference `Tests/OpenZCineCoreTests/` (or `ios/RunnerTests/`) to find which branches already have coverage.
4. Report the gap as a prioritised list: untested error paths first, then untested happy paths, then edge cases.

## Writing XCTest Cases

Use XCTest for the shared core and for shell integration tests that call system frameworks.

```swift
import XCTest
@testable import OpenZCineCore

final class MonitorLayoutPolicyTests: XCTestCase {

    func test_singleMonitor_returnsFullFrame() {
        let policy = MonitorLayoutPolicy()
        let result = policy.layout(for: [.init(id: 0, resolution: .init(width: 1920, height: 1080))])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].frame.size, CGSize(width: 1920, height: 1080))
    }

    func test_emptyMonitors_returnsEmpty() {
        let policy = MonitorLayoutPolicy()
        XCTAssertTrue(policy.layout(for: []).isEmpty)
    }
}
```

Guidelines:

- One assertion concept per test function; use `XCTAssertEqual`, `XCTAssertNil`, `XCTAssertThrowsError`.
- Name pattern: `test_<subject>_<condition>_<expectedOutcome>` (snake_case after `test_`).
- Use `@testable import` only when testing `internal` symbols; prefer testing through public API.

## Writing Swift Testing Cases

Use the `Testing` framework (`@Test`, `#expect`, `#require`) for new tests in Swift 6 targets.

```swift
import Testing
@testable import OpenZCineCore

@Suite("MonitorLayoutPolicy")
struct MonitorLayoutPolicyTests {

    @Test("single monitor fills the full frame")
    func singleMonitorFullFrame() {
        let policy = MonitorLayoutPolicy()
        let result = policy.layout(for: [.init(id: 0, resolution: .init(width: 1920, height: 1080))])
        #expect(result.count == 1)
        #expect(result[0].frame.size == CGSize(width: 1920, height: 1080))
    }

    @Test("empty monitor list returns empty layout")
    func emptyMonitorsReturnsEmpty() {
        let policy = MonitorLayoutPolicy()
        #expect(policy.layout(for: []).isEmpty)
    }

    @Test("layout throws for unsupported configuration", .tags(.errorHandling))
    func unsupportedConfigurationThrows() throws {
        let policy = MonitorLayoutPolicy()
        #expect(throws: LayoutError.unsupported) {
            try policy.strictLayout(for: [])
        }
    }
}
```

Guidelines:

- Use `#expect` for soft assertions (test continues on failure).
- Use `#require` for preconditions (test aborts on failure — equivalent to `XCTUnwrap`).
- Use `@Suite` to group related tests; use `.tags()` for cross-cutting concerns.
- Parameterise with `@Test(arguments:)` when testing multiple input/output pairs.

## Coverage Targets

| Code category | Target |
| --- | --- |
| Business logic (`OpenZCineCore` protocols, policies, state machines) | ≥ 80 % |
| Error handling and edge cases | 100 % of documented paths |
| UI binding code in shell | ≥ 50 % (snapshot or behaviour tests) |
| Pure layout helpers | ≥ 70 % |

## Critical Rules

- **Never import SwiftUI, UIKit, or AppKit in `OpenZCineCoreTests/`.** The shared core is UI-free; tests must stay UI-free.
- Do not add test dependencies that require a running simulator for `OpenZCineCoreTests/` — those tests must run headless via `just swift-test`.
- Shell tests in `ios/RunnerTests/` may use `XCUITest` for behaviour tests but keep unit tests in `RunnerTests/` host-app-free where possible.
