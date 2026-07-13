# Collaborative flow docs

Node-based flowcharts of the app — the shared design surface between the operator (you), Claude
Code, and Codex. Everything lives in git; no external board.

## Two live surfaces per flow

| Surface | File | Who edits | What it holds |
| ------- | ---- | --------- | ------------- |
| Diagram | `docs/flows/<flow>.excalidraw` | You visually, agents as JSON | Nodes, edges, layout |
| Node cards | `docs/flows/<flow>.md` | Both, as text | Status / Screen / Code / Detail / 📝 Notes |

**Editing the diagrams — ExcaliDash (preferred):** a self-hosted
[ExcaliDash](https://github.com/ZimengXiong/ExcaliDash) runs locally with real-time
collaboration — you edit in the browser at <http://localhost:6767> while agents read/write the
same drawings through its localhost API. All drawings live in the **OpenZCine Flows**
collection; drawing name == file stem.

```sh
just flows-up            # start the server (Docker, localhost-only, auth disabled)
just flows-pull          # ExcaliDash -> git files (snapshot before committing)
just flows-verify <flow> # print a drawing's live element count + version + node ids
just flows-push [flow]   # FULL REPLACE from git file — resets layout, deliberate regen only
just flows-down          # stop the server
```

**ExcaliDash is the live source of truth.** Agents `just flows-pull` (or GET the drawing)
BEFORE reading or editing any diagram — never trust the checked-out file to be current — and
verify after every write. The git files are commit-time snapshots: `just flows-pull` + commit
after a design session. Compose file: `infra/excalidash/docker-compose.yml`; sync script:
`scripts/flows-excalidash-sync.mjs`; merge library: `scripts/flows-dash.mjs`.

**How agents write without clobbering you (diff/merge).** Incremental edits go through
`pushMerged(flow, mutate)` in `scripts/flows-dash.mjs`: it pulls the LIVE scene + its
`version`, applies the change to only the specific elements involved (every element you moved
stays put), and PUTs with the version. If you saved in between, the server returns **409
VERSION_CONFLICT** and the agent re-pulls and re-applies (rebases) — your committed edits are
never overwritten. `just flows-push` is the opposite: a full-scene replace that resets layout,
reserved for deliberate regeneration.

**Residual limit — the open-tab autosave race.** ExcaliDash persistence is whole-scene
last-write-wins, and the browser's live edits reach the server only over its collab socket, not
the REST API an agent uses. So a tab you're *actively editing* can still re-stamp its whole
scene over an agent's REST write on its next autosave (its scene doesn't include the agent's
elements). The version guard means nobody loses **committed** work, but for the same drawing in
the same moment, coordinate: when you ask an agent to edit a diagram, pause your own edits on
that one drawing for the second the merge takes, then refresh to see the result. (A true
live-collab agent — joining the socket room and emitting `element-update` so your open tab
merges the change live — is a possible future enhancement; it needs a small socket.io-client
tool. Ask if you want it built.)

**Editing without the server:** open the `.excalidraw` file at
[excalidraw.com](https://excalidraw.com) (File → Open, then save back over the same file), or
use an Excalidraw extension inside VS Code or another editor. Agents can also edit the JSON directly —
element positions and styling are preserved; arrows are bound to node rectangles so
rearranging keeps edges attached.

Note: excalidraw.com **share links** (`#json=…`) are immutable snapshots — they can't be
updated in place by anyone. The file in git (mirrored in ExcaliDash) is the live document;
never trade share links.

## Conventions

- **Node IDs are permanent and readable.** Full names, no cryptic abbreviations
  (`RECONNECT-01`, not `RECON-01`); failures are `<PREFIX>-FAILED-NN`, open questions
  `<PREFIX>-QUESTION-NN`. Never renumber (`JOIN-03` stays `JOIN-03` even if `JOIN-02` dies);
  new nodes take the next free number.
- `Status:` on each card — `shipped` · `proposed` · `needs-work` · `question`
- 📝 **Notes:** your scratchpad on each card — write anything; agents read the diff and act.
- Keep the node set in sync: a node added on the canvas gets a card, and vice versa.

## Flows

| Flow | Diagram | Node cards |
| ---- | ------- | ---------- |
| Full app overview | `full-app-overview.excalidraw` | (zones only — see per-flow docs) |
| First pair — camera AP | `camera-ap-join.excalidraw` | [camera-ap-join.md](./camera-ap-join.md) |
| Startup & home | `startup-home.excalidraw` | [startup-home.md](./startup-home.md) |
| Monitor — live view & controls | `monitor.excalidraw` | [monitor.md](./monitor.md) |
| Media browsing | `media-browsing.excalidraw` | [media-browsing.md](./media-browsing.md) |
| Media playback — player & photo viewer | `media-playback.excalidraw` | [media-playback.md](./media-playback.md) |
| Media delivery — Share & Frame.io | `media-delivery-frameio.excalidraw` | [media-delivery-frameio.md](./media-delivery-frameio.md) |
| Internet hop — RED LUT download | `internet-hop.excalidraw` | [internet-hop.md](./internet-hop.md) |

The `.excalidraw` diagrams were scaffolded from the markdown graphs (auto-layout, snake grid) —
rearrange freely; your layout wins from then on. The markdown files keep a Mermaid block as a
quick inline preview, but the `.excalidraw` file is the canonical diagram.

**Related:** Frame.io delivery reuses hop machinery from the internet-hop flow but adds an
active `waitForInternetPath` wait — see the delivery and browsing flows.

Claude Code and Codex must follow the live-source, incremental-merge, and verification rules above.
