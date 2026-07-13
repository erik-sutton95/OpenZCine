# Responsive Startup Layout Foundation Implementation Plan

**Goal:** Replace fixed Penpot-board startup sizing with tested adaptive layout rules for iOS
startup, discovery, saved-camera, and camera-ready screens.

**Architecture:** Keep responsive sizing decisions in `OpenZCineCore` as pure, tested policy. SwiftUI
will render from that policy using flexible columns, scoped scrolling, and safe-area-aware content
margins. Penpot remains visual intent, not a fixed runtime canvas.

**Tech Stack:** Swift Package Manager, Swift Testing, SwiftUI, existing `just` recipes.

---

## File Structure

- Modify: `Sources/OpenZCineCore/MonitorLayoutPolicy.swift`
  - Add `StartupLayoutProfile`, `StartupContentMode`, and adaptive column fields to
    `StartupContentLayout`.
  - Replace scale-to-fit reference sizing with content width, intro column width, action column
    width, spacing, and visibility flags.
- Modify: `Tests/OpenZCineCoreTests/MonitorLayoutPolicyTests.swift`
  - Replace reference-scale tests with no-overflow and profile tests across representative device
    sizes.
- Modify: `ios/Runner/NativeAppRoot.swift`
  - Compute startup layout from viewport width, viewport height, and safe area.
  - Render discovery, saved-camera, and camera-ready screens from adaptive column widths.
  - Remove the global `scaleEffect` startup fitting helper.
- Modify: `docs/design/plans/2026-06-20-wireframe-kit-app.md`
  - Mark completed Stage 0.5 items after implementation and verification.

## Task 1: Core Startup Layout Policy

**Files:**

- Modify: `Sources/OpenZCineCore/MonitorLayoutPolicy.swift`
- Test: `Tests/OpenZCineCoreTests/MonitorLayoutPolicyTests.swift`

- [ ] **Step 1: Write failing layout policy tests**

Replace the two existing startup landscape scale tests in
`Tests/OpenZCineCoreTests/MonitorLayoutPolicyTests.swift` with these tests:

```swift
@Test func startupLayoutUsesTwoColumnsOnRegularLandscapePhone() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 956,
        viewportHeight: 440,
        safeArea: .zero
    )

    #expect(layout.profile == .regularLandscape)
    #expect(layout.mode == .twoColumn)
    #expect(layout.availableWidth == 900)
    #expect(layout.contentWidth == 900)
    #expect(layout.introColumnWidth >= 380)
    #expect(layout.actionColumnWidth >= 420)
    #expect(layout.columnSpacing >= 56)
    #expect(layout.totalColumnWidth <= layout.availableWidth)
    #expect(layout.showSecondaryVisuals)
    #expect(layout.showFooterLinks)
}

@Test func startupLayoutUsesTwoColumnsInsideNotchedLandscapeSafeArea() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 844,
        viewportHeight: 390,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    #expect(layout.profile == .regularLandscape)
    #expect(layout.mode == .twoColumn)
    #expect(layout.availableWidth == 685)
    #expect(layout.contentWidth == 685)
    #expect(layout.introColumnWidth >= 260)
    #expect(layout.actionColumnWidth >= 340)
    #expect(layout.columnSpacing >= 32)
    #expect(layout.totalColumnWidth <= layout.availableWidth)
    #expect(layout.showSecondaryVisuals)
}

@Test func startupLayoutFallsBackToSingleColumnWhenMinimumColumnsCannotFit() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 740,
        viewportHeight: 360,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)
    )

    #expect(layout.profile == .compactLandscape)
    #expect(layout.mode == .singleColumn)
    #expect(layout.availableWidth == 581)
    #expect(layout.contentWidth <= layout.availableWidth)
    #expect(layout.introColumnWidth == layout.contentWidth)
    #expect(layout.actionColumnWidth == layout.contentWidth)
    #expect(layout.totalColumnWidth == layout.contentWidth)
}

@Test func startupLayoutCapsWideContentInsteadOfStretchingControls() {
    let layout = StartupContentLayout.fit(
        viewportWidth: 1194,
        viewportHeight: 834,
        safeArea: MonitorEdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24)
    )

    #expect(layout.profile == .wideLandscape)
    #expect(layout.mode == .twoColumn)
    #expect(layout.availableWidth == 1090)
    #expect(layout.contentWidth == 920)
    #expect(layout.totalColumnWidth == layout.contentWidth)
    #expect(layout.actionColumnWidth <= 520)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```sh
just swift-test
```

Expected: FAIL because `StartupContentLayout.fit(viewportWidth:viewportHeight:safeArea:)`,
`StartupLayoutProfile`, `StartupContentMode`, `contentWidth`, `introColumnWidth`,
`actionColumnWidth`, `columnSpacing`, `totalColumnWidth`, `showSecondaryVisuals`, and
`showFooterLinks` do not exist yet.

- [ ] **Step 3: Implement adaptive layout policy**

Replace the current `StartupContentLayout` in `Sources/OpenZCineCore/MonitorLayoutPolicy.swift` with:

```swift
/// Semantic startup layout profile selected from viewport shape and safe content width.
public enum StartupLayoutProfile: Equatable, Sendable {
    /// Narrow portrait shape. The app is currently landscape-locked, but this keeps policy explicit.
    case compactPortrait

    /// Landscape shape where two readable columns cannot fit.
    case compactLandscape

    /// Primary iPhone landscape layout.
    case regularLandscape

    /// Large landscape layout with capped content width.
    case wideLandscape
}

/// Startup content arrangement.
public enum StartupContentMode: Equatable, Sendable {
    /// Intro and controls stack vertically.
    case singleColumn

    /// Intro and controls sit side by side.
    case twoColumn
}

/// Adaptive startup content layout after safe-area margins have been applied.
public struct StartupContentLayout: Equatable, Sendable {
    /// Smallest readable intro column in two-column mode.
    public static let minimumIntroColumnWidth = 230.0

    /// Smallest readable action/list column in two-column mode.
    public static let minimumActionColumnWidth = 320.0

    /// Tightest acceptable spacing between two startup columns.
    public static let minimumColumnSpacing = 32.0

    /// Preferred maximum content width before wide layouts stop stretching controls.
    public static let maximumContentWidth = 920.0

    /// Maximum width for a single-column startup stack.
    public static let maximumSingleColumnWidth = 520.0

    /// Selected semantic layout profile.
    public let profile: StartupLayoutProfile

    /// Selected content arrangement.
    public let mode: StartupContentMode

    /// Width remaining for startup content after margins.
    public let availableWidth: Double

    /// Actual width used by the startup content.
    public let contentWidth: Double

    /// Width assigned to the intro/explainer column.
    public let introColumnWidth: Double

    /// Width assigned to the action/list column.
    public let actionColumnWidth: Double

    /// Spacing between intro and action columns.
    public let columnSpacing: Double

    /// Whether secondary art, such as the discovery scope, has enough space to be useful.
    public let showSecondaryVisuals: Bool

    /// Whether footer links should be shown without crowding primary actions.
    public let showFooterLinks: Bool

    /// Total horizontal footprint of the current column arrangement.
    public var totalColumnWidth: Double {
        switch mode {
        case .singleColumn:
            contentWidth
        case .twoColumn:
            introColumnWidth + columnSpacing + actionColumnWidth
        }
    }

    /// Fits startup content inside the safe content area using adaptive columns.
    public static func fit(
        viewportWidth: Double,
        viewportHeight: Double,
        safeArea: MonitorEdgeInsets
    ) -> StartupContentLayout {
        let portrait = viewportHeight > viewportWidth
        let compactCandidate = portrait || viewportWidth < 760
        let margins = StartupLayoutMargins.content(for: safeArea, compact: compactCandidate)
        let availableWidth = max(0, viewportWidth - margins.leading - margins.trailing)
        let availableHeight = max(0, viewportHeight - margins.top - margins.bottom)
        let minimumTwoColumnWidth =
            minimumIntroColumnWidth + minimumColumnSpacing + minimumActionColumnWidth
        let shouldUseSingleColumn = compactCandidate || availableWidth < minimumTwoColumnWidth

        if shouldUseSingleColumn {
            let profile: StartupLayoutProfile = portrait ? .compactPortrait : .compactLandscape
            let contentWidth = min(availableWidth, maximumSingleColumnWidth)

            return StartupContentLayout(
                profile: profile,
                mode: .singleColumn,
                availableWidth: availableWidth,
                contentWidth: contentWidth,
                introColumnWidth: contentWidth,
                actionColumnWidth: contentWidth,
                columnSpacing: 0,
                showSecondaryVisuals: availableWidth >= 360 && availableHeight >= 300,
                showFooterLinks: availableHeight >= 340
            )
        }

        let profile: StartupLayoutProfile = availableWidth > maximumContentWidth
            ? .wideLandscape
            : .regularLandscape
        let contentWidth = min(availableWidth, maximumContentWidth)
        let columnSpacing = min(66, max(minimumColumnSpacing, contentWidth * 0.07))
        let actionColumnWidth = min(520, max(minimumActionColumnWidth, contentWidth * 0.48))
        let introColumnWidth = contentWidth - columnSpacing - actionColumnWidth

        return StartupContentLayout(
            profile: profile,
            mode: .twoColumn,
            availableWidth: availableWidth,
            contentWidth: contentWidth,
            introColumnWidth: introColumnWidth,
            actionColumnWidth: actionColumnWidth,
            columnSpacing: columnSpacing,
            showSecondaryVisuals: introColumnWidth >= 250 && availableHeight >= 300,
            showFooterLinks: availableHeight >= 330 && introColumnWidth >= 260
        )
    }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```sh
just swift-test
```

Expected: PASS for all Swift tests.

- [ ] **Step 5: Commit core policy**

Run:

```sh
git add Sources/OpenZCineCore/MonitorLayoutPolicy.swift Tests/OpenZCineCoreTests/MonitorLayoutPolicyTests.swift
git commit -m "feat: add adaptive startup layout policy"
```

## Task 2: SwiftUI Startup Container

**Files:**

- Modify: `ios/Runner/NativeAppRoot.swift`
- Test: existing build through `just native-check`

- [ ] **Step 1: Update layout creation**

In `LinkExperience.body`, replace the current `compact` and `contentLayout` calculations with:

```swift
let contentLayout = StartupContentLayout.fit(
    viewportWidth: Double(proxy.size.width),
    viewportHeight: Double(proxy.size.height),
    safeArea: proxy.monitorEdgeInsets
)
let compact = contentLayout.mode == .singleColumn
let margins = StartupLayoutMargins.content(
    for: proxy.monitorEdgeInsets,
    compact: compact
)
```

- [ ] **Step 2: Replace fixed startup scaling**

Delete the `startupLandscapeFitted(_:)` helper from the `extension View` block near the bottom of
`ios/Runner/NativeAppRoot.swift`.

Add this helper instead:

```swift
fileprivate func startupContentWidth(_ layout: StartupContentLayout) -> some View {
    frame(width: CGFloat(layout.contentWidth), alignment: .topLeading)
}
```

- [ ] **Step 3: Update camera-ready two-column layout**

In `StartupCameraReadyView`, keep `let contentLayout: StartupContentLayout` and replace the
non-compact `HStack` with:

```swift
HStack(alignment: .top, spacing: CGFloat(contentLayout.columnSpacing)) {
    intro
        .frame(width: CGFloat(contentLayout.introColumnWidth), alignment: .leading)
    readyPanel
        .frame(width: CGFloat(contentLayout.actionColumnWidth))
}
.startupContentWidth(contentLayout)
```

- [ ] **Step 4: Update saved-cameras two-column layout**

In `StartupSavedCamerasView`, replace the non-compact `HStack` with:

```swift
HStack(alignment: .top, spacing: CGFloat(contentLayout.columnSpacing)) {
    intro
        .frame(width: CGFloat(contentLayout.introColumnWidth), alignment: .leading)
    cameraRows
        .frame(width: CGFloat(contentLayout.actionColumnWidth))
}
.startupContentWidth(contentLayout)
```

- [ ] **Step 5: Update discovery two-column layout**

In `StartupDiscoveryView`, replace the non-compact `HStack` with:

```swift
HStack(alignment: .top, spacing: CGFloat(contentLayout.columnSpacing)) {
    discoveryIntro
        .frame(width: CGFloat(contentLayout.introColumnWidth), alignment: .leading)
    discoveryControls
        .frame(width: CGFloat(contentLayout.actionColumnWidth))
}
.startupContentWidth(contentLayout)
```

- [ ] **Step 6: Center capped wide content without shifting compact layouts**

On the `Group` containing the selected startup state inside `LinkExperience.body`, add:

```swift
.frame(maxWidth: .infinity, alignment: contentLayout.profile == .wideLandscape ? .center : .leading)
```

Expected result: wide/iPad layouts do not stretch the two columns endlessly; phone landscape remains
leading-aligned within the safe content area.

- [ ] **Step 7: Build the iOS app**

Run:

```sh
just native-check
```

Expected: PASS, including Swift tests and iOS simulator build.

- [ ] **Step 8: Commit SwiftUI container**

Run:

```sh
git add ios/Runner/NativeAppRoot.swift
git commit -m "fix: adapt startup views to safe content width"
```

## Task 3: Startup Content Priority Rules

**Files:**

- Modify: `ios/Runner/NativeAppRoot.swift`
- Test: existing build through `just native-check`

- [ ] **Step 1: Hide optional discovery footer when space is tight**

In `StartupDiscoveryView.discoveryIntro`, wrap the footer link `HStack` in:

```swift
if contentLayout.showFooterLinks {
    HStack(spacing: 8) {
        Text("v0.1")
        Text("·")
        Button("Tutorial") { model.showPairingHelp() }
        Text("·")
        Button("Privacy") {}
        Text("·")
        Button("Terms") {}
    }
    .buttonStyle(.plain)
    .font(.system(size: 11, weight: .regular, design: .rounded))
    .foregroundStyle(StartupColors.muted)
}
```

- [ ] **Step 2: Size the discovery scope from the intro column**

Replace the fixed scope frame in `StartupDiscoveryView.discoveryIntro` with:

```swift
if contentLayout.showSecondaryVisuals {
    let scopeWidth = min(210, max(160, contentLayout.introColumnWidth * 0.70))
    StartupDiscoveryScope(
        cameras: model.discoveredCameras,
        selectedCamera: model.selectedDiscoveredCamera
    )
    .frame(width: CGFloat(scopeWidth), height: CGFloat(scopeWidth * 0.90))
}
```

- [ ] **Step 3: Improve saved-camera row text compression**

In `StartupSavedCameraRow`, add `lineLimit` and `minimumScaleFactor` to the display name and
subtitle text:

```swift
Text(onlineCamera?.displayName ?? camera.displayName)
    .font(.system(size: 15, weight: .semibold, design: .rounded))
    .foregroundStyle(StartupColors.ink)
    .lineLimit(1)
    .minimumScaleFactor(0.86)
Text(subtitle)
    .font(.system(size: 12, weight: .regular, design: .rounded))
    .foregroundStyle(StartupColors.muted)
    .lineLimit(1)
    .minimumScaleFactor(0.82)
```

- [ ] **Step 4: Build the iOS app**

Run:

```sh
just native-check
```

Expected: PASS.

- [ ] **Step 5: Commit priority rules**

Run:

```sh
git add ios/Runner/NativeAppRoot.swift
git commit -m "fix: prioritize startup controls on compact widths"
```

## Task 4: Plan Checklist And Full Verification

**Files:**

- Modify: `docs/design/plans/2026-06-20-wireframe-kit-app.md`

- [ ] **Step 1: Mark implemented Stage 0.5 items**

Update Stage 0.5 in `docs/design/plans/2026-06-20-wireframe-kit-app.md`:

```markdown
- [x] Replace startup fixed Penpot-width compositions with adaptive SwiftUI columns backed by pure
  `OpenZCineCore` layout policies.
- [x] Add no-horizontal-overflow tests for small notched landscape phone, regular landscape phone,
  large Pro Max landscape, and wide iPad/full-width profiles.
- [x] Keep backgrounds full-bleed while all text, cards, buttons, and status pills remain inside the
  safe content bounds.
- [x] Apply the same startup layout container to discovery, saved-camera, and camera-ready states.
- [ ] Define priority overflow rules for live-view assist tools and camera-value strip before the
  live monitor is treated as polished.
```

The live-view overflow item remains unchecked because this plan scopes implementation to startup.

- [ ] **Step 2: Run repository verification**

Run:

```sh
just swift-format
git diff --check
just check
```

Expected: PASS. If SwiftPM fails in the sandbox because it cannot write `~/.cache/clang`, rerun
`just check` with approved unsandboxed execution and record that the sandbox failure was cache-write
related.

- [ ] **Step 3: Commit plan checklist**

Run:

```sh
git add docs/design/plans/2026-06-20-wireframe-kit-app.md
git commit -m "docs: track responsive startup layout progress"
```

## Self-Review

- Spec coverage: covers adaptive startup columns, safe content bounds, scoped footer/visual priority,
  core layout tests, and plan tracking. Live-view overflow is intentionally left as the next
  unchecked Stage 0.5 item.
- Placeholder scan: no `TBD`, `TODO`, or unspecified implementation steps.
- Type consistency: plan uses `StartupLayoutProfile`, `StartupContentMode`, and
  `StartupContentLayout.fit(viewportWidth:viewportHeight:safeArea:)` consistently across tests,
  implementation, and SwiftUI wiring.
