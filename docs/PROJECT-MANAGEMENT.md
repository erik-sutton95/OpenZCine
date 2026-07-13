# Project management — Plane

OpenZCine tracks work in a self-hosted [Plane](https://plane.so) board. This doc is the contract
that lets agents keep the board in sync **without being asked** — read it before touching Plane.

`docs/ROADMAP.md` remains the human-readable source of truth for *what the milestones are*. Plane
is the live *status mirror* of that roadmap. When they disagree, the roadmap wins for scope; Plane
wins for current status.

## Board identity

| Thing | Value |
| --- | --- |
| Workspace slug | `openzcine` |
| Base URL | `https://plane.opencapture.org` |
| Project | **OpenZCine** — identifier `OZC` |
| Project id | `8722f3e3-c246-44fb-9e33-a8ed36bbd88e` |

Credentials live in the local Plane MCP config / `$PLANE_API_KEY` — **never commit the API key.**

State UUIDs (project-scoped, stable):

| State | Group | UUID |
| --- | --- | --- |
| Backlog | backlog | `e3566082-f1c5-4225-a530-0ceb2b90b756` |
| Todo | unstarted | `fcc6ee6c-7eeb-4f80-bfef-5e90b30cc617` |
| In Progress | started | `7c52c981-4129-4008-9fe2-02744b0d815f` |
| Done | completed | `1b78d583-a523-4fe0-b0d3-1bea8cc2cd44` |
| Cancelled | cancelled | `cf3261f4-a752-47c9-a010-b51e5df88bc8` |

## Model: epics = phases, work items = deliverables

This instance's stable API does **not** expose the Epic work-item type (see Gotchas). So an "epic"
is modelled as a **parent work item**, one per roadmap phase, with each deliverable a **child work
item** (`parent` set to the phase). This gives the phase → deliverables hierarchy without depending
on the unavailable Epics feature. If the instance ever gains the Epics feature, phases can be
promoted to real epics later.

The board was initially seeded from `docs/ROADMAP.md`. Treat the roadmap and live board as the
current sources; do not rely on a hard-coded phase-status snapshot in this document.

## Lifecycle contract

Agents already read `AGENTS.md` every session, which points here. Follow this as part of normal work
— no separate "update Plane" step needs to be requested:

1. **Capturing possible work** → create it in **Backlog**.
2. **Accepting and preparing work** → move it to **Todo** once it is actionable and ready to start.
3. **Starting work on a deliverable** → set its work item to **In Progress**
   (`update_work_item` → `state = <In Progress uuid>`). If no work item exists for what you're
   doing, `create_work_item` under the right phase parent first.
4. **Opening or updating its PR** → keep it **In Progress** throughout review. Local verification
   means the implementation is review-ready; it does not mean the deliverable is Done.
5. **Finishing a deliverable** → only after its PR is merged to the default branch and the required
   default-branch CI run succeeds, set it to **Done**. The completion workflow normally does this.
6. **New scope discovered** → `create_work_item` with `parent` = the owning phase, state Backlog or
   Todo. Also add it to `docs/ROADMAP.md` if it's a real deliverable, not a one-off.
7. **A phase completes** → set the phase parent to Done and update its `**Status:**` line in
   `docs/ROADMAP.md` in the same change.
8. **Abandoned work** → explicitly move it to **Cancelled**, never delete it. A closed-unmerged PR
   only triggers cancellation when a maintainer applies `plane-cancelled`.

Done and Cancelled are sticky terminal states: automation must never reopen or downgrade them. A
maintainer may correct a terminal state manually when the evidence was wrong.

Keep the roadmap and the board moving together in the same commit/session — that's what keeps this
"nearly fully automated" instead of drifting.

## GitHub automation

Every internal implementation PR carries exactly one line in its body:

```text
Plane: OZC-123
```

That key identifies the primary deliverable. Mentioning other Plane keys elsewhere is fine, but the
`Plane:` field must remain singular and unambiguous. The workflows enforce this contract and use
only GitHub metadata; they never execute or check out a contributor's PR branch.

The synchronization paths are:

- `Plane PR sync` moves trusted open work to In Progress and refreshes a deterministic GitHub
  evidence block in the description.
- `Plane completion sync` moves merged work to Done only after successful CI on `main`.
- `Plane reconciliation` checks the last 30 days nightly. It reports proposed changes by default;
  set `PLANE_SYNC_APPLY=true` only after reviewing dry-run output.
- Issues enter Backlog, or Todo when labelled `ready`. Untrusted external issues and PRs require a
  maintainer to apply `plane-sync` before any Plane write.

Scheduled backfill may create a missing item directly in In Progress or Done when GitHub supplies
that evidence. This is provenance-based recovery, not a fabricated history of intermediate states.
The description includes the stable marker `github:<owner>/<repo>:<kind>:<number>`, making retries
idempotent.

### Activation

Create a protected GitHub environment named `plane-sync`, add a dedicated least-privilege Plane API
key as its `PLANE_SYNC_API_KEY` secret, then set the repository variable
`PLANE_SYNC_ENABLED=true`. Leave `PLANE_SYNC_APPLY` unset or `false` while validating nightly
reports; the event and completion workflows still apply their narrowly evidenced transitions.
Never place the key in repository variables, workflow YAML, logs, or PR configuration.

## Tooling — what actually works on this instance

Prefer the Plane MCP tools. This self-hosted instance serves the classic `/api/v1` API
(projects · issues · states · labels) but **not** the newer work-item-type / epic endpoints, so some
MCP tools 404. Verified on 2026-07-11:

| Works (MCP) | Broken here (404) — don't use |
| --- | --- |
| `create_work_item`, `update_work_item` | `list_projects` |
| `list_work_items`, `list_states` | `list_work_item_types`, `resolve_work_item_type` |
| `create_project`, `list_labels`, `create_label`, `get_me` | the Epic-type / work-item-type family |

**Read gotcha:** `list_work_items` uses sparse fieldsets. Any field you don't name comes back `null`
— so to get a UUID for a follow-up `update_work_item`, you **must** request `id` explicitly:
`fields = "id,sequence_id,name,state"`.

**REST fallback** (when an MCP tool 404s, or for bulk work): the raw API is reliable. Use
`/usr/bin/curl` (Python's `urllib` fails TLS verification in this env; `curl` is fine):

```sh
curl -s -H "X-API-Key: $PLANE_API_KEY" \
  "https://plane.opencapture.org/api/v1/workspaces/openzcine/projects/8722f3e3-c246-44fb-9e33-a8ed36bbd88e/issues/"
```

`POST` the same `issues/` endpoint with `{"name","state","parent","priority","description_html"}` to
create. The one-shot seed script pattern lives in the scratchpad from the initial setup; re-derive
from this table rather than hunting for it.
