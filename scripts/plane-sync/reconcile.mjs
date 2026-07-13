import {
  appendSourceReference,
  createdWorkItemName,
  desiredIssueState,
  desiredPullRequestState,
  extractPlaneKeys,
  isTrustedPullRequest,
  labelsOf,
  primaryKeyForPullRequest,
  primaryPlaneKey,
  renderGitHubDescription,
  sequenceFromKey,
  sourceId
} from "./domain.mjs";
import { checksSuccessful } from "./clients.mjs";

function stateId(workItem) {
  return typeof workItem?.state === "string" ? workItem.state : workItem?.state?.id;
}

function operation(kind, details) {
  return { kind, ...details };
}

export class SyncEngine {
  constructor(config, planeClient, { apply = false } = {}) {
    this.config = config;
    this.plane = planeClient;
    this.apply = apply;
    this.workItems = null;
    this.operations = [];
  }

  async loadWorkItems({ refresh = false } = {}) {
    if (this.workItems && !refresh) return this.workItems;
    this.workItems = await this.plane.listWorkItems();
    return this.workItems;
  }

  async findBySequence(sequence) {
    const items = await this.loadWorkItems();
    return items.find((item) => Number(item.sequence_id) === Number(sequence)) ?? null;
  }

  async findBySource(sourceIdentifier) {
    const items = await this.loadWorkItems();
    return items.find((item) => String(item.description_html ?? "").includes(sourceIdentifier)) ?? null;
  }

  async resolveWorkItem({ key, sourceIdentifier, allowCreate, createFields }) {
    if (key) {
      const existing = await this.findBySequence(sequenceFromKey(key));
      if (!existing) {
        this.operations.push(operation("conflict", { key, reason: "Plane key does not exist" }));
        return null;
      }
      return existing;
    }

    const mapped = await this.findBySource(sourceIdentifier);
    if (mapped) return mapped;
    if (!allowCreate) {
      this.operations.push(
        operation("conflict", { source: sourceIdentifier, reason: "Missing primary Plane key" })
      );
      return null;
    }

    if (!this.apply) {
      const proposed = { id: null, sequence_id: null, _proposed: true, ...createFields };
      this.operations.push(operation("create", { source: sourceIdentifier, fields: createFields }));
      return proposed;
    }

    // Re-read immediately before POST so overlapping reconciliation runs recover by marker.
    const recovered = await this.loadWorkItems({ refresh: true });
    const duplicate = recovered.find((item) =>
      String(item.description_html ?? "").includes(sourceIdentifier)
    );
    if (duplicate) return duplicate;

    const created = await this.plane.createWorkItem(createFields);
    this.workItems.push(created);
    this.operations.push(
      operation("create", {
        source: sourceIdentifier,
        key: created?.sequence_id ? `OZC-${created.sequence_id}` : null
      })
    );
    return created;
  }

  async transition(workItem, desiredState, descriptionHtml, sourceIdentifier) {
    if (workItem?._proposed) return;
    if (!workItem || !desiredState) {
      this.operations.push(operation("unchanged", { source: sourceIdentifier, reason: "No transition" }));
      return;
    }

    const current = stateId(workItem);
    const terminal = [this.config.states.done, this.config.states.cancelled];
    if (terminal.includes(current) && current !== desiredState) {
      this.operations.push(
        operation("conflict", {
          key: workItem.sequence_id ? `OZC-${workItem.sequence_id}` : null,
          source: sourceIdentifier,
          reason: "Terminal Plane state is sticky"
        })
      );
      return;
    }

    const mergedDescription = appendSourceReference(
      workItem.description_html,
      descriptionHtml,
      sourceIdentifier
    );
    const fields = {};
    if (current !== desiredState) fields.state = desiredState;
    if (mergedDescription !== String(workItem.description_html ?? "")) {
      fields.description_html = mergedDescription;
    }

    if (Object.keys(fields).length === 0) {
      this.operations.push(
        operation("unchanged", {
          key: workItem.sequence_id ? `OZC-${workItem.sequence_id}` : null,
          source: sourceIdentifier
        })
      );
      return;
    }

    if (this.apply && workItem.id) await this.plane.updateWorkItem(workItem.id, fields);
    Object.assign(workItem, fields);
    this.operations.push(
      operation("update", {
        key: workItem.sequence_id ? `OZC-${workItem.sequence_id}` : null,
        source: sourceIdentifier,
        fields
      })
    );
  }

  async syncPullRequest(
    repository,
    pullRequest,
    { files = [], verified = false, allowCreate = false, backfilled = false } = {}
  ) {
    const primary = primaryKeyForPullRequest(pullRequest);
    const keys = extractPlaneKeys(
      pullRequest?.body,
      pullRequest?.title,
      pullRequest?.head?.ref
    );
    if (!primary && keys.length > 1) {
      this.operations.push(
        operation("conflict", {
          source: sourceId(repository, "pull_request", pullRequest.number),
          reason: `Multiple Plane keys: ${keys.join(", ")}`
        })
      );
      return;
    }

    const sourceIdentifier = sourceId(repository, "pull_request", pullRequest.number);
    const desiredState = desiredPullRequestState(pullRequest, this.config, { verified });
    const description = renderGitHubDescription({
      repository,
      kind: "pull_request",
      number: pullRequest.number,
      title: pullRequest.title,
      body: pullRequest.body,
      author: pullRequest.user?.login,
      url: pullRequest.html_url,
      branch: pullRequest.head?.ref,
      mergeSha: pullRequest.merge_commit_sha,
      files,
      backfilled,
      verification: verified ? "required checks succeeded" : "pending"
    });

    const workItem = await this.resolveWorkItem({
      key: primary,
      sourceIdentifier,
      allowCreate,
      createFields: {
        name: createdWorkItemName("pull_request", pullRequest.number, pullRequest.title),
        state: desiredState ?? this.config.states.inProgress,
        priority: "none",
        description_html: description
      }
    });
    await this.transition(workItem, desiredState, description, sourceIdentifier);
  }

  async syncIssue(repository, issue, { allowCreate = false, backfilled = false } = {}) {
    const sourceIdentifier = sourceId(repository, "issue", issue.number);
    const primary = primaryPlaneKey(issue.body) ?? extractPlaneKeys(issue.title)[0] ?? null;
    const desiredState = desiredIssueState(issue, this.config);
    const description = renderGitHubDescription({
      repository,
      kind: "issue",
      number: issue.number,
      title: issue.title,
      body: issue.body,
      author: issue.user?.login,
      url: issue.html_url,
      branch: null,
      files: [],
      backfilled,
      verification: issue.state === "closed" ? issue.state_reason ?? "closed" : "intake"
    });
    const workItem = await this.resolveWorkItem({
      key: primary,
      sourceIdentifier,
      allowCreate,
      createFields: {
        name: createdWorkItemName("issue", issue.number, issue.title),
        state: desiredState ?? this.config.states.backlog,
        priority: "none",
        description_html: description
      }
    });
    await this.transition(workItem, desiredState, description, sourceIdentifier);
  }

  summary() {
    return this.operations.reduce(
      (result, item) => {
        result[item.kind] = (result[item.kind] ?? 0) + 1;
        return result;
      },
      { create: 0, update: 0, unchanged: 0, conflict: 0, skipped: 0 }
    );
  }
}

export async function reconcilePullRequests({
  config,
  planeClient,
  githubClient,
  repository,
  lookbackDays = 30,
  apply = false
}) {
  const engine = new SyncEngine(config, planeClient, { apply });
  const cutoff = Date.now() - lookbackDays * 24 * 60 * 60 * 1000;
  const pullRequests = await githubClient.listPullRequests();

  for (const pullRequest of pullRequests) {
    if (Date.parse(pullRequest.updated_at) < cutoff) continue;
    if (!isTrustedPullRequest(pullRequest, config)) {
      engine.operations.push(
        operation("skipped", {
          source: sourceId(repository, "pull_request", pullRequest.number),
          reason: "External pull request is not approved for Plane sync"
        })
      );
      continue;
    }

    const files = await githubClient.listPullRequestFiles(pullRequest.number);
    const merged = pullRequest.merged === true || Boolean(pullRequest.merged_at);
    let verified = false;
    if (merged && pullRequest.merge_commit_sha) {
      verified = checksSuccessful(
        await githubClient.checkRunsForCommit(pullRequest.merge_commit_sha)
      );
    }
    const primary = primaryKeyForPullRequest(pullRequest);
    const explicitlyCancelled = labelsOf(pullRequest).includes(config.labels.cancelled);
    if (pullRequest.state === "closed" && !merged && !explicitlyCancelled && !primary) {
      engine.operations.push(
        operation("skipped", {
          source: sourceId(repository, "pull_request", pullRequest.number),
          reason: "Closed-unmerged work requires an explicit Plane key or cancellation label"
        })
      );
      continue;
    }
    if (merged && !verified && !primary) {
      engine.operations.push(
        operation("skipped", {
          source: sourceId(repository, "pull_request", pullRequest.number),
          reason: "Merged work lacks retained successful check evidence"
        })
      );
      continue;
    }
    await engine.syncPullRequest(repository, pullRequest, {
      files,
      verified,
      allowCreate: !merged || verified || explicitlyCancelled,
      backfilled: true
    });
  }
  return engine;
}
