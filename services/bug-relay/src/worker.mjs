const V1_API_PATH = "/v1/bug-reports";
const V2_API_PATH = "/v2/bug-reports";
const V2_MEDIA_PATH_PREFIX = "/v2/bug-report-media/";
const MAX_BODY_BYTES = 12 * 1024;
const MAX_V2_REPORT_BYTES = 16 * 1024;
const MAX_V2_SCREENSHOT_BYTES = 1_048_576;
const MAX_V2_SCREENSHOT_COUNT = 3;
const MAX_V2_SCREENSHOT_TOTAL_BYTES = MAX_V2_SCREENSHOT_BYTES * MAX_V2_SCREENSHOT_COUNT;
const MAX_V2_REQUEST_BYTES = MAX_V2_SCREENSHOT_TOTAL_BYTES + 64 * 1024;
const RECEIPT_KEY = "receipt";
const PENDING_SUBMISSION_KEY = "pending-submission";
const RECEIPT_TTL_MS = 24 * 60 * 60 * 1000;
const UNCERTAIN_SUBMISSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const GITHUB_OWNER = "erik-sutton95";
const GITHUB_REPOSITORY = "OpenZCine";
const GITHUB_API_URL = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/issues`;
const GITHUB_ISSUE_URL_PREFIX = `https://github.com/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/issues/`;
const MEDIA_PUBLIC_ORIGIN = "https://reports.openzcine.app";

const ROOT_REQUIRED_KEYS = ["schemaVersion", "summary", "whatHappened", "frequency", "context"];
const ROOT_ALLOWED_KEYS = [...ROOT_REQUIRED_KEYS, "stepsToReproduce"];
const CONTEXT_KEYS = [
  "platform",
  "appVersion",
  "buildNumber",
  "osVersion",
  "deviceClass",
  "connection",
];
const FREQUENCIES = new Set(["always", "sometimes", "once", "unknown"]);
const PLATFORMS = new Set(["ios", "android"]);
const DEVICE_CLASSES = new Set(["phone", "tablet", "unknown"]);
const CONNECTIONS = new Set(["wifi", "usb", "unknown"]);
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DISALLOWED_CONTROL_CHARACTERS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/u;
const ACTIVITY_EVENTS = new Set([
  "app.launched",
  "scene.connected",
  "app.background",
  "app.foreground",
  "connection.disconnected",
  "connection.scanning",
  "connection.pairing",
  "connection.reconnecting",
  "connection.preparing-live-view",
  "connection.connected",
  "connection.connecting",
  "monitor.presented",
  "monitor.dismissed",
  "live-view.started",
  "live-view.failed",
  "recording.started",
  "recording.stopped",
  // The currently shipped native event uses the live-guide prefix. The plain guide aliases
  // remain accepted for a short, closed compatibility surface used by early clients.
  "live-guide.presented",
  "live-guide.completed",
  "live-guide.skipped",
  "guide.presented",
  "guide.completed",
  "guide.skipped",
  "diagnostics.exported",
  "error.connection.failed",
  "error.connection.event-channel-ended",
  "error.live-view.failed",
  "warning.live-view.stalled",
]);
const ACTIVITY_INCIDENTS = new Map([
  [
    "error.connection.failed",
    {
      severity: "ERROR",
      trace: ["connection.attempt", "transport-or-handshake", "connection.failure"],
    },
  ],
  [
    "error.connection.event-channel-ended",
    {
      severity: "ERROR",
      trace: ["connection.connected", "camera.event-channel", "channel.ended"],
    },
  ],
  [
    "live-view.failed",
    {
      severity: "ERROR",
      trace: ["connection.connected", "live-view.start", "first-frame.unavailable"],
    },
  ],
  [
    "error.live-view.failed",
    {
      severity: "ERROR",
      trace: ["connection.connected", "live-view.start", "first-frame.unavailable"],
    },
  ],
  [
    "warning.live-view.stalled",
    {
      severity: "WARNING",
      trace: ["live-view.streaming", "frame-delivery.stalled", "live-view.restart"],
    },
  ],
]);
const PNG_SIGNATURE = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
const PNG_IHDR = Uint8Array.of(0x49, 0x48, 0x44, 0x52);
const PNG_IDAT = Uint8Array.of(0x49, 0x44, 0x41, 0x54);
const PNG_IEND = Uint8Array.of(0x49, 0x45, 0x4e, 0x44);
const STRIPPABLE_PNG_METADATA_TYPES = new Set([
  "cHRM",
  "eXIf",
  "gAMA",
  "iCCP",
  "iTXt",
  "pHYs",
  "sBIT",
  "sPLT",
  "sRGB",
  "tEXt",
  "tIME",
  "zTXt",
]);
const CRC32_TABLE = createCRC32Table();
const textEncoder = new TextEncoder();

let installationTokenCache = null;

/** Error thrown for a request that deliberately does not meet the public contract. */
export class InvalidRequestError extends Error {
  constructor() {
    super("Invalid request");
  }
}

/** Error used when an upstream dependency cannot safely complete a report. */
export class ServiceUnavailableError extends Error {
  constructor() {
    super("Service unavailable");
  }
}

/** A GitHub create may have succeeded even though the relay cannot safely recover its receipt. */
export class AmbiguousIssueCreationError extends ServiceUnavailableError {
  constructor() {
    super();
  }
}

/**
 * Build the Worker entry point. Exporting a factory makes request behavior testable without a
 * Cloudflare runtime or network access.
 *
 * @returns {{fetch(request: Request, env: object): Promise<Response>}}
 */
export function createWorker() {
  return {
    async fetch(request, env) {
      const url = new URL(request.url);

      if (url.pathname.startsWith(V2_MEDIA_PATH_PREFIX)) {
        return fetchV2Media(request, env, url.pathname);
      }

      const isV1 = url.pathname === V1_API_PATH;
      const isV2 = url.pathname === V2_API_PATH;
      if (!isV1 && !isV2) {
        return errorResponse("invalid_request", 404);
      }

      if (request.method !== "POST") {
        return errorResponse("invalid_request", 405, { Allow: "POST" });
      }

      const contentType = request.headers.get("Content-Type");
      if ((isV1 && !isJsonContentType(contentType)) || (isV2 && !isMultipartContentType(contentType))) {
        return errorResponse("invalid_request", 415);
      }

      if (!isIdentityContentEncoding(request.headers.get("Content-Encoding"))) {
        return errorResponse("invalid_request", 415);
      }

      let idempotencyKey;
      try {
        idempotencyKey = validateIdempotencyKey(request.headers.get("Idempotency-Key"));
      } catch (error) {
        if (error instanceof InvalidRequestError) {
          return errorResponse("invalid_request", 400);
        }

        return errorResponse("unavailable", 503);
      }

      const clientIP = request.headers.get("CF-Connecting-IP");
      if (!clientIP) {
        return errorResponse("unavailable", 503);
      }

      let limitResult;
      try {
        limitResult = await env.BUG_REPORT_RATE_LIMITER.limit({ key: clientIP });
      } catch {
        return errorResponse("unavailable", 503);
      }

      if (!limitResult?.success) {
        return errorResponse("rate_limited", 429, { "Retry-After": "60" });
      }

      let submission;
      try {
        submission = isV1
          ? await parseReportBody(request)
          : await parseV2Submission(request, idempotencyKey);
      } catch (error) {
        if (error instanceof InvalidRequestError) {
          return errorResponse("invalid_request", 400);
        }

        return errorResponse("unavailable", 503);
      }

      try {
        const id = env.BUG_REPORT_IDEMPOTENCY.idFromName(idempotencyKey);
        const stub = env.BUG_REPORT_IDEMPOTENCY.get(id);
        const response = await stub.fetch("https://bug-report-idempotency.internal/submit", {
          method: "POST",
          headers: { "Content-Type": "application/json; charset=utf-8" },
          body: JSON.stringify(submission),
        });

        if (response.status === 400) {
          return errorResponse("invalid_request", 400);
        }

        if (response.status !== 200 && response.status !== 201) {
          return errorResponse("unavailable", 503);
        }

        const receipt = await parseIssueReceipt(response);
        if (!receipt) {
          return errorResponse("unavailable", 503);
        }

        return jsonResponse({ issue: receipt }, response.status);
      } catch {
        return errorResponse("unavailable", 503);
      }
    },
  };
}

/**
 * Cloudflare Durable Object that serializes an idempotency key, retaining receipts for 24 hours and
 * an outcome-uncertain fingerprint marker for 30 days to prevent a duplicate public issue.
 */
export class BugReportIdempotency {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.coordinator = new ReceiptCoordinator({
      storage: ctx.storage,
      createIssue: (submission) => createIssueForSubmission(env, submission),
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/submit") {
      return errorResponse("invalid_request", 400);
    }

    try {
      const rawSubmission = await request.json();
      const submission = isV2Submission(rawSubmission)
        ? validateV2Submission(rawSubmission)
        : validateReport(rawSubmission);
      const result = await this.coordinator.submit(submission);

      if (result.status === 400) {
        return errorResponse("invalid_request", 400);
      }

      if (result.status === 503) {
        return errorResponse("unavailable", 503);
      }

      return jsonResponse({ issue: result.issue }, result.status);
    } catch (error) {
      if (error instanceof InvalidRequestError) {
        return errorResponse("invalid_request", 400);
      }

      return errorResponse("unavailable", 503);
    }
  }

  async alarm() {
    const receipt = await this.ctx.storage.get(RECEIPT_KEY);
    const pendingSubmission = await this.ctx.storage.get(PENDING_SUBMISSION_KEY);
    const now = Date.now();
    const receiptIsCurrent = isStoredReceipt(receipt) && receipt.expiresAt > now;
    const pendingIsCurrent = isStoredPendingSubmission(pendingSubmission) && pendingSubmission.expiresAt > now;

    if (!receiptIsCurrent) {
      await this.ctx.storage.delete(RECEIPT_KEY);
    }

    if (!pendingIsCurrent) {
      await this.ctx.storage.delete(PENDING_SUBMISSION_KEY);
    }

    const nextExpiry = Math.min(
      receiptIsCurrent ? receipt.expiresAt : Number.POSITIVE_INFINITY,
      pendingIsCurrent ? pendingSubmission.expiresAt : Number.POSITIVE_INFINITY,
    );
    if (Number.isFinite(nextExpiry)) {
      await this.ctx.storage.setAlarm(nextExpiry);
    }
  }
}

/**
 * Storage-backed idempotency state machine used by the Durable Object and unit tests.
 */
export class ReceiptCoordinator {
  constructor({
    storage,
    createIssue,
    now = () => Date.now(),
    fingerprint = fingerprintReport,
    requiresReservation = isV2Submission,
  }) {
    this.storage = storage;
    this.createIssue = createIssue;
    this.now = now;
    this.fingerprint = fingerprint;
    this.requiresReservation = requiresReservation;
    this.inFlight = null;
  }

  async submit(submission) {
    const payloadHash = await this.fingerprint(submission);
    const current = await this.currentReceipt();

    if (current) {
      return receiptResultFor(current, payloadHash);
    }

    const pendingSubmission = await this.currentPendingSubmission();
    if (pendingSubmission) {
      if (pendingSubmission.payloadHash !== payloadHash) {
        return { status: 400 };
      }

      if (pendingSubmission.outcome === "uncertain") {
        return { status: 503 };
      }
    }

    const requiresReservation = this.requiresReservation(submission);

    if (this.inFlight) {
      const result = await this.inFlight;
      return result.payloadHash === payloadHash
        ? { status: 200, issue: result.issue }
        : { status: 400 };
    }

    const operation = this.createAndStore(submission, payloadHash, requiresReservation);
    this.inFlight = operation;

    try {
      const result = await operation;
      return { status: 201, issue: result.issue };
    } finally {
      if (this.inFlight === operation) {
        this.inFlight = null;
      }
    }
  }

  async createAndStore(submission, payloadHash, requiresReservation) {
    const current = await this.currentReceipt();
    if (current) {
      const result = receiptResultFor(current, payloadHash);
      if (result.status === 400) {
        throw new InvalidRequestError();
      }

      return { payloadHash, issue: result.issue };
    }

    if (requiresReservation) {
      const pendingSubmission = await this.currentPendingSubmission();
      if (pendingSubmission && pendingSubmission.payloadHash !== payloadHash) {
        throw new InvalidRequestError();
      }

      if (!pendingSubmission) {
        const expiresAt = this.now() + RECEIPT_TTL_MS;
        await this.storage.put(PENDING_SUBMISSION_KEY, { expiresAt, payloadHash });
        await this.storage.setAlarm(expiresAt);
      }
    }

    let issue;
    try {
      issue = await this.createIssue(submission);
    } catch (error) {
      if (error instanceof AmbiguousIssueCreationError) {
        const expiresAt = this.now() + UNCERTAIN_SUBMISSION_TTL_MS;
        await this.storage.put(PENDING_SUBMISSION_KEY, {
          expiresAt,
          outcome: "uncertain",
          payloadHash,
        });
        await this.storage.setAlarm(expiresAt);
      }
      throw error;
    }
    const receipt = {
      expiresAt: this.now() + RECEIPT_TTL_MS,
      issue,
      payloadHash,
    };

    await this.storage.put(RECEIPT_KEY, receipt);
    if (requiresReservation) {
      await this.storage.delete(PENDING_SUBMISSION_KEY);
    }
    await this.storage.setAlarm(receipt.expiresAt);
    return { payloadHash, issue };
  }

  async currentReceipt() {
    const value = await this.storage.get(RECEIPT_KEY);
    if (!isStoredReceipt(value)) {
      if (value !== undefined && value !== null) {
        await this.storage.delete(RECEIPT_KEY);
      }

      return null;
    }

    if (value.expiresAt <= this.now()) {
      await this.storage.delete(RECEIPT_KEY);
      return null;
    }

    return value;
  }

  async currentPendingSubmission() {
    const value = await this.storage.get(PENDING_SUBMISSION_KEY);
    if (!isStoredPendingSubmission(value)) {
      if (value !== undefined && value !== null) {
        await this.storage.delete(PENDING_SUBMISSION_KEY);
      }

      return null;
    }

    if (value.expiresAt <= this.now()) {
      await this.storage.delete(PENDING_SUBMISSION_KEY);
      return null;
    }

    return value;
  }
}

/**
 * Validate and normalize the intentionally narrow public report schema.
 */
export function validateReport(value) {
  return validateReportVersion(value, 1, ROOT_ALLOWED_KEYS);
}

/** Validate the attachment-capable report schema without accepting arbitrary diagnostics text. */
export function validateV2Report(value) {
  const report = validateReportVersion(value, 2, [...ROOT_ALLOWED_KEYS, "activityLog"]);

  if (Object.hasOwn(value, "activityLog")) {
    if (!Array.isArray(value.activityLog) || value.activityLog.length > 200) {
      throw new InvalidRequestError();
    }

    report.activityLog = value.activityLog.map((event) => enumValue(event, ACTIVITY_EVENTS));
  }

  return report;
}

function validateReportVersion(value, schemaVersion, allowedKeys) {
  if (!isPlainObject(value) || !hasExactKeys(value, ROOT_REQUIRED_KEYS, allowedKeys)) {
    throw new InvalidRequestError();
  }

  if (value.schemaVersion !== schemaVersion) {
    throw new InvalidRequestError();
  }

  if (!isPlainObject(value.context) || !hasExactKeys(value.context, CONTEXT_KEYS, CONTEXT_KEYS)) {
    throw new InvalidRequestError();
  }

  const context = {
    platform: enumValue(value.context.platform, PLATFORMS),
    appVersion: normalizedText(value.context.appVersion, 64, true),
    buildNumber: normalizedText(value.context.buildNumber, 64, true),
    osVersion: normalizedText(value.context.osVersion, 128, true),
    deviceClass: enumValue(value.context.deviceClass, DEVICE_CLASSES),
    connection: enumValue(value.context.connection, CONNECTIONS),
  };

  const report = {
    schemaVersion,
    summary: normalizedText(value.summary, 120, true, { compact: true }),
    whatHappened: normalizedText(value.whatHappened, 4000, true),
    frequency: enumValue(value.frequency, FREQUENCIES),
    context,
  };

  if (Object.hasOwn(value, "stepsToReproduce")) {
    report.stepsToReproduce = normalizedText(value.stepsToReproduce, 4000, false);
  }

  return report;
}

/**
 * Render report content so user input cannot escape a Markdown code fence or create a mention.
 */
export function renderIssue(report) {
  return renderNormalizedIssue(validateReport(report));
}

/** Render a v2 issue with only server-derived media URLs and closed activity events. */
export function renderV2Issue(submission) {
  const safeSubmission = validateV2Submission(submission);
  const screenshotURLs = safeSubmission.screenshots.map((screenshot) =>
    publicMediaURL(safeSubmission.idempotencyKey, screenshot.slot),
  );
  return renderNormalizedIssue(safeSubmission.report, { screenshotURLs });
}

function renderNormalizedIssue(safeReport, { screenshotURLs = [] } = {}) {
  const platform = safeReport.context.platform === "ios" ? "iOS" : "Android";
  const title = `[${platform}] ${safeIssueTitle(safeReport.summary)}`;
  const context = [
    `Platform: ${platform}`,
    `App version: ${safeReport.context.appVersion}`,
    `Build number: ${safeReport.context.buildNumber}`,
    `OS version: ${safeReport.context.osVersion}`,
    `Device class: ${safeReport.context.deviceClass}`,
    `Connection: ${safeReport.context.connection}`,
    `Frequency: ${safeReport.frequency}`,
  ].join("\n");
  const steps = safeReport.stepsToReproduce;

  const sections = [
    "## Anonymous in-app bug report",
    "",
    "This report was submitted without an account and is public in this repository.",
    "",
    "## Summary",
    "",
    fencedText(safeReport.summary),
    "",
    "## What happened",
    "",
    fencedText(safeReport.whatHappened),
    "",
    "## Steps to reproduce",
    "",
    steps ? fencedText(steps) : "Not provided.",
    "",
    "## App and device context",
    "",
    fencedText(context),
  ];

  if (safeReport.activityLog?.length) {
    sections.push(
      "",
      "## Privacy-filtered app activity log",
      "",
      "This list contains closed app event names plus privacy-safe error/warning codes. Incident traces are fixed operational stages, not raw stack traces or free-form log text; there are no timestamps.",
      "",
      fencedText(renderActivityLog(safeReport.activityLog)),
    );
  }

  if (screenshotURLs.length) {
    sections.push("", "## Screenshots", "");
    for (const [index, screenshotURL] of screenshotURLs.entries()) {
      sections.push(`![Screenshot ${index + 1}](${screenshotURL})`, "");
    }
  }

  return {
    title,
    body: sections.join("\n"),
  };
}

function renderActivityLog(events) {
  return events
    .map((event) => {
      const incident = ACTIVITY_INCIDENTS.get(event);
      if (!incident) return event;
      const trace = incident.trace.map((frame) => `    at ${frame}`).join("\n");
      return `[${incident.severity}] ${event}\n  operational trace:\n${trace}`;
    })
    .join("\n");
}

/**
 * Create a labelled GitHub issue using a short-lived GitHub App installation token.
 */
export async function createGitHubIssue(
  env,
  report,
  { fetchImpl = fetch, getToken = getInstallationToken } = {},
) {
  return createGitHubIssueFromRendered(env, renderIssue(report), { fetchImpl, getToken });
}

/** Store only canonical screenshots before creating the public issue that references them. */
export async function createV2GitHubIssue(
  env,
  submission,
  { fetchImpl = fetch, getToken = getInstallationToken } = {},
) {
  const safeSubmission = await canonicalizeV2Submission(submission);
  const createdMediaKeys = await storeV2Screenshots(env, safeSubmission);
  try {
    return await createGitHubIssueFromRendered(env, renderV2Issue(safeSubmission), {
      fetchImpl,
      getToken,
    });
  } catch (error) {
    if (!(error instanceof AmbiguousIssueCreationError)) {
      await deleteV2Media(env?.BUG_REPORT_MEDIA, createdMediaKeys);
    }
    throw error;
  }
}

async function createIssueForSubmission(env, submission) {
  return isV2Submission(submission)
    ? createV2GitHubIssue(env, submission)
    : createGitHubIssue(env, submission);
}

async function createGitHubIssueFromRendered(env, rendered, { fetchImpl, getToken }) {
  const token = await getToken(env, { fetchImpl });

  let response;
  try {
    response = await fetchImpl(GITHUB_API_URL, {
      method: "POST",
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=utf-8",
        "User-Agent": "OpenZCine-bug-relay",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({
        title: rendered.title,
        body: rendered.body,
        labels: ["bug", "needs-triage", "source:anonymous"],
      }),
    });
  } catch {
    throw new AmbiguousIssueCreationError();
  }

  if (!response.ok) {
    if (response.status >= 500) {
      throw new AmbiguousIssueCreationError();
    }
    throw new ServiceUnavailableError();
  }

  let issue;
  try {
    issue = await response.json();
  } catch {
    throw new AmbiguousIssueCreationError();
  }

  if (!Number.isSafeInteger(issue?.number) || issue.number < 1) {
    throw new AmbiguousIssueCreationError();
  }

  return canonicalIssueReceipt(issue.number);
}

async function storeV2Screenshots(env, submission) {
  if (submission.screenshots.length === 0) {
    return [];
  }

  const bucket = env?.BUG_REPORT_MEDIA;
  if (
    !bucket ||
    typeof bucket.get !== "function" ||
    typeof bucket.put !== "function" ||
    typeof bucket.delete !== "function"
  ) {
    throw new ServiceUnavailableError();
  }

  const createdKeys = [];
  try {
    for (const screenshot of submission.screenshots) {
      const key = v2MediaKey(submission.idempotencyKey, screenshot.slot);
      const bytes = base64UrlToBytes(screenshot.data);
      const existing = await bucket.get(key);
      if (existing) {
        if (!bytesEqual(await r2ObjectBytes(existing), bytes)) {
          throw new InvalidRequestError();
        }
        continue;
      }

      await bucket.put(key, bytes, { httpMetadata: { contentType: "image/png" } });
      createdKeys.push(key);
    }
  } catch (error) {
    await deleteV2Media(bucket, createdKeys);
    if (error instanceof InvalidRequestError) {
      throw error;
    }
    throw new ServiceUnavailableError();
  }

  return createdKeys;
}

async function deleteV2Media(bucket, keys) {
  if (!bucket || typeof bucket.delete !== "function") {
    return;
  }

  for (const key of keys) {
    try {
      await bucket.delete(key);
    } catch {
      // The Durable Object reservation prevents a changed retry from overwriting a leftover key.
      // R2 lifecycle expiry is the operational backstop when a deletion itself is unavailable.
    }
  }
}

async function r2ObjectBytes(object) {
  if (object instanceof Uint8Array) {
    return object;
  }

  if (object && typeof object.arrayBuffer === "function") {
    return new Uint8Array(await object.arrayBuffer());
  }

  if (object && typeof object === "object" && object.body) {
    return new Uint8Array(await new Response(object.body).arrayBuffer());
  }

  throw new ServiceUnavailableError();
}

/**
 * Mint or reuse a short-lived GitHub App installation token. The cache exists only in a Worker
 * isolate and credentials never cross the Worker boundary.
 */
export async function getInstallationToken(
  env,
  { fetchImpl = fetch, now = () => Date.now(), cache = installationTokenCache } = {},
) {
  const appId = requiredSecret(env, "GITHUB_APP_ID");
  const installationId = requiredSecret(env, "GITHUB_INSTALLATION_ID");
  const privateKey = requiredSecret(env, "GITHUB_APP_PRIVATE_KEY");
  const nowMs = now();

  if (
    cache &&
    cache.appId === appId &&
    cache.installationId === installationId &&
    cache.expiresAt - nowMs > 60_000
  ) {
    return cache.token;
  }

  const jwt = await createAppJwt(appId, privateKey, nowMs);
  let response;
  try {
    response = await fetchImpl(
      `https://api.github.com/app/installations/${encodeURIComponent(installationId)}/access_tokens`,
      {
        method: "POST",
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${jwt}`,
          "User-Agent": "OpenZCine-bug-relay",
          "X-GitHub-Api-Version": "2022-11-28",
        },
      },
    );
  } catch {
    throw new ServiceUnavailableError();
  }

  if (!response.ok) {
    throw new ServiceUnavailableError();
  }

  let tokenResponse;
  try {
    tokenResponse = await response.json();
  } catch {
    throw new ServiceUnavailableError();
  }

  const expiresAt = Date.parse(tokenResponse?.expires_at ?? "");
  if (typeof tokenResponse?.token !== "string" || !tokenResponse.token || !Number.isFinite(expiresAt)) {
    throw new ServiceUnavailableError();
  }

  installationTokenCache = {
    appId,
    installationId,
    expiresAt,
    token: tokenResponse.token,
  };

  return tokenResponse.token;
}

/**
 * Sign a GitHub App JWT with the app's RSA private key using Web Crypto only.
 */
export async function createAppJwt(appId, privateKeyPem, nowMs = Date.now()) {
  if (typeof appId !== "string" || !/^[0-9]+$/u.test(appId)) {
    throw new ServiceUnavailableError();
  }

  const issuedAt = Math.floor(nowMs / 1000) - 60;
  const encodedHeader = base64Url(textEncoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const encodedPayload = base64Url(
    textEncoder.encode(
      JSON.stringify({
        exp: issuedAt + 9 * 60,
        iat: issuedAt,
        iss: appId,
      }),
    ),
  );
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  let key;
  try {
    key = await crypto.subtle.importKey(
      "pkcs8",
      pemToPkcs8(privateKeyPem),
      { hash: "SHA-256", name: "RSASSA-PKCS1-v1_5" },
      false,
      ["sign"],
    );
  } catch {
    throw new ServiceUnavailableError();
  }

  let signature;
  try {
    signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, textEncoder.encode(signingInput));
  } catch {
    throw new ServiceUnavailableError();
  }

  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

async function parseReportBody(request) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength && (!/^\d+$/u.test(contentLength) || Number(contentLength) > MAX_BODY_BYTES)) {
    throw new InvalidRequestError();
  }

  const bytes = await readBoundedBody(request);

  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new InvalidRequestError();
  }

  try {
    return validateReport(JSON.parse(text));
  } catch (error) {
    if (error instanceof InvalidRequestError) {
      throw error;
    }

    throw new InvalidRequestError();
  }
}

async function parseV2Submission(request, idempotencyKey) {
  const expectedLength = requiredV2ContentLength(request.headers.get("Content-Length"));
  const bytes = await readBoundedBody(request, MAX_V2_REQUEST_BYTES);
  if (bytes.byteLength !== expectedLength) {
    throw new InvalidRequestError();
  }

  let formData;
  try {
    formData = await new Response(bytes, {
      headers: { "Content-Type": request.headers.get("Content-Type") },
    }).formData();
  } catch {
    throw new InvalidRequestError();
  }

  const reports = [];
  const files = [];
  for (const [name, value] of formData.entries()) {
    if (name === "report") {
      reports.push(value);
    } else if (name === "screenshot") {
      files.push(value);
    } else {
      throw new InvalidRequestError();
    }
  }

  if (reports.length !== 1 || typeof reports[0] !== "string" || files.length > MAX_V2_SCREENSHOT_COUNT) {
    throw new InvalidRequestError();
  }

  const reportText = reports[0];
  if (textEncoder.encode(reportText).byteLength > MAX_V2_REPORT_BYTES) {
    throw new InvalidRequestError();
  }

  let report;
  try {
    report = validateV2Report(JSON.parse(reportText));
  } catch {
    throw new InvalidRequestError();
  }

  let aggregateSize = 0;
  const screenshots = [];
  for (const [index, file] of files.entries()) {
    if (!isMultipartFile(file) || file.type.toLowerCase() !== "image/png") {
      throw new InvalidRequestError();
    }

    if (!Number.isSafeInteger(file.size) || file.size < 1 || file.size > MAX_V2_SCREENSHOT_BYTES) {
      throw new InvalidRequestError();
    }

    let sourceBytes;
    try {
      sourceBytes = new Uint8Array(await file.arrayBuffer());
    } catch {
      throw new InvalidRequestError();
    }

    if (sourceBytes.byteLength !== file.size || sourceBytes.byteLength > MAX_V2_SCREENSHOT_BYTES) {
      throw new InvalidRequestError();
    }

    aggregateSize += sourceBytes.byteLength;
    if (aggregateSize > MAX_V2_SCREENSHOT_TOTAL_BYTES) {
      throw new InvalidRequestError();
    }

    screenshots.push({ data: base64Url(sourceBytes), slot: index + 1 });
  }

  return validateV2Submission({ kind: "v2", idempotencyKey, report, screenshots });
}

/** Validate a JSON-serializable v2 submission before it reaches R2 or GitHub. */
export function validateV2Submission(value) {
  if (
    !isV2Submission(value) ||
    !hasExactKeys(value, ["kind", "idempotencyKey", "report", "screenshots"], [
      "kind",
      "idempotencyKey",
      "report",
      "screenshots",
    ]) ||
    !Array.isArray(value.screenshots) ||
    value.screenshots.length > MAX_V2_SCREENSHOT_COUNT
  ) {
    throw new InvalidRequestError();
  }

  const report = validateV2Report(value.report);
  const idempotencyKey = validateIdempotencyKey(value.idempotencyKey);
  let aggregateSize = 0;
  const screenshots = [];
  for (const [index, screenshot] of value.screenshots.entries()) {
    if (
      !isPlainObject(screenshot) ||
      !hasExactKeys(screenshot, ["data", "slot"], ["data", "slot"]) ||
      screenshot.slot !== index + 1 ||
      typeof screenshot.data !== "string" ||
      screenshot.data.length > maximumBase64UrlLength(MAX_V2_SCREENSHOT_BYTES)
    ) {
      throw new InvalidRequestError();
    }

    const bytes = base64UrlToBytes(screenshot.data);
    if (bytes.byteLength > MAX_V2_SCREENSHOT_BYTES) {
      throw new InvalidRequestError();
    }

    aggregateSize += bytes.byteLength;
    if (aggregateSize > MAX_V2_SCREENSHOT_TOTAL_BYTES) {
      throw new InvalidRequestError();
    }

    screenshots.push({ data: base64Url(bytes), slot: screenshot.slot });
  }

  return { kind: "v2", idempotencyKey, report, screenshots };
}

/** Canonicalize every attachment immediately before R2 receives it. */
async function canonicalizeV2Submission(value) {
  const validatedSubmission = validateV2Submission(value);
  const screenshots = [];
  let aggregateSize = 0;

  for (const screenshot of validatedSubmission.screenshots) {
    const canonical = await canonicalizePng(base64UrlToBytes(screenshot.data));
    if (canonical.byteLength > MAX_V2_SCREENSHOT_BYTES) {
      throw new InvalidRequestError();
    }

    aggregateSize += canonical.byteLength;
    if (aggregateSize > MAX_V2_SCREENSHOT_TOTAL_BYTES) {
      throw new InvalidRequestError();
    }

    screenshots.push({ data: base64Url(canonical), slot: screenshot.slot });
  }

  return { ...validatedSubmission, screenshots };
}

/**
 * Keep just the image-defining PNG chunks, dropping validated metadata while rejecting malformed
 * or unsupported chunks. Native apps already re-encode picked images; this is the server-side
 * trust boundary before any public object is stored.
 */
export async function canonicalizePng(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  if (bytes.byteLength < PNG_SIGNATURE.byteLength || !bytesEqual(bytes.subarray(0, 8), PNG_SIGNATURE)) {
    throw new InvalidRequestError();
  }

  let offset = PNG_SIGNATURE.byteLength;
  let ihdr = null;
  let imageInfo = null;
  const idatChunks = [];
  let idatLength = 0;
  let sawIDAT = false;
  let closedIDAT = false;

  while (offset < bytes.byteLength) {
    if (bytes.byteLength - offset < 12) {
      throw new InvalidRequestError();
    }

    const length = readUint32(bytes, offset);
    const typeBytes = bytes.subarray(offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    const crcOffset = dataEnd;
    if (dataEnd > bytes.byteLength - 4 || crcOffset + 4 > bytes.byteLength) {
      throw new InvalidRequestError();
    }

    const data = bytes.subarray(dataStart, dataEnd);
    const expectedCRC = readUint32(bytes, crcOffset);
    if (crc32(typeBytes, data) !== expectedCRC) {
      throw new InvalidRequestError();
    }

    const type = latin1(typeBytes);
    if (!ihdr && type !== "IHDR") {
      throw new InvalidRequestError();
    }

    if (type === "IHDR") {
      if (ihdr || length !== 13 || offset !== PNG_SIGNATURE.byteLength) {
        throw new InvalidRequestError();
      }
      imageInfo = validatePngIHDR(data);
      ihdr = new Uint8Array(data);
    } else if (type === "IDAT") {
      if (!ihdr || closedIDAT || length === 0) {
        throw new InvalidRequestError();
      }
      sawIDAT = true;
      idatLength += data.byteLength;
      if (idatLength > MAX_V2_SCREENSHOT_BYTES) {
        throw new InvalidRequestError();
      }
      idatChunks.push(new Uint8Array(data));
    } else if (type === "IEND") {
      if (!ihdr || !sawIDAT || length !== 0 || crcOffset + 4 !== bytes.byteLength) {
        throw new InvalidRequestError();
      }

      const scanlines = await decodedPngScanlines(concatenateBytes(...idatChunks), imageInfo);
      const canonicalIDAT = await deflatePngScanlines(scanlines);
      return concatenateBytes(
        PNG_SIGNATURE,
        pngChunk(PNG_IHDR, ihdr),
        pngChunk(PNG_IDAT, canonicalIDAT),
        pngChunk(PNG_IEND, new Uint8Array()),
      );
    } else if (!STRIPPABLE_PNG_METADATA_TYPES.has(type)) {
      throw new InvalidRequestError();
    } else if (sawIDAT) {
      closedIDAT = true;
    }

    offset = crcOffset + 4;
  }

  throw new InvalidRequestError();
}

function validatePngIHDR(data) {
  const width = readUint32(data, 0);
  const height = readUint32(data, 4);
  if (
    width < 1 ||
    width > 2560 ||
    height < 1 ||
    height > 2560 ||
    data[8] !== 8 ||
    data[9] !== 6 ||
    data[10] !== 0 ||
    data[11] !== 0 ||
    data[12] !== 0
  ) {
    throw new InvalidRequestError();
  }

  return { width, height };
}

/** Decode a PNG's single RGBA scanline plane without allowing a compressed-data expansion. */
async function decodedPngScanlines(idat, imageInfo) {
  if (!imageInfo) {
    throw new InvalidRequestError();
  }

  const rowLength = 1 + imageInfo.width * 4;
  const expectedLength = imageInfo.height * rowLength;
  const stream = new Blob([idat]).stream().pipeThrough(new DecompressionStream("deflate"));
  const scanlines = await readBoundedStream(stream, expectedLength, expectedLength);

  for (let offset = 0; offset < scanlines.byteLength; offset += rowLength) {
    if (scanlines[offset] > 4) {
      throw new InvalidRequestError();
    }
  }

  return scanlines;
}

/** Recompress validated scanlines so no source compressed bytes reach private R2. */
async function deflatePngScanlines(scanlines) {
  const stream = new Blob([scanlines]).stream().pipeThrough(new CompressionStream("deflate"));
  return readBoundedStream(stream, MAX_V2_SCREENSHOT_BYTES);
}

/** Read a web stream within an exact or maximum byte budget. */
async function readBoundedStream(stream, maximumLength, expectedLength = null) {
  if (!stream || typeof stream.getReader !== "function") {
    throw new InvalidRequestError();
  }

  const reader = stream.getReader();
  const chunks = [];
  let totalLength = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      if (!(value instanceof Uint8Array)) {
        throw new InvalidRequestError();
      }

      totalLength += value.byteLength;
      if (totalLength > maximumLength) {
        await reader.cancel();
        throw new InvalidRequestError();
      }

      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof InvalidRequestError) {
      throw error;
    }

    throw new InvalidRequestError();
  } finally {
    reader.releaseLock();
  }

  if (expectedLength !== null && totalLength !== expectedLength) {
    throw new InvalidRequestError();
  }

  return concatenateBytes(...chunks);
}

function pngChunk(type, data) {
  return concatenateBytes(uint32Bytes(data.byteLength), type, data, uint32Bytes(crc32(type, data)));
}

function readUint32(bytes, offset) {
  if (offset < 0 || offset + 4 > bytes.byteLength) {
    throw new InvalidRequestError();
  }

  return bytes[offset] * 0x1000000 + bytes[offset + 1] * 0x10000 + bytes[offset + 2] * 0x100 + bytes[offset + 3];
}

function uint32Bytes(value) {
  return Uint8Array.of((value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff);
}

function latin1(bytes) {
  return String.fromCharCode(...bytes);
}

function crc32(...values) {
  let crc = 0xffffffff;
  for (const value of values) {
    for (const byte of value) {
      crc = CRC32_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
    }
  }

  return (crc ^ 0xffffffff) >>> 0;
}

function createCRC32Table() {
  const table = new Uint32Array(256);
  for (let value = 0; value < table.length; value += 1) {
    let crc = value;
    for (let index = 0; index < 8; index += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    table[value] = crc >>> 0;
  }

  return table;
}

function bytesEqual(left, right) {
  return left.byteLength === right.byteLength && left.every((value, index) => value === right[index]);
}

function maximumBase64UrlLength(byteLength) {
  return Math.ceil((byteLength * 4) / 3);
}

function base64UrlToBytes(value) {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) {
    throw new InvalidRequestError();
  }

  try {
    const padded = `${value}${"=".repeat((4 - (value.length % 4)) % 4)}`.replace(/-/gu, "+").replace(/_/gu, "/");
    return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
  } catch {
    throw new InvalidRequestError();
  }
}

function requiredV2ContentLength(value) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/u.test(value)) {
    throw new InvalidRequestError();
  }

  const length = Number(value);
  if (!Number.isSafeInteger(length) || length < 1 || length > MAX_V2_REQUEST_BYTES) {
    throw new InvalidRequestError();
  }

  return length;
}

async function readBoundedBody(request, maximumLength = MAX_BODY_BYTES) {
  if (!request.body) {
    return new Uint8Array();
  }

  const reader = request.body.getReader();
  const chunks = [];
  let totalLength = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      if (!(value instanceof Uint8Array)) {
        throw new InvalidRequestError();
      }

      totalLength += value.byteLength;
      if (totalLength > maximumLength) {
        await reader.cancel();
        throw new InvalidRequestError();
      }

      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof InvalidRequestError) {
      throw error;
    }

    throw new InvalidRequestError();
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return bytes;
}

function validateIdempotencyKey(value) {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new InvalidRequestError();
  }

  return value.toLowerCase();
}

function isJsonContentType(value) {
  if (typeof value !== "string" || !value) {
    return false;
  }

  const [mediaType, ...parameters] = value.split(";");
  if (mediaType.trim().toLowerCase() !== "application/json") {
    return false;
  }

  return parameters.every((parameter) => {
    const separator = parameter.indexOf("=");
    if (separator === -1) {
      return false;
    }

    const name = parameter.slice(0, separator).trim().toLowerCase();
    const rawValue = parameter.slice(separator + 1).trim();
    const parameterValue = rawValue.replace(/^"|"$/gu, "").toLowerCase();
    return name !== "charset" || parameterValue === "utf-8";
  });
}

function isMultipartContentType(value) {
  if (typeof value !== "string" || !value) {
    return false;
  }

  const [mediaType, ...parameters] = value.split(";");
  if (mediaType.trim().toLowerCase() !== "multipart/form-data") {
    return false;
  }

  return parameters.some((parameter) => {
    const separator = parameter.indexOf("=");
    if (separator === -1) {
      return false;
    }

    const name = parameter.slice(0, separator).trim().toLowerCase();
    const boundary = parameter.slice(separator + 1).trim().replace(/^"|"$/gu, "");
    return name === "boundary" && boundary.length > 0;
  });
}

function isIdentityContentEncoding(value) {
  return !value || value.trim().toLowerCase() === "identity";
}

function isMultipartFile(value) {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof value.arrayBuffer === "function" &&
    typeof value.type === "string" &&
    Number.isSafeInteger(value.size)
  );
}

function isV2Submission(value) {
  return isPlainObject(value) && value.kind === "v2";
}

async function fetchV2Media(request, env, pathname) {
  const match = pathname.match(
    new RegExp(`^${V2_MEDIA_PATH_PREFIX}(${UUID_PATTERN.source.slice(1, -1)})/([1-3])$`, "i"),
  );
  if (!match) {
    return mediaNotFoundResponse();
  }

  if (request.method !== "GET") {
    return errorResponse("invalid_request", 405, { Allow: "GET" });
  }

  const bucket = env?.BUG_REPORT_MEDIA;
  if (!bucket || typeof bucket.get !== "function") {
    return errorResponse("unavailable", 503);
  }

  try {
    const object = await bucket.get(v2MediaKey(match[1].toLowerCase(), Number(match[2])));
    const body = object && typeof object === "object" && "body" in object ? object.body : object;
    if (!body) {
      return mediaNotFoundResponse();
    }

    return new Response(body, {
      headers: {
        "Cache-Control": "public, max-age=300",
        "Content-Type": "image/png",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    return errorResponse("unavailable", 503);
  }
}

function mediaNotFoundResponse() {
  return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
}

function v2MediaKey(idempotencyKey, slot) {
  return `bug-report-media/${idempotencyKey}/screenshot-${slot}.png`;
}

function publicMediaURL(idempotencyKey, slot) {
  return `${MEDIA_PUBLIC_ORIGIN}${V2_MEDIA_PATH_PREFIX}${idempotencyKey}/${slot}`;
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value, requiredKeys, allowedKeys) {
  const keys = Object.keys(value);
  return (
    requiredKeys.every((key) => Object.hasOwn(value, key)) &&
    keys.every((key) => allowedKeys.includes(key))
  );
}

function normalizedText(value, maximumLength, required, { compact = false } = {}) {
  if (typeof value !== "string") {
    throw new InvalidRequestError();
  }

  const normalized = value.normalize("NFC").replace(/\r\n?/gu, "\n");
  if (DISALLOWED_CONTROL_CHARACTERS.test(normalized)) {
    throw new InvalidRequestError();
  }

  const trimmed = normalized.trim();
  if (required && !trimmed) {
    throw new InvalidRequestError();
  }

  const result = compact ? trimmed.replace(/\s+/gu, " ") : trimmed;
  if (Array.from(result).length > maximumLength) {
    throw new InvalidRequestError();
  }

  return result;
}

function enumValue(value, allowedValues) {
  if (typeof value !== "string" || !allowedValues.has(value)) {
    throw new InvalidRequestError();
  }

  return value;
}

function safeIssueTitle(summary) {
  return summary.replace(/@/gu, "＠").replace(/\s+/gu, " ").trim();
}

function fencedText(value) {
  const backtickRuns = value.match(/`+/gu) ?? [];
  const delimiterLength = Math.max(4, ...backtickRuns.map((run) => run.length + 1));
  const delimiter = "`".repeat(delimiterLength);
  return `${delimiter}text\n${value}\n${delimiter}`;
}

function jsonResponse(value, status, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}

function errorResponse(code, status, extraHeaders = {}) {
  return jsonResponse({ error: code }, status, extraHeaders);
}

async function parseIssueReceipt(response) {
  let value;
  try {
    value = await response.json();
  } catch {
    return null;
  }

  if (!Number.isSafeInteger(value?.issue?.number) || value.issue.number < 1) {
    return null;
  }

  return canonicalIssueReceipt(value.issue.number);
}

function canonicalIssueReceipt(number) {
  return {
    number,
    url: `${GITHUB_ISSUE_URL_PREFIX}${number}`,
  };
}

function receiptResultFor(receipt, payloadHash) {
  return receipt.payloadHash === payloadHash
    ? { status: 200, issue: receipt.issue }
    : { status: 400 };
}

function isStoredReceipt(value) {
  return (
    isPlainObject(value) &&
    typeof value.payloadHash === "string" &&
    Number.isFinite(value.expiresAt) &&
    Number.isSafeInteger(value.issue?.number) &&
    value.issue.number > 0 &&
    typeof value.issue.url === "string"
  );
}

function isStoredPendingSubmission(value) {
  return (
    isPlainObject(value) &&
    typeof value.payloadHash === "string" &&
    Number.isFinite(value.expiresAt) &&
    (value.outcome === undefined || value.outcome === "uncertain")
  );
}

async function fingerprintReport(submission) {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(JSON.stringify(submission)));
  return base64Url(new Uint8Array(digest));
}

function requiredSecret(env, name) {
  const value = env?.[name];
  if (typeof value !== "string" || !value.trim()) {
    throw new ServiceUnavailableError();
  }

  return value;
}

function pemToPkcs8(pem) {
  if (typeof pem !== "string") {
    throw new ServiceUnavailableError();
  }

  const match = pem
    .trim()
    .match(/^-----BEGIN (RSA PRIVATE KEY|PRIVATE KEY)-----\s*([\s\S]*?)\s*-----END \1-----$/u);
  if (!match) {
    throw new ServiceUnavailableError();
  }

  const base64 = match[2].replace(/\s+/gu, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(base64)) {
    throw new ServiceUnavailableError();
  }

  let binary;
  try {
    binary = atob(base64);
  } catch {
    throw new ServiceUnavailableError();
  }

  const keyBytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return match[1] === "RSA PRIVATE KEY" ? pkcs1ToPkcs8(keyBytes) : keyBytes;
}

function pkcs1ToPkcs8(pkcs1) {
  const version = Uint8Array.of(0x02, 0x01, 0x00);
  const rsaEncryptionAlgorithm = Uint8Array.of(
    0x30,
    0x0d,
    0x06,
    0x09,
    0x2a,
    0x86,
    0x48,
    0x86,
    0xf7,
    0x0d,
    0x01,
    0x01,
    0x01,
    0x05,
    0x00,
  );
  const privateKey = concatenateBytes(Uint8Array.of(0x04), derLength(pkcs1.length), pkcs1);
  const payload = concatenateBytes(version, rsaEncryptionAlgorithm, privateKey);
  return concatenateBytes(Uint8Array.of(0x30), derLength(payload.length), payload);
}

function derLength(length) {
  if (length < 0x80) {
    return Uint8Array.of(length);
  }

  const bytes = [];
  let remaining = length;
  while (remaining > 0) {
    bytes.unshift(remaining & 0xff);
    remaining >>>= 8;
  }

  return Uint8Array.of(0x80 | bytes.length, ...bytes);
}

function concatenateBytes(...values) {
  const length = values.reduce((total, value) => total + value.length, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.length;
  }

  return result;
}

function base64Url(value) {
  let binary = "";
  for (const byte of value) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replace(/=/gu, "").replace(/\+/gu, "-").replace(/\//gu, "_");
}

export default createWorker();
