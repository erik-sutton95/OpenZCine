import assert from "node:assert/strict";
import test from "node:test";

import {
  createAppJwt,
  createGitHubIssue,
  createWorker,
  InvalidRequestError,
  ReceiptCoordinator,
  renderIssue,
  ServiceUnavailableError,
  validateReport,
} from "../src/worker.mjs";

const IDEMPOTENCY_KEY = "123e4567-e89b-12d3-a456-426614174000";

function validReport(overrides = {}) {
  const context = {
    platform: "ios",
    appVersion: "1.2.3",
    buildNumber: "42",
    osVersion: "iOS 18.0",
    deviceClass: "phone",
    connection: "wifi",
    ...overrides.context,
  };

  return {
    schemaVersion: 1,
    summary: "Live view freezes",
    whatHappened: "The preview stopped updating after connecting to the camera.",
    frequency: "sometimes",
    context,
    ...overrides,
  };
}

function reportRequest({ method = "POST", body = validReport(), headers = {} } = {}) {
  const requestHeaders = new Headers({
    "CF-Connecting-IP": "203.0.113.50",
    "Content-Type": "application/json; charset=utf-8",
    "Idempotency-Key": IDEMPOTENCY_KEY,
    ...headers,
  });

  return new Request("https://reports.openzcine.app/v1/bug-reports", {
    method,
    headers: requestHeaders,
    body:
      method === "POST"
        ? typeof body === "string" || body instanceof Uint8Array
          ? body
          : JSON.stringify(body)
        : undefined,
  });
}

function fakeEnvironment({ limiterResult = { success: true }, relayResponse, onRelayFetch } = {}) {
  const defaultRelayResponse = new Response(
    JSON.stringify({ issue: { number: 73, url: "https://github.com/ignored/issue/73" } }),
    { status: 201, headers: { "Content-Type": "application/json" } },
  );
  const state = { limitCalls: 0, relayCalls: 0 };

  return {
    state,
    env: {
      BUG_REPORT_RATE_LIMITER: {
        async limit() {
          state.limitCalls += 1;
          return limiterResult;
        },
      },
      BUG_REPORT_IDEMPOTENCY: {
        idFromName(value) {
          return value;
        },
        get() {
          return {
            async fetch(url, options) {
              state.relayCalls += 1;
              onRelayFetch?.(url, options);
              return relayResponse ?? defaultRelayResponse;
            },
          };
        },
      },
    },
  };
}

class MemoryStorage {
  constructor() {
    this.values = new Map();
    this.alarms = [];
  }

  async get(key) {
    return this.values.get(key);
  }

  async put(key, value) {
    this.values.set(key, value);
  }

  async delete(key) {
    this.values.delete(key);
  }

  async setAlarm(time) {
    this.alarms.push(time);
  }
}

test("strictly validates required fields, unknown fields, and character lengths", () => {
  const normalized = validateReport(
    validReport({
      summary: "  Preview\n  freezes  ",
      stepsToReproduce: "  Connect\nOpen Live View  ",
    }),
  );

  assert.equal(normalized.summary, "Preview freezes");
  assert.equal(normalized.stepsToReproduce, "Connect\nOpen Live View");
  assert.throws(
    () => validateReport(validReport({ unexpected: "nope" })),
    InvalidRequestError,
  );
  assert.throws(
    () => validateReport(validReport({ context: { unknown: "nope" } })),
    InvalidRequestError,
  );
  assert.throws(
    () => validateReport(validReport({ summary: " " })),
    InvalidRequestError,
  );
  assert.throws(
    () => validateReport(validReport({ summary: "a".repeat(121) })),
    InvalidRequestError,
  );
  assert.throws(
    () => validateReport(validReport({ frequency: "frequently" })),
    InvalidRequestError,
  );
});

test("rejects control characters and fences untrusted Markdown safely", () => {
  assert.throws(
    () => validateReport(validReport({ whatHappened: "Preview\u0007 froze" })),
    InvalidRequestError,
  );

  const rendered = renderIssue(
    validReport({
      summary: "@maintainer preview froze",
      whatHappened: "Saw @octocat\n````\n# pretend heading",
    }),
  );

  assert.equal(rendered.title, "[iOS] ＠maintainer preview froze");
  assert.ok(
    rendered.body.includes("`````text\nSaw @octocat\n````\n# pretend heading\n`````"),
    "a fence longer than embedded backticks keeps user Markdown inert",
  );
  assert.match(rendered.body, /submitted without an account and is public/u);
});

test("rejects non-POST methods and non-JSON media types", async () => {
  const worker = createWorker();
  const { env } = fakeEnvironment();

  const getResponse = await worker.fetch(
    reportRequest({ method: "GET", headers: { "Content-Type": "text/plain" } }),
    env,
  );
  assert.equal(getResponse.status, 405);
  assert.equal(getResponse.headers.get("Allow"), "POST");
  assert.deepEqual(await getResponse.json(), { error: "invalid_request" });

  const mediaTypeResponse = await worker.fetch(
    reportRequest({ headers: { "Content-Type": "text/plain" } }),
    env,
  );
  assert.equal(mediaTypeResponse.status, 415);
  assert.deepEqual(await mediaTypeResponse.json(), { error: "invalid_request" });
});

test("rejects malformed UTF-8 and bodies larger than 12 KiB before relaying", async () => {
  const worker = createWorker();
  const { env, state } = fakeEnvironment();
  const invalidUtf8 = reportRequest({ body: new Uint8Array([0xc3, 0x28]) });

  const invalidUtf8Response = await worker.fetch(invalidUtf8, env);
  assert.equal(invalidUtf8Response.status, 400);
  assert.deepEqual(await invalidUtf8Response.json(), { error: "invalid_request" });

  const tooLarge = reportRequest({ body: new Uint8Array(12 * 1024 + 1) });
  const tooLargeResponse = await worker.fetch(tooLarge, env);
  assert.equal(tooLargeResponse.status, 400);
  assert.deepEqual(await tooLargeResponse.json(), { error: "invalid_request" });
  assert.equal(state.limitCalls, 0);
});

test("returns a bounded response when the Cloudflare rate limiter rejects a report", async () => {
  const worker = createWorker();
  const { env, state } = fakeEnvironment({ limiterResult: { success: false } });

  const response = await worker.fetch(reportRequest(), env);
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("Retry-After"), "60");
  assert.deepEqual(await response.json(), { error: "rate_limited" });
  assert.equal(state.limitCalls, 1);
  assert.equal(state.relayCalls, 0);
});

test("returns a GitHub issue receipt on initial success without echoing report text", async () => {
  const worker = createWorker();
  let receivedReport;
  const { env, state } = fakeEnvironment({
    onRelayFetch(_url, options) {
      receivedReport = JSON.parse(options.body);
    },
  });

  const response = await worker.fetch(reportRequest(), env);
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), {
    issue: {
      number: 73,
      url: "https://github.com/erik-sutton95/OpenZCine/issues/73",
    },
  });
  assert.equal(state.limitCalls, 1);
  assert.equal(state.relayCalls, 1);
  assert.deepEqual(Object.keys(receivedReport).sort(), [
    "context",
    "frequency",
    "schemaVersion",
    "summary",
    "whatHappened",
  ]);
});

test("stores one receipt, retries its payload, and rejects a changed payload", async () => {
  const storage = new MemoryStorage();
  let issueCreations = 0;
  const coordinator = new ReceiptCoordinator({
    storage,
    now: () => 10_000,
    fingerprint: async (report) => JSON.stringify(report),
    async createIssue() {
      issueCreations += 1;
      return {
        number: 88,
        url: "https://github.com/erik-sutton95/OpenZCine/issues/88",
      };
    },
  });
  const report = validateReport(validReport());

  const created = await coordinator.submit(report);
  const retried = await coordinator.submit(report);
  const changedPayload = await coordinator.submit(
    validateReport(validReport({ summary: "Recording controls stopped responding" })),
  );

  assert.equal(created.status, 201);
  assert.equal(retried.status, 200);
  assert.equal(changedPayload.status, 400);
  assert.deepEqual(retried.issue, created.issue);
  assert.equal(issueCreations, 1);
  assert.equal(storage.alarms.length, 1);
});

test("uses the exact labels and maps GitHub failures to an unavailable response", async () => {
  let requestOptions;
  const issue = await createGitHubIssue({}, validReport(), {
    async getToken() {
      return "installation-token";
    },
    async fetchImpl(_url, options) {
      requestOptions = options;
      return new Response(JSON.stringify({ number: 91 }), {
        status: 201,
        headers: { "Content-Type": "application/json" },
      });
    },
  });

  assert.deepEqual(issue, {
    number: 91,
    url: "https://github.com/erik-sutton95/OpenZCine/issues/91",
  });
  assert.deepEqual(JSON.parse(requestOptions.body).labels, ["bug", "needs-triage", "source:anonymous"]);

  await assert.rejects(
    () =>
      createGitHubIssue({}, validReport(), {
        async getToken() {
          return "installation-token";
        },
        async fetchImpl() {
          return new Response(JSON.stringify({ message: "do not expose this" }), { status: 500 });
        },
      }),
    ServiceUnavailableError,
  );

  const worker = createWorker();
  const { env } = fakeEnvironment({
    relayResponse: new Response(JSON.stringify({ message: "do not expose this" }), { status: 500 }),
  });
  const response = await worker.fetch(reportRequest(), env);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "unavailable" });
});

test("signs a short GitHub App RS256 JWT with Web Crypto", async () => {
  const keyPair = await globalThis.crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await globalThis.crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
  const encoded = Buffer.from(pkcs8).toString("base64").match(/.{1,64}/gu).join("\n");
  const privateKey = `-----BEGIN PRIVATE KEY-----\n${encoded}\n-----END PRIVATE KEY-----`;

  const jwt = await createAppJwt("123", privateKey, 1_000_000);
  const [header, payload, signature] = jwt.split(".");
  const decodedPayload = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));

  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString("utf8")), {
    alg: "RS256",
    typ: "JWT",
  });
  assert.equal(decodedPayload.iss, "123");
  assert.equal(decodedPayload.exp - decodedPayload.iat, 9 * 60);
  assert.equal(
    await globalThis.crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      keyPair.publicKey,
      Buffer.from(signature, "base64url"),
      new TextEncoder().encode(`${header}.${payload}`),
    ),
    true,
  );
});
