#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import process from "node:process";
import { GitHubClient, PlaneClient } from "./plane-sync/clients.mjs";
import {
  isTrustedPullRequest,
  labelsOf,
  primaryKeyForPullRequest,
  validatePullRequestContract
} from "./plane-sync/domain.mjs";
import { reconcilePullRequests, SyncEngine } from "./plane-sync/reconcile.mjs";

function option(args, name, fallback = null) {
  const index = args.indexOf(name);
  return index === -1 ? fallback : args[index + 1];
}

function hasFlag(args, name) {
  return args.includes(name);
}

async function loadJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function loadConfig() {
  return loadJson(new URL("../.github/plane-sync.json", import.meta.url));
}

function printResult(engine, { mode, command }) {
  const result = {
    command,
    mode,
    summary: engine.summary(),
    operations: engine.operations
  };
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (engine.operations.some((item) => item.kind === "conflict")) process.exitCode = 2;
}

function apiToken() {
  return process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
}

async function eventCommand(config, args, apply) {
  const payloadPath = option(args, "--payload", process.env.GITHUB_EVENT_PATH);
  const eventName = option(args, "--event-name", process.env.GITHUB_EVENT_NAME);
  if (!payloadPath || !eventName) throw new Error("event requires --payload and --event-name");
  const payload = await loadJson(payloadPath);
  const repository = payload.repository?.full_name ?? process.env.GITHUB_REPOSITORY;
  const plane = new PlaneClient(config, process.env.PLANE_API_KEY);
  const engine = new SyncEngine(config, plane, { apply });

  if (eventName === "pull_request_target" || eventName === "pull_request") {
    const pullRequest = payload.pull_request;
    if (!pullRequest) throw new Error("Pull-request payload is missing pull_request");
    if (!isTrustedPullRequest(pullRequest, config)) {
      engine.operations.push({
        kind: "skipped",
        source: `${repository}#${pullRequest.number}`,
        reason: `Apply the ${config.labels.syncApproved} label to authorize Plane synchronization`
      });
      printResult(engine, { mode: apply ? "apply" : "dry-run", command: "event" });
      return;
    }

    const internal = pullRequest.head?.repo?.full_name === repository;
    const hasApprovalLabel = labelsOf(pullRequest).includes(config.labels.syncApproved);
    const key = primaryKeyForPullRequest(pullRequest);
    const allowCreate = !internal && hasApprovalLabel && !key;
    await engine.syncPullRequest(repository, pullRequest, { allowCreate });
  } else if (eventName === "issues") {
    const issue = payload.issue;
    if (!issue) throw new Error("Issue payload is missing issue");
    const trusted = config.trustedAuthorAssociations.includes(
      String(issue.author_association ?? "").toUpperCase()
    );
    const approved = labelsOf(issue).includes(config.labels.syncApproved);
    if (!trusted && !approved) {
      engine.operations.push({
        kind: "skipped",
        source: `${repository}#${issue.number}`,
        reason: `Apply the ${config.labels.syncApproved} label to accept this intake into Plane`
      });
    } else {
      await engine.syncIssue(repository, issue, { allowCreate: true });
    }
  } else {
    throw new Error(`Unsupported event: ${eventName}`);
  }

  printResult(engine, { mode: apply ? "apply" : "dry-run", command: "event" });
}

async function completeCommand(config, args, apply) {
  const payloadPath = option(args, "--payload", process.env.GITHUB_EVENT_PATH);
  if (!payloadPath) throw new Error("complete requires --payload");
  const payload = await loadJson(payloadPath);
  const run = payload.workflow_run;
  const repository = payload.repository?.full_name ?? process.env.GITHUB_REPOSITORY;
  if (
    !run ||
    run.conclusion !== "success" ||
    run.head_branch !== payload.repository?.default_branch ||
    run.head_repository?.full_name !== repository
  ) {
    throw new Error("Completion requires successful trusted default-branch CI");
  }

  const github = new GitHubClient(repository, apiToken());
  const plane = new PlaneClient(config, process.env.PLANE_API_KEY);
  const engine = new SyncEngine(config, plane, { apply });
  const pullRequests = await github.listPullRequestsForCommit(run.head_sha);
  for (const pullRequest of pullRequests.filter((item) => item.merged_at)) {
    const files = await github.listPullRequestFiles(pullRequest.number);
    await engine.syncPullRequest(repository, pullRequest, {
      files,
      verified: true,
      allowCreate: true,
      backfilled: !primaryKeyForPullRequest(pullRequest)
    });
  }
  printResult(engine, { mode: apply ? "apply" : "dry-run", command: "complete" });
}

async function reconcileCommand(config, args, apply) {
  const repository = option(args, "--repo", process.env.GITHUB_REPOSITORY);
  const lookbackDays = Number(option(args, "--lookback-days", "30"));
  const github = new GitHubClient(repository, apiToken());
  const plane = new PlaneClient(config, process.env.PLANE_API_KEY);
  const engine = await reconcilePullRequests({
    config,
    planeClient: plane,
    githubClient: github,
    repository,
    lookbackDays,
    apply
  });
  printResult(engine, { mode: apply ? "apply" : "dry-run", command: "reconcile" });
}

async function validateCommand(args) {
  const payloadPath = option(args, "--payload", process.env.GITHUB_EVENT_PATH);
  if (!payloadPath) throw new Error("validate requires --payload");
  const payload = await loadJson(payloadPath);
  const repository = payload.repository?.full_name ?? process.env.GITHUB_REPOSITORY;
  const result = validatePullRequestContract(payload.pull_request, repository);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (!result.valid) process.exitCode = 2;
}

export async function main(argv = process.argv.slice(2)) {
  const [command, ...args] = argv;
  const apply = hasFlag(args, "--apply");
  const config = await loadConfig();
  switch (command) {
    case "event":
      return eventCommand(config, args, apply);
    case "complete":
      return completeCommand(config, args, apply);
    case "reconcile":
      return reconcileCommand(config, args, apply);
    case "validate":
      return validateCommand(args);
    default:
      throw new Error(
        "Usage: plane-sync.mjs <event|complete|reconcile|validate> [--apply] [options]"
      );
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    process.stderr.write(`plane-sync: ${error.message}\n`);
    process.exitCode = 1;
  });
}
