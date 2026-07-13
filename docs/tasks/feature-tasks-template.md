# Tasks: [Feature Name]

<!-- Copy this template for each feature's task breakdown.
    Save as docs/tasks/<feature-slug>-tasks.md
    Link to the corresponding spec: docs/specs/<feature-slug>.md -->

## Progress

- **Total steps:** [N]
- **Completed:** [0] / [N]
- **Status:** Not Started | In Progress | Blocked | Complete

## Steps

### Step 1: [Step Name]

**Goal:** [One sentence describing what this step achieves.]

**Subtasks:**

- [ ] 1.1 — [Subtask description]
- [ ] 1.2 — [Subtask description]
- [ ] 1.3 — [Subtask description]

**Implementation Notes:**

<!-- Key decisions, constraints, or patterns to follow for this step. -->

**Done when:**

- [ ] `just native-check` passes
- [ ] [Specific acceptance criterion met]

---

### Step 2: [Step Name]

**Goal:** [One sentence.]

**Subtasks:**

- [ ] 2.1 — [Subtask description]
- [ ] 2.2 — [Subtask description]

**Implementation Notes:**

<!-- Notes here -->

**Done when:**

- [ ] `just native-check` passes
- [ ] [Specific acceptance criterion met]

---

### Step 3: [Step Name]

**Goal:** [One sentence.]

**Subtasks:**

- [ ] 3.1 — [Subtask description]
- [ ] 3.2 — [Subtask description]

**Implementation Notes:**

<!-- Notes here -->

**Done when:**

- [ ] `just native-check` passes
- [ ] [Specific acceptance criterion met]

---

## Implementation Notes

<!-- Cross-cutting concerns, patterns used, and decisions that apply to the whole feature. -->

- Follows: `docs/specs/[feature-slug].md`
- Core changes land in `Sources/OpenZCineCore/`; shell changes land in `ios/Runner/`
- All new tests use Swift Testing (`import Testing`)
- Commit each step atomically with a `feat:` or `fix:` Conventional Commit message

## Changes Log

| Date | Step | Description |
| --- | --- | --- |
| YYYY-MM-DD | Step 1 | [Brief description of what changed] |
| YYYY-MM-DD | Step 2 | [Brief description] |
