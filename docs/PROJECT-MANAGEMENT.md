# Project management — Kaneo

OpenZCine tracks work on a self-hosted [Kaneo](https://kaneo.app) board. This doc is the contract
that lets agents keep the board in sync **without being asked** — read it before touching the board.

`docs/ROADMAP.md` remains the human-readable source of truth for *what the milestones are*. Kaneo
is the live *status mirror* of that roadmap. When they disagree, the roadmap wins for scope; Kaneo
wins for current status.

## Board identity

| What | Value |
| --- | --- |
| Base URL | `https://kaneo.opencapture.org` |
| Workspace | `OpenCapture` |
| Project | `OpenZCine` (identifier `OPE`) |
| Public read-only view | `https://kaneo.opencapture.org/public-project/x8bqmvbho1am6f7ganbp72uq` |

Agent access is via the Kaneo MCP tools (device-auth flow; the cached token lives in local MCP
config — **never commit it**). Everything on the board, including task descriptions, is publicly
visible through the read-only view: write descriptions accordingly.

## Statuses

Valid task statuses: `to-do`, `in-progress`, `in-review`, `done`, `planned`, `archived`.

- `to-do` → `in-progress` when work starts; `in-review` while its PR is open; `done` only after
  merge and green default-branch CI.
- `planned` is the backlog for ideas and investigations (tag them with the `investigation` label);
  promote to `to-do` when scoped.
- `archived` is the explicit "abandoned" state — never infer cancellation from a closed PR.

## GitHub sync

The Kaneo GitHub App mirrors every task — including sub-tasks — into a GitHub issue at creation
time. Two things to know:

- The sync is **create-only**: editing a task in Kaneo does not update its issue, and deleting a
  Kaneo task **orphans** its issue (close it manually).
- Sub-tasks are ordinary tasks linked to a parent by a `subtask` relation; the MCP tools don't
  expose relations, so check the board before bulk-creating to avoid duplicates.

Ideas live in GitHub Discussions (Ideas & Feature Requests) and are mirrored onto the board as
`planned` + `investigation` tasks referencing the discussion number.

## Attachments

Task photos/attachments are stored in S3-compatible object storage (Backblaze B2). Uploads go
directly from the browser to the bucket via presigned URLs, so the bucket carries a CORS rule
allowing `PUT` from the Kaneo origin — note that B2's web console cannot create upload CORS
rules; they must be set with the `b2` CLI. Files are private: reads are served back through
Kaneo's authenticated API, so embedded images may not render for anonymous visitors on the
public board view.
