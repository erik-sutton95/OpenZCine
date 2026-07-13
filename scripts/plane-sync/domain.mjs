const primaryPlanePattern = /^\s*Plane:\s*(OZC-(\d+))\s*$/gim;
const anyPlanePattern = /\bOZC-(\d+)\b/gi;

export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function truncate(value, maximum) {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim();
  if (normalized.length <= maximum) return normalized;
  return `${normalized.slice(0, Math.max(0, maximum - 1)).trimEnd()}…`;
}

export function primaryPlaneKey(body) {
  const matches = [...String(body ?? "").matchAll(primaryPlanePattern)];
  return matches.length === 1 ? `OZC-${Number(matches[0][2])}` : null;
}

export function extractPlaneKeys(...values) {
  const keys = new Set();
  for (const value of values) {
    for (const match of String(value ?? "").matchAll(anyPlanePattern)) {
      keys.add(`OZC-${Number(match[1])}`);
    }
  }
  return [...keys].sort((left, right) => sequenceFromKey(left) - sequenceFromKey(right));
}

export function sequenceFromKey(key) {
  const match = String(key ?? "").match(/^OZC-(\d+)$/i);
  if (!match) throw new Error(`Invalid Plane key: ${key}`);
  return Number(match[1]);
}

export function sourceId(repository, kind, number) {
  return `github:${repository}:${kind}:${number}`;
}

export function labelsOf(record) {
  return (record?.labels ?? [])
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter(Boolean);
}

export function isTrustedPullRequest(pullRequest, config) {
  const association = String(pullRequest?.author_association ?? "").toUpperCase();
  return (
    config.trustedAuthorAssociations.includes(association) ||
    labelsOf(pullRequest).includes(config.labels.syncApproved) ||
    pullRequest?.merged === true || Boolean(pullRequest?.merged_at)
  );
}

export function primaryKeyForPullRequest(pullRequest) {
  const explicit = primaryPlaneKey(pullRequest?.body);
  if (explicit) return explicit;
  const inferred = extractPlaneKeys(pullRequest?.head?.ref, pullRequest?.title);
  return inferred.length === 1 ? inferred[0] : null;
}

export function validatePullRequestContract(pullRequest, repository) {
  const internal = pullRequest?.head?.repo?.full_name === repository;
  const login = pullRequest?.user?.login ?? "";
  const bot = login === "dependabot[bot]" || login === "github-actions[bot]";
  if (!internal || bot) return { valid: true, reason: "external-or-automation" };

  const key = primaryPlaneKey(pullRequest?.body);
  if (!key) {
    return {
      valid: false,
      reason: "Add exactly one `Plane: OZC-###` line to the pull-request body."
    };
  }
  return { valid: true, key };
}

export function desiredPullRequestState(pullRequest, config, { verified = false } = {}) {
  if (pullRequest?.merged === true || pullRequest?.merged_at) {
    return verified ? config.states.done : null;
  }

  if (pullRequest?.state === "closed") {
    return labelsOf(pullRequest).includes(config.labels.cancelled)
      ? config.states.cancelled
      : null;
  }

  return config.states.inProgress;
}

export function desiredIssueState(issue, config) {
  const labels = labelsOf(issue);
  if (issue?.state === "closed") {
    if (issue?.state_reason === "completed") return config.states.done;
    if (labels.some((label) => ["wontfix", "invalid"].includes(label))) {
      return config.states.cancelled;
    }
    return null;
  }
  return labels.includes(config.labels.ready) ? config.states.todo : config.states.backlog;
}

export function topLevelAreas(files) {
  const areas = new Set();
  for (const file of files ?? []) {
    const path = typeof file === "string" ? file : file?.filename;
    if (!path) continue;
    areas.add(path.includes("/") ? path.split("/", 1)[0] : path);
  }
  return [...areas].sort().slice(0, 12);
}

export function renderGitHubDescription({
  repository,
  kind,
  number,
  title,
  body,
  author,
  url,
  branch,
  mergeSha,
  files = [],
  backfilled = false,
  verification = "pending"
}) {
  const id = sourceId(repository, kind, number);
  const areas = topLevelAreas(files);
  const summary = truncate(body, 800) || truncate(title, 240);
  const provenance = backfilled ? "Historical reconciliation" : "GitHub lifecycle sync";

  const rows = [
    ["Source", `<a href="${escapeHtml(url)}">${escapeHtml(`${repository}#${number}`)}</a>`],
    ["Author", escapeHtml(author || "unknown")],
    ["Branch", `<code>${escapeHtml(branch || "n/a")}</code>`],
    ["Verification", escapeHtml(verification)],
    ["Provenance", escapeHtml(provenance)]
  ];
  if (mergeSha) rows.push(["Merge SHA", `<code>${escapeHtml(mergeSha)}</code>`]);
  if (areas.length > 0) rows.push(["Changed areas", escapeHtml(areas.join(", "))]);

  const table = rows
    .map(([label, value]) => `<tr><th>${escapeHtml(label)}</th><td>${value}</td></tr>`)
    .join("");

  return [
    `<p><strong>GitHub sync begin:</strong> <code>${escapeHtml(id)}</code></p>`,
    `<h2>${escapeHtml(title)}</h2>`,
    `<p>${escapeHtml(summary)}</p>`,
    `<table><tbody>${table}</tbody></table>`,
    `<p><strong>GitHub source ID:</strong> <code>${escapeHtml(id)}</code></p>`,
    `<p><strong>GitHub sync end:</strong> <code>${escapeHtml(id)}</code></p>`
  ].join("");
}

export function appendSourceReference(existingHtml, sourceHtml, sourceIdentifier) {
  const existing = String(existingHtml ?? "");
  const escapedIdentifier = sourceIdentifier.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const synchronizedBlock = new RegExp(
    `<p><strong>GitHub sync begin:</strong> <code>${escapedIdentifier}</code></p>` +
      `[\\s\\S]*?` +
      `<p><strong>GitHub sync end:</strong> <code>${escapedIdentifier}</code></p>`
  );
  if (synchronizedBlock.test(existing)) return existing.replace(synchronizedBlock, sourceHtml);
  if (existing.includes(sourceIdentifier)) return existing;
  if (!existing.trim()) return sourceHtml;
  return `${existing}<hr>${sourceHtml}`;
}

export function createdWorkItemName(kind, number, title) {
  const prefix = kind === "issue" ? "Issue" : "PR";
  return `[Reconciled] ${prefix} #${number} — ${truncate(title, 160)}`;
}
