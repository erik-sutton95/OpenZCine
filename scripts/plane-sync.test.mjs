import assert from "node:assert/strict";
import test from "node:test";
import config from "../.github/plane-sync.json" with { type: "json" };
import { checksSuccessful, PlaneClient } from "./plane-sync/clients.mjs";
import {
  desiredIssueState,
  desiredPullRequestState,
  escapeHtml,
  extractPlaneKeys,
  primaryKeyForPullRequest,
  primaryPlaneKey,
  renderGitHubDescription,
  sourceId,
  validatePullRequestContract
} from "./plane-sync/domain.mjs";
import { reconcilePullRequests, SyncEngine } from "./plane-sync/reconcile.mjs";

const repository = "erik-sutton95/OpenZCine";

function pullRequest(overrides = {}) {
  return {
    number: 42,
    title: "Polish controls",
    body: "Plane: OZC-47\n\nImprove the controls.",
    state: "open",
    merged: false,
    merged_at: null,
    merge_commit_sha: null,
    updated_at: new Date().toISOString(),
    author_association: "OWNER",
    html_url: "https://github.com/erik-sutton95/OpenZCine/pull/42",
    user: { login: "erik-sutton95" },
    head: { ref: "codex/feat/ozc-47-sync", repo: { full_name: repository } },
    labels: [],
    ...overrides
  };
}

class FakePlane {
  constructor(items = []) {
    this.items = structuredClone(items);
    this.creates = [];
    this.updates = [];
  }

  async listWorkItems() {
    return structuredClone(this.items);
  }

  async createWorkItem(fields) {
    this.creates.push(fields);
    const item = { id: `new-${this.creates.length}`, sequence_id: 100, ...fields };
    this.items.push(item);
    return structuredClone(item);
  }

  async updateWorkItem(id, fields) {
    this.updates.push({ id, fields });
    Object.assign(this.items.find((item) => item.id === id), fields);
  }
}

test("extracts, normalizes, and de-duplicates Plane keys", () => {
  assert.deepEqual(extractPlaneKeys("ozc-47 and OZC-47", "OZC-2"), ["OZC-2", "OZC-47"]);
  assert.equal(primaryPlaneKey("Text\nPlane: ozc-47\nMore"), "OZC-47");
  assert.equal(primaryPlaneKey("Related: OZC-47"), null);
  assert.equal(primaryPlaneKey("Plane: OZC-47\nPlane: OZC-47"), null);
});

test("does not infer a primary key when metadata contains several keys", () => {
  const pr = pullRequest({
    body: "No primary field. Related OZC-1 and OZC-2.",
    title: "Fix OZC-1",
    head: { ref: "codex/fix/ozc-2", repo: { full_name: repository } }
  });
  assert.equal(primaryKeyForPullRequest(pr), null);
});

test("requires an exact Plane field for internal implementation PRs", () => {
  assert.equal(validatePullRequestContract(pullRequest(), repository).valid, true);
  const invalid = validatePullRequestContract(pullRequest({ body: "OZC-47" }), repository);
  assert.equal(invalid.valid, false);
  assert.match(invalid.reason, /Plane: OZC-###/);

  const external = pullRequest({
    body: "",
    head: { ref: "feature", repo: { full_name: "contributor/fork" } }
  });
  assert.equal(validatePullRequestContract(external, repository).valid, true);
});

test("maps PR and issue evidence to lifecycle states", () => {
  assert.equal(desiredPullRequestState(pullRequest(), config), config.states.inProgress);
  assert.equal(
    desiredPullRequestState(
      pullRequest({ merged: true, state: "closed", merge_commit_sha: "abc" }),
      config,
      { verified: false }
    ),
    null
  );
  assert.equal(
    desiredPullRequestState(
      pullRequest({ merged: true, state: "closed", merge_commit_sha: "abc" }),
      config,
      { verified: true }
    ),
    config.states.done
  );
  assert.equal(
    desiredPullRequestState(
      pullRequest({ merged_at: "2026-07-12T08:00:00Z", state: "closed" }),
      config,
      { verified: true }
    ),
    config.states.done
  );
  assert.equal(
    desiredPullRequestState(
      pullRequest({ state: "closed", labels: [{ name: config.labels.cancelled }] }),
      config
    ),
    config.states.cancelled
  );
  assert.equal(desiredIssueState({ state: "open", labels: [] }, config), config.states.backlog);
  assert.equal(
    desiredIssueState({ state: "open", labels: [{ name: config.labels.ready }] }, config),
    config.states.todo
  );
});

test("escapes untrusted GitHub metadata in generated descriptions", () => {
  const html = renderGitHubDescription({
    repository,
    kind: "pull_request",
    number: 9,
    title: "<script>alert(1)</script>",
    body: "Use & verify",
    author: 'bad"actor',
    url: "https://example.test/pull/9",
    branch: "feature/<unsafe>",
    files: ["ios/Runner/Foo.swift", "docs/README.md"]
  });
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /ios, docs|docs, ios/);
  assert.match(html, new RegExp(sourceId(repository, "pull_request", 9)));
});

test("updates an existing planned item and preserves its human description", async () => {
  const plane = new FakePlane([
    {
      id: "item-47",
      sequence_id: 47,
      name: "Automation",
      state: config.states.todo,
      description_html: "<p>Human acceptance criteria.</p>"
    }
  ]);
  const engine = new SyncEngine(config, plane, { apply: true });
  await engine.syncPullRequest(repository, pullRequest());
  assert.equal(plane.updates.length, 1);
  assert.equal(plane.updates[0].fields.state, config.states.inProgress);
  assert.match(plane.updates[0].fields.description_html, /Human acceptance criteria/);
  assert.match(plane.updates[0].fields.description_html, /GitHub source ID/);
});

test("repeated sync is idempotent", async () => {
  const plane = new FakePlane([
    {
      id: "item-47",
      sequence_id: 47,
      state: config.states.todo,
      description_html: ""
    }
  ]);
  const first = new SyncEngine(config, plane, { apply: true });
  await first.syncPullRequest(repository, pullRequest());
  const second = new SyncEngine(config, plane, { apply: true });
  await second.syncPullRequest(repository, pullRequest());
  assert.equal(plane.updates.length, 1);
  assert.equal(second.summary().unchanged, 1);
});

test("refreshes synchronized evidence without replacing human context", async () => {
  const plane = new FakePlane([
    {
      id: "item-47",
      sequence_id: 47,
      state: config.states.todo,
      description_html: "<p>Human acceptance criteria.</p>"
    }
  ]);
  const first = new SyncEngine(config, plane, { apply: true });
  await first.syncPullRequest(repository, pullRequest());
  const second = new SyncEngine(config, plane, { apply: true });
  await second.syncPullRequest(repository, pullRequest({ title: "Polished controls" }));
  assert.equal(plane.updates.length, 2);
  assert.match(plane.updates[1].fields.description_html, /Human acceptance criteria/);
  assert.match(plane.updates[1].fields.description_html, /Polished controls/);
  assert.doesNotMatch(plane.updates[1].fields.description_html, /<h2>Polish controls<\/h2>/);
});

test("dry-run backfill proposes one create and performs no mutation", async () => {
  const plane = new FakePlane([]);
  const engine = new SyncEngine(config, plane, { apply: false });
  const external = pullRequest({
    body: "",
    title: "External layout fix",
    head: { ref: "layout-fix", repo: { full_name: "contributor/fork" } },
    labels: [{ name: config.labels.syncApproved }]
  });
  await engine.syncPullRequest(repository, external, { allowCreate: true, backfilled: true });
  assert.equal(plane.creates.length, 0);
  assert.equal(engine.summary().create, 1);
  assert.equal(engine.summary().unchanged, 0);
});

test("terminal Plane states are not reopened by inferred PR state", async () => {
  const plane = new FakePlane([
    { id: "item-47", sequence_id: 47, state: config.states.done, description_html: "" }
  ]);
  const engine = new SyncEngine(config, plane, { apply: true });
  await engine.syncPullRequest(repository, pullRequest());
  assert.equal(plane.updates.length, 0);
  assert.equal(engine.summary().conflict, 1);
});

test("scheduled reconciliation skips unapproved external PRs", async () => {
  const plane = new FakePlane([]);
  const github = {
    async listPullRequests() {
      return [
        pullRequest({
          body: "",
          author_association: "NONE",
          head: { ref: "feature", repo: { full_name: "contributor/fork" } }
        })
      ];
    },
    async listPullRequestFiles() {
      throw new Error("files should not be fetched");
    }
  };
  const engine = await reconcilePullRequests({
    config,
    planeClient: plane,
    githubClient: github,
    repository,
    lookbackDays: 30,
    apply: false
  });
  assert.equal(engine.summary().skipped, 1);
});

test("Plane client follows cursor pagination without exposing the API key", async () => {
  const calls = [];
  const fetchImplementation = async (url, options) => {
    calls.push({ url: String(url), options });
    const second = String(url).includes("cursor=next");
    return new Response(
      JSON.stringify(
        second
          ? { results: [{ id: "2" }], next_page_results: false }
          : { results: [{ id: "1" }], next_page_results: true, next_cursor: "next" }
      ),
      { status: 200 }
    );
  };
  const client = new PlaneClient(config, "secret-token", fetchImplementation);
  assert.deepEqual(await client.listWorkItems(), [{ id: "1" }, { id: "2" }]);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].options.headers["X-API-Key"], "secret-token");

  const failing = new PlaneClient(config, "secret-token", async () =>
    new Response("nope", { status: 401 })
  );
  await assert.rejects(() => failing.listWorkItems(), (error) => {
    assert.doesNotMatch(error.message, /secret-token/);
    return true;
  });
});

test("requires every check run to finish successfully", () => {
  assert.equal(
    checksSuccessful({ check_runs: [{ status: "completed", conclusion: "success" }] }),
    true
  );
  assert.equal(
    checksSuccessful({ check_runs: [{ status: "completed", conclusion: "failure" }] }),
    false
  );
  assert.equal(checksSuccessful({ check_runs: [] }), false);
});
