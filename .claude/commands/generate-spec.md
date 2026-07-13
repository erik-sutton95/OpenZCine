---
description: Extract a feature spec from docs/PRD.md into docs/specs/<feature>.md
---

# Generate Spec

Extract a detailed feature specification from `docs/PRD.md` (or the feature described in this
conversation) and write it to `docs/specs/<feature>.md`, where `<feature>` is a short kebab-case
name for the feature.

The spec must include:

- **Goal** — single sentence
- **Background** — relevant context from the PRD
- **Scope** — files and modules affected; explicitly note whether changes touch `Sources/OpenZCineCore`
  or `ios/Runner` or both
- **Design** — data model, API surface, UI sketch (text description)
- **Edge cases and constraints**
- **Acceptance criteria** — testable statements

Create `docs/specs/` if it does not exist.
