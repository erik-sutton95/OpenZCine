const API_PATH = "/v1/bug-reports";
const MAX_BODY_BYTES = 12 * 1024;
const RECEIPT_KEY = "receipt";
const RECEIPT_TTL_MS = 24 * 60 * 60 * 1000;
const GITHUB_OWNER = "erik-sutton95";
const GITHUB_REPOSITORY = "OpenZCine";
const GITHUB_API_URL = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/issues`;
const GITHUB_ISSUE_URL_PREFIX = `https://github.com/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/issues/`;

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

      if (url.pathname !== API_PATH) {
        return errorResponse("invalid_request", 404);
      }

      if (request.method !== "POST") {
        return errorResponse("invalid_request", 405, { Allow: "POST" });
      }

      if (!isJsonContentType(request.headers.get("Content-Type"))) {
        return errorResponse("invalid_request", 415);
      }

      if (!isIdentityContentEncoding(request.headers.get("Content-Encoding"))) {
        return errorResponse("invalid_request", 415);
      }

      let idempotencyKey;
      let report;
      try {
        idempotencyKey = validateIdempotencyKey(request.headers.get("Idempotency-Key"));
        report = await parseReportBody(request);
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

      try {
        const id = env.BUG_REPORT_IDEMPOTENCY.idFromName(idempotencyKey);
        const stub = env.BUG_REPORT_IDEMPOTENCY.get(id);
        const response = await stub.fetch("https://bug-report-idempotency.internal/submit", {
          method: "POST",
          headers: { "Content-Type": "application/json; charset=utf-8" },
          body: JSON.stringify(report),
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
 * Cloudflare Durable Object that serializes an idempotency key and persists a receipt for 24 hours.
 */
export class BugReportIdempotency {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.coordinator = new ReceiptCoordinator({
      storage: ctx.storage,
      createIssue: (report) => createGitHubIssue(env, report),
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/submit") {
      return errorResponse("invalid_request", 400);
    }

    try {
      const report = validateReport(await request.json());
      const result = await this.coordinator.submit(report);

      if (result.status === 400) {
        return errorResponse("invalid_request", 400);
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
    if (!isStoredReceipt(receipt) || receipt.expiresAt <= Date.now()) {
      await this.ctx.storage.delete(RECEIPT_KEY);
      return;
    }

    await this.ctx.storage.setAlarm(receipt.expiresAt);
  }
}

/**
 * Storage-backed idempotency state machine used by the Durable Object and unit tests.
 */
export class ReceiptCoordinator {
  constructor({ storage, createIssue, now = () => Date.now(), fingerprint = fingerprintReport }) {
    this.storage = storage;
    this.createIssue = createIssue;
    this.now = now;
    this.fingerprint = fingerprint;
    this.inFlight = null;
  }

  async submit(report) {
    const payloadHash = await this.fingerprint(report);
    const current = await this.currentReceipt();

    if (current) {
      return receiptResultFor(current, payloadHash);
    }

    if (this.inFlight) {
      const result = await this.inFlight;
      return result.payloadHash === payloadHash
        ? { status: 200, issue: result.issue }
        : { status: 400 };
    }

    const operation = this.createAndStore(report, payloadHash);
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

  async createAndStore(report, payloadHash) {
    const current = await this.currentReceipt();
    if (current) {
      const result = receiptResultFor(current, payloadHash);
      if (result.status === 400) {
        throw new InvalidRequestError();
      }

      return { payloadHash, issue: result.issue };
    }

    const issue = await this.createIssue(report);
    const receipt = {
      expiresAt: this.now() + RECEIPT_TTL_MS,
      issue,
      payloadHash,
    };

    await this.storage.put(RECEIPT_KEY, receipt);
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
}

/**
 * Validate and normalize the intentionally narrow public report schema.
 */
export function validateReport(value) {
  if (!isPlainObject(value) || !hasExactKeys(value, ROOT_REQUIRED_KEYS, ROOT_ALLOWED_KEYS)) {
    throw new InvalidRequestError();
  }

  if (value.schemaVersion !== 1) {
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
    schemaVersion: 1,
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
  const safeReport = validateReport(report);
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

  return {
    title,
    body: [
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
    ].join("\n"),
  };
}

/**
 * Create a labelled GitHub issue using a short-lived GitHub App installation token.
 */
export async function createGitHubIssue(
  env,
  report,
  { fetchImpl = fetch, getToken = getInstallationToken } = {},
) {
  const rendered = renderIssue(report);
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
    throw new ServiceUnavailableError();
  }

  if (!response.ok) {
    throw new ServiceUnavailableError();
  }

  let issue;
  try {
    issue = await response.json();
  } catch {
    throw new ServiceUnavailableError();
  }

  if (!Number.isSafeInteger(issue?.number) || issue.number < 1) {
    throw new ServiceUnavailableError();
  }

  return canonicalIssueReceipt(issue.number);
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

async function readBoundedBody(request) {
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
      if (totalLength > MAX_BODY_BYTES) {
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

function isIdentityContentEncoding(value) {
  return !value || value.trim().toLowerCase() === "identity";
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

async function fingerprintReport(report) {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(JSON.stringify(report)));
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
