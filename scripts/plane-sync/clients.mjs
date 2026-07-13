function errorMessage(method, url, status, body) {
  const detail = String(body ?? "").replace(/\s+/g, " ").trim().slice(0, 300);
  return `${method} ${url.pathname} failed (${status})${detail ? `: ${detail}` : ""}`;
}

async function responseBody(response) {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export class PlaneClient {
  constructor(config, apiKey, fetchImplementation = fetch) {
    if (!apiKey) throw new Error("PLANE_API_KEY is required");
    this.config = config;
    this.apiKey = apiKey;
    this.fetch = fetchImplementation;
  }

  collectionUrl(query = {}) {
    const url = new URL(
      `/api/v1/workspaces/${this.config.workspaceSlug}/projects/${this.config.projectId}/${this.config.resourcePath}/`,
      this.config.baseUrl
    );
    for (const [key, value] of Object.entries(query)) {
      if (value !== null && value !== undefined && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
    return url;
  }

  async request(method, url, body = null) {
    const response = await this.fetch(url, {
      method,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-API-Key": this.apiKey
      },
      body: body === null ? undefined : JSON.stringify(body)
    });
    const parsed = await responseBody(response);
    if (!response.ok) throw new Error(errorMessage(method, url, response.status, parsed));
    return parsed;
  }

  async listWorkItems() {
    const results = [];
    const seenCursors = new Set();
    let cursor = null;

    while (true) {
      const payload = await this.request("GET", this.collectionUrl({ per_page: 100, cursor }));
      if (Array.isArray(payload)) return payload;
      results.push(...(payload?.results ?? []));
      if (!payload?.next_page_results || !payload?.next_cursor) return results;
      if (seenCursors.has(payload.next_cursor)) {
        throw new Error(`Plane pagination repeated cursor ${payload.next_cursor}`);
      }
      seenCursors.add(payload.next_cursor);
      cursor = payload.next_cursor;
    }
  }

  async createWorkItem(fields) {
    return this.request("POST", this.collectionUrl(), fields);
  }

  async updateWorkItem(id, fields) {
    const url = new URL(`${id}/`, this.collectionUrl());
    return this.request("PATCH", url, fields);
  }
}

export class GitHubClient {
  constructor(repository, token, fetchImplementation = fetch) {
    if (!repository) throw new Error("GitHub repository is required");
    if (!token) throw new Error("GITHUB_TOKEN or GH_TOKEN is required");
    this.repository = repository;
    this.token = token;
    this.fetch = fetchImplementation;
  }

  async request(path, query = {}) {
    const url = new URL(`/repos/${this.repository}/${path.replace(/^\//, "")}`, "https://api.github.com");
    for (const [key, value] of Object.entries(query)) {
      if (value !== null && value !== undefined && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
    const response = await this.fetch(url, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${this.token}`,
        "X-GitHub-Api-Version": "2026-03-10"
      }
    });
    const parsed = await responseBody(response);
    if (!response.ok) throw new Error(errorMessage("GET", url, response.status, parsed));
    return parsed;
  }

  async listPullRequests() {
    return this.request("pulls", {
      state: "all",
      sort: "updated",
      direction: "desc",
      per_page: 100
    });
  }

  async listPullRequestFiles(number) {
    return this.request(`pulls/${number}/files`, { per_page: 100 });
  }

  async listPullRequestsForCommit(sha) {
    return this.request(`commits/${sha}/pulls`, { per_page: 100 });
  }

  async checkRunsForCommit(sha) {
    return this.request(`commits/${sha}/check-runs`, { per_page: 100 });
  }
}

export function checksSuccessful(payload) {
  const runs = payload?.check_runs ?? [];
  if (runs.length === 0) return false;
  return runs.every(
    (run) =>
      run.status === "completed" &&
      ["success", "neutral", "skipped"].includes(run.conclusion)
  );
}
