#!/usr/bin/env node
// Sync docs/flows/*.excalidraw <-> a local ExcaliDash instance (auth-disabled, localhost).
//
//   node scripts/flows-excalidash-sync.mjs pull            # ExcaliDash -> git files (snapshot)
//   node scripts/flows-excalidash-sync.mjs push [flow]     # git file -> ExcaliDash (FULL REPLACE)
//   node scripts/flows-excalidash-sync.mjs verify <flow>   # print server element count + version
//
// FULL-REPLACE WARNING: `push` overwrites the whole scene and RESETS ANY LAYOUT the user
// moved in the browser. Use it only for a deliberate regeneration. For incremental edits an
// agent should use pushMerged() from flows-dash.mjs, which preserves untouched positions and
// rebases on conflict. `push` is still version-aware: it refuses (409) if the drawing changed
// since it was pulled — re-pull first.
//
// The ExcaliDash collection "OpenZCine Flows" mirrors docs/flows/: drawing name == file stem.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { api, collectionId, listDrawings, pullDrawing } from "./flows-dash.mjs";

const FLOWS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "docs", "flows");

async function push(only) {
  const cid = await collectionId();
  const { drawings } = await listDrawings();
  const files = readdirSync(FLOWS_DIR)
    .filter((f) => f.endsWith(".excalidraw"))
    .filter((f) => !only || f === `${only}.excalidraw`);
  for (const file of files) {
    const name = file.replace(/\.excalidraw$/, "");
    const doc = JSON.parse(readFileSync(join(FLOWS_DIR, file), "utf8"));
    const existing = drawings.find((d) => d.name === name);
    if (existing) {
      // Version-aware: fetch current version so a stale push 409s instead of clobbering.
      const live = await pullDrawing(name);
      await api(`/drawings/${existing.id}`, {
        method: "PUT",
        body: {
          name,
          collectionId: cid,
          elements: doc.elements ?? [],
          appState: doc.appState ?? {},
          files: doc.files ?? {},
          version: live.version,
        },
      });
      console.log(`replaced ${name} (${(doc.elements ?? []).length} elements)`);
    } else {
      await api("/drawings", {
        method: "POST",
        body: {
          name,
          collectionId: cid,
          elements: doc.elements ?? [],
          appState: doc.appState ?? {},
          files: doc.files ?? {},
        },
      });
      console.log(`created  ${name} (${(doc.elements ?? []).length} elements)`);
    }
  }
}

async function pull() {
  const { drawings } = await listDrawings();
  for (const summary of drawings) {
    const d = await api(`/drawings/${summary.id}`);
    const doc = {
      type: "excalidraw",
      version: 2,
      source: "https://excalidraw.com",
      elements: d.elements ?? [],
      appState: { gridSize: null, viewBackgroundColor: "#ffffff", ...(d.appState ?? {}) },
      files: d.files ?? {},
    };
    writeFileSync(join(FLOWS_DIR, `${d.name}.excalidraw`), JSON.stringify(doc, null, 1));
    console.log(`pulled   ${d.name} (${doc.elements.length} elements)`);
  }
}

async function verify(flow) {
  const d = await pullDrawing(flow);
  if (!d) {
    console.error(`no drawing named "${flow}"`);
    process.exit(1);
  }
  const rects = d.elements.filter((e) => e.type === "rectangle").map((e) => e.id);
  console.log(`${flow}: ${d.elements.length} elements, version ${d.version}, ${rects.length} nodes`);
  console.log(rects.sort().join(", "));
}

const cmd = process.argv[2];
if (cmd === "pull") await pull();
else if (cmd === "push") await push(process.argv[3]);
else if (cmd === "verify") await verify(process.argv[3]);
else {
  console.error("usage: flows-excalidash-sync.mjs pull | push [flow] | verify <flow>");
  process.exit(1);
}
