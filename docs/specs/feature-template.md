# Feature Spec: [Feature Name]

<!-- Copy this template for each new feature spec. Save as docs/specs/<feature-slug>.md -->

## Status

<!-- Draft | Review | Approved | In Progress | Complete | Deprecated -->
Draft

## Priority

<!-- P0 = critical / blocking milestone; P1 = high value, current cycle; P2 = future cycle -->
P1

## User Stories

<!-- Format: As a <role>, I want <goal>, so that <benefit>. -->

1. As a **camera operator**, I want [goal], so that [benefit].
2. As a **developer**, I want [goal], so that [benefit].

## Acceptance Criteria

<!-- Each criterion is independently testable. -->

- [ ] Criterion 1: [observable outcome + measurable threshold]
- [ ] Criterion 2: [observable outcome]
- [ ] Criterion 3: [error / edge case handled]

## Technical Design

### Overview

<!-- One paragraph describing the approach. -->

### Components Affected

<!-- List files / modules that will change or be created. -->

- `Sources/OpenZCineCore/` — [describe changes]
- `ios/Runner/` — [describe changes]
- `Tests/OpenZCineCoreTests/` — [new/updated tests]
- `ios/RunnerTests/` — [new/updated tests]

### Data Flow

<!-- Describe the data flow from camera to UI, or from UI action to camera. -->

### API / Interface Changes

```swift
// Describe any new or changed public types, protocols, or functions.
```

## Data Models

<!-- Describe any new or changed types. -->

```swift
// Example model definition
```

## Dependencies

<!-- List other features, specs, or external constraints this depends on. -->

- Depends on: [spec or feature slug]
- Blocks: [spec or feature slug]

## UI / UX References

<!-- Link to design files in docs/design/ or describe the layout. -->

- Design file: `docs/design/specs/[filename]` or `docs/design/plans/[filename]`
- Notes: [any layout or interaction notes]

## Edge Cases

<!-- What can go wrong? How is each case handled? -->

| Scenario | Expected Behavior |
| --- | --- |
| Camera disconnects mid-operation | Show error; transition to disconnected state |
| [Scenario 2] | [Expected behavior] |

## Testing Plan

### Unit Tests

- `OpenZCineCoreTests/` — test [protocol / state machine logic]
- `RunnerTests/` — test [view model logic]

### Integration Tests

- [Describe any UI-level or end-to-end tests required]

### Manual Verification

- [ ] Connect to a real Nikon ZR and verify [criterion 1]
- [ ] Simulate [error condition] and verify error UI

## Rollout

### Feature Flags

<!-- Does this need a feature flag? If so, describe the flag and the rollout plan. -->

- Flag name: `[flag-name]`
- Default: `disabled`
- Enable for: [internal testing / beta / general release]

## Open Questions

<!-- Questions that must be resolved before or during implementation. -->

1. [Question] — Owner: [name] — Due: [date]
2. [Question] — Owner: [name] — Due: [date]
