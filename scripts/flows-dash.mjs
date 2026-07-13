// Shared ExcaliDash client for the OpenZCine flow diagrams.
//
// Provides version-aware, element-level merge so an agent and a human can edit the same
// drawing without clobbering each other:
//
//   pushMerged(flow, (elements) => { ...mutate in place... })
//
// pulls the LIVE scene (+ its version), applies your mutation to a fresh copy of the
// server's elements — so every element you don't touch keeps the user's latest position —
// then PUTs with the version. If the user saved in between, the server 409s and we re-pull
// and re-apply (rebase), never overwrite.
//
// Full-file replace (`push`) is intentionally destructive and resets layout — use it only
// for a deliberate re-generation, never for an incremental change.

const BASE = process.env.EXCALIDASH_URL ?? "http://localhost:6767/api";
const COLLECTION = "OpenZCine Flows";
const MAX_REBASE = 4;

let csrf = null;

async function getCsrf() {
  if (csrf) return csrf;
  const res = await fetch(`${BASE}/csrf-token`);
  const cookie = (res.headers.get("set-cookie") ?? "").split(";")[0];
  const { token } = await res.json();
  csrf = { token, cookie };
  return csrf;
}

export async function api(path, { method = "GET", body } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (method !== "GET") {
    const { token, cookie } = await getCsrf();
    headers["x-csrf-token"] = token;
    headers.Cookie = cookie;
    headers.Origin = BASE.replace(/\/api$/, "");
  }
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const err = new Error(`${method} ${path} -> ${res.status}: ${text}`);
    err.status = res.status;
    err.body = json;
    throw err;
  }
  return json;
}

export async function collectionId() {
  const result = await api("/collections");
  const list = Array.isArray(result) ? result : result.collections;
  const existing = list.find((c) => c.name === COLLECTION);
  if (existing) return existing.id;
  const created = await api("/collections", { method: "POST", body: { name: COLLECTION } });
  return created.id ?? created.collection?.id;
}

export async function listDrawings() {
  const cid = await collectionId();
  const result = await api(`/drawings?collectionId=${encodeURIComponent(cid)}`);
  const list = Array.isArray(result) ? result : result.drawings;
  return { cid, drawings: list };
}

// Full live drawing incl. version. Returns null if the named flow doesn't exist yet.
export async function pullDrawing(flow) {
  const { drawings } = await listDrawings();
  const summary = drawings.find((d) => d.name === flow);
  if (!summary) return null;
  const d = await api(`/drawings/${summary.id}`);
  return {
    id: d.id,
    version: d.version,
    name: d.name,
    elements: d.elements ?? [],
    appState: d.appState ?? {},
    files: d.files ?? {},
  };
}

// Element-level merge: mutate a fresh copy of the server's elements, push with version,
// rebase on 409. `mutate(elements, drawing)` edits the array in place (or returns a new one).
export async function pushMerged(flow, mutate) {
  for (let attempt = 1; attempt <= MAX_REBASE; attempt++) {
    const drawing = await pullDrawing(flow);
    if (!drawing) throw new Error(`No drawing named "${flow}" on the server (create it first).`);
    const elements = structuredClone(drawing.elements);
    const next = mutate(elements, drawing) ?? elements;
    try {
      const res = await api(`/drawings/${drawing.id}`, {
        method: "PUT",
        body: {
          elements: next,
          appState: drawing.appState,
          files: drawing.files,
          version: drawing.version,
        },
      });
      return { id: drawing.id, count: next.length, version: res.version };
    } catch (err) {
      if (err.status === 409 && attempt < MAX_REBASE) {
        // User saved between our pull and push — rebase onto their version and retry.
        continue;
      }
      throw err;
    }
  }
  throw new Error(`pushMerged("${flow}") gave up after ${MAX_REBASE} rebase attempts.`);
}

// Convenience: index the elements array by id.
export function byId(elements) {
  const m = new Map();
  for (const e of elements) m.set(e.id, e);
  return m;
}

// Convenience: remove an element and any text bound to it (containerId match).
export function removeNode(elements, id) {
  return elements.filter((e) => e.id !== id && e.containerId !== id);
}
