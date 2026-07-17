import assert from "node:assert/strict";
import test from "node:test";
import { deflateSync, inflateSync } from "node:zlib";

import {
  AmbiguousIssueCreationError,
  canonicalizePng,
  createAppJwt,
  createGitHubIssue,
  createV2GitHubIssue,
  createWorker,
  InvalidRequestError,
  ReceiptCoordinator,
  renderIssue,
  renderV2Issue,
  ServiceUnavailableError,
  validateReport,
  validateV2Report,
} from "../src/worker.mjs";

const REPORT_RETRY_UUID = "123e4567-e89b-12d3-a456-426614174000";

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

function validV2Report(overrides = {}) {
  const report = validReport({ schemaVersion: 2 });
  return {
    ...report,
    ...overrides,
    schemaVersion: 2,
    context: { ...report.context, ...overrides.context },
  };
}

function reportRequest({ method = "POST", body = validReport(), headers = {} } = {}) {
  const requestHeaders = new Headers({
    "CF-Connecting-IP": "203.0.113.50",
    "Content-Type": "application/json; charset=utf-8",
    "Idempotency-Key": REPORT_RETRY_UUID,
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

async function v2ReportRequest({
  report = validV2Report(),
  screenshots = [],
  headers = {},
  omitContentLength = false,
} = {}) {
  const form = new FormData();
  form.append("report", JSON.stringify(report));
  for (const screenshot of screenshots) {
    form.append(
      "screenshot",
      new Blob([screenshot.bytes], { type: screenshot.contentType ?? "image/png" }),
      screenshot.name ?? "untrusted-original-name.png",
    );
  }

  const encoded = new Request("https://reports.openzcine.app/v2/bug-reports", {
    method: "POST",
    body: form,
  });
  const body = new Uint8Array(await encoded.arrayBuffer());
  const requestHeaders = new Headers({
    "CF-Connecting-IP": "203.0.113.50",
    "Content-Type": encoded.headers.get("Content-Type"),
    "Idempotency-Key": REPORT_RETRY_UUID,
    ...headers,
  });
  if (!omitContentLength) {
    requestHeaders.set("Content-Length", String(body.byteLength));
  }

  return new Request("https://reports.openzcine.app/v2/bug-reports", {
    method: "POST",
    headers: requestHeaders,
    body,
  });
}

async function v2Submission({ report = validV2Report(), screenshots = [] } = {}) {
  const canonicalScreenshots = [];
  for (const [index, bytes] of screenshots.entries()) {
    canonicalScreenshots.push({
      data: Buffer.from(await canonicalizePng(bytes)).toString("base64url"),
      slot: index + 1,
    });
  }

  return {
    kind: "v2",
    idempotencyKey: REPORT_RETRY_UUID,
    report,
    screenshots: canonicalScreenshots,
  };
}

function rawV2Submission({
  report = validV2Report(),
  screenshots = [],
  idempotencyKey = REPORT_RETRY_UUID,
} = {}) {
  return {
    kind: "v2",
    idempotencyKey,
    report,
    screenshots: screenshots.map((bytes, index) => ({
      data: Buffer.from(bytes).toString("base64url"),
      slot: index + 1,
    })),
  };
}

function fakeEnvironment({ limiterResult = { success: true }, relayResponse, onRelayFetch, media } = {}) {
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
      BUG_REPORT_MEDIA:
        media ?? {
          async get() {
            return null;
          },
          async put() {},
          async delete() {},
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

function png({
  width = 1,
  height = 1,
  metadata = [],
  color = [0x44, 0x88, 0xcc, 0xff],
  idat = null,
  corruptCRC = false,
} = {}) {
  const scanlines = Buffer.alloc((width * 4 + 1) * Math.max(height, 1));
  for (let row = 0; row < height; row += 1) {
    scanlines[row * (width * 4 + 1)] = 0;
    for (let pixel = 0; pixel < width; pixel += 1) {
      const offset = row * (width * 4 + 1) + 1 + pixel * 4;
      scanlines[offset] = color[0];
      scanlines[offset + 1] = color[1];
      scanlines[offset + 2] = color[2];
      scanlines[offset + 3] = color[3];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.set([8, 6, 0, 0, 0], 8);
  const chunks = [
    pngChunk("IHDR", ihdr),
    ...metadata,
    pngChunk("IDAT", idat ?? deflateSync(scanlines)),
    pngChunk("IEND", Buffer.alloc(0)),
  ];
  const result = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), ...chunks]);
  if (corruptCRC) result[result.length - 1] ^= 0xff;
  return new Uint8Array(result);
}

function pngChunk(type, data) {
  const typeBytes = Buffer.from(type, "ascii");
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  typeBytes.copy(chunk, 4);
  Buffer.from(data).copy(chunk, 8);
  chunk.writeUInt32BE(crc32(typeBytes, data), 8 + data.length);
  return chunk;
}

function crc32(...values) {
  let crc = 0xffffffff;
  for (const value of values) {
    for (const byte of value) {
      crc ^= byte;
      for (let index = 0; index < 8; index += 1) {
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
      }
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunkTypes(bytes) {
  const types = [];
  let offset = 8;
  while (offset < bytes.byteLength) {
    const length = Buffer.from(bytes).readUInt32BE(offset);
    types.push(Buffer.from(bytes.subarray(offset + 4, offset + 8)).toString("ascii"));
    offset += length + 12;
  }
  return types;
}

function pngIDAT(bytes) {
  const chunks = [];
  let offset = 8;
  while (offset < bytes.byteLength) {
    const length = Buffer.from(bytes).readUInt32BE(offset);
    const type = Buffer.from(bytes.subarray(offset + 4, offset + 8)).toString("ascii");
    if (type === "IDAT") {
      chunks.push(Buffer.from(bytes.subarray(offset + 8, offset + 8 + length)));
    }
    offset += length + 12;
  }
  return Buffer.concat(chunks);
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

test("rate limits malformed v1 bodies before rejecting them without relaying", async () => {
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
  assert.equal(state.limitCalls, 2);
  assert.equal(state.relayCalls, 0);
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

test("v2 requires a fixed-length multipart body after rate limiting and before relaying", async () => {
  const worker = createWorker();
  const { env, state } = fakeEnvironment();
  const screenshot = png();

  const missingLength = await worker.fetch(
    await v2ReportRequest({ screenshots: [{ bytes: screenshot }], omitContentLength: true }),
    env,
  );
  assert.equal(missingLength.status, 400);

  const tooLarge = await worker.fetch(
    new Request("https://reports.openzcine.app/v2/bug-reports", {
      method: "POST",
      headers: {
        "CF-Connecting-IP": "203.0.113.50",
        "Content-Length": String(3 * 1_048_576 + 64 * 1024 + 1),
        "Content-Type": "multipart/form-data; boundary=bounded",
        "Idempotency-Key": REPORT_RETRY_UUID,
      },
      body: new Uint8Array([1]),
    }),
    env,
  );
  assert.equal(tooLarge.status, 400);
  assert.equal(state.limitCalls, 2);
  assert.equal(state.relayCalls, 0);
});

test("rate limits a malformed v2 upload before parsing its multipart body", async () => {
  const worker = createWorker();
  const { env, state } = fakeEnvironment({ limiterResult: { success: false } });

  const response = await worker.fetch(
    new Request("https://reports.openzcine.app/v2/bug-reports", {
      method: "POST",
      headers: {
        "CF-Connecting-IP": "203.0.113.50",
        "Content-Length": "1",
        "Content-Type": "multipart/form-data; boundary=bounded",
        "Idempotency-Key": REPORT_RETRY_UUID,
      },
      body: new Uint8Array([1]),
    }),
    env,
  );

  assert.equal(response.status, 429);
  assert.deepEqual(await response.json(), { error: "rate_limited" });
  assert.equal(state.limitCalls, 1);
  assert.equal(state.relayCalls, 0);
});

test("v2 relays only closed activity events with an opaque attachment contract", async () => {
  const worker = createWorker();
  let receivedSubmission;
  const { env, state } = fakeEnvironment({
    onRelayFetch(_url, options) {
      receivedSubmission = JSON.parse(options.body);
    },
  });
  const response = await worker.fetch(
    await v2ReportRequest({
      report: validV2Report({ activityLog: ["app.launched", "live-view.started"] }),
      screenshots: [{ bytes: png(), name: "Bob's iPhone.png" }],
    }),
    env,
  );

  assert.equal(response.status, 201);
  assert.equal(state.limitCalls, 1);
  assert.equal(receivedSubmission.kind, "v2");
  assert.equal(receivedSubmission.idempotencyKey, REPORT_RETRY_UUID);
  assert.deepEqual(receivedSubmission.report.activityLog, ["app.launched", "live-view.started"]);
  assert.equal(receivedSubmission.screenshots.length, 1);
  assert.equal(receivedSubmission.screenshots[0].slot, 1);
});

test("v2 accepts closed incidents and renders fixed privacy-safe operational traces", async () => {
  const rendered = await renderV2Issue(
    await v2Submission({
      report: validV2Report({
        activityLog: [
          "connection.connected",
          "warning.live-view.stalled",
          "error.connection.event-channel-ended",
          "connection.disconnected",
        ],
      }),
    }),
  );

  assert.match(rendered.body, /\[WARNING\] warning\.live-view\.stalled/u);
  assert.match(
    rendered.body,
    /at live-view\.streaming\n    at frame-delivery\.stalled\n    at live-view\.restart/u,
  );
  assert.match(rendered.body, /\[ERROR\] error\.connection\.event-channel-ended/u);
  assert.equal(rendered.body.includes("exception message"), false);
  assert.equal(rendered.body.includes("\/private\/"), false);
});

test("canonicalizes only a zlib-decoded RGBA image plane", async () => {
  const valid = await canonicalizePng(png());
  assert.deepEqual(pngChunkTypes(valid), ["IHDR", "IDAT", "IEND"]);
  assert.deepEqual([...inflateSync(pngIDAT(valid))], [0, 0x44, 0x88, 0xcc, 0xff]);

  await assert.rejects(
    () => canonicalizePng(png({ idat: Buffer.from("Bob's iPhone", "utf8") })),
    InvalidRequestError,
  );
});

test("rejects malformed PNGs at the R2 storage boundary", async () => {
  const malformedImages = [
    png({ corruptCRC: true }),
    png({ width: 2561 }),
    png({ idat: Buffer.from("Bob's iPhone", "utf8") }),
  ];

  for (const image of malformedImages) {
    await assert.rejects(
      () => createV2GitHubIssue({}, rawV2Submission({ screenshots: [image] })),
      InvalidRequestError,
    );
  }
});

test("v2 rejects arbitrary activity text and oversized uploads after rate limiting", async () => {
  const worker = createWorker();
  const { env, state } = fakeEnvironment();

  const arbitraryLog = await worker.fetch(
    await v2ReportRequest({ report: validV2Report({ activityLog: ["Bob's iPhone"] }) }),
    env,
  );
  assert.equal(arbitraryLog.status, 400);

  const oversizedScreenshot = await worker.fetch(
    await v2ReportRequest({ screenshots: [{ bytes: new Uint8Array(1_048_577) }] }),
    env,
  );
  assert.equal(oversizedScreenshot.status, 400);
  assert.equal(state.limitCalls, 2);
  assert.equal(state.relayCalls, 0);
  assert.throws(
    () => validateV2Report(validV2Report({ activityLog: ["not-a-closed-event"] })),
    InvalidRequestError,
  );
  assert.throws(
    () =>
      validateV2Report(
        validV2Report({ activityLog: ["error.connection.failed: Bob's iPhone"] }),
      ),
    InvalidRequestError,
  );
});

test("v2 issue rendering uses opaque fixed media URLs and a privacy-filtered activity section", async () => {
  const rendered = await renderV2Issue(
    await v2Submission({
      report: validV2Report({ activityLog: ["app.launched", "connection.connected"] }),
      screenshots: [png()],
    }),
  );

  assert.match(rendered.body, /## Privacy-filtered app activity log/u);
  assert.match(rendered.body, /app\.launched\nconnection\.connected/u);
  assert.match(
    rendered.body,
    new RegExp(
      `https://reports\\.openzcine\\.app/v2/bug-report-media/${REPORT_RETRY_UUID}/1`,
      "u",
    ),
  );
  assert.equal(rendered.body.includes("untrusted-original-name"), false);
});

test("v2 idempotency fingerprint includes canonical attachment bytes", async () => {
  const storage = new MemoryStorage();
  let issueCreations = 0;
  const coordinator = new ReceiptCoordinator({
    storage,
    now: () => 10_000,
    async createIssue() {
      issueCreations += 1;
      return { number: 101, url: "https://github.com/erik-sutton95/OpenZCine/issues/101" };
    },
  });
  const initial = await v2Submission({ screenshots: [png()] });
  const changed = await v2Submission({ screenshots: [png({ color: [0x11, 0x22, 0x33, 0xff] })] });

  const created = await coordinator.submit(initial);
  const retried = await coordinator.submit(initial);
  const alteredAttachment = await coordinator.submit(changed);

  assert.equal(created.status, 201);
  assert.equal(retried.status, 200);
  assert.equal(alteredAttachment.status, 400);
  assert.equal(issueCreations, 1);
});

test("v2 writes canonical PNGs to private R2 and serves hardened opaque media", async () => {
  const objects = new Map();
  const puts = [];
  const media = {
    async get(key) {
      const value = objects.get(key);
      return value ? { body: value } : null;
    },
    async put(key, value, options) {
      const bytes = new Uint8Array(value);
      objects.set(key, bytes);
      puts.push({ key, options, value: bytes });
    },
    async delete(key) {
      objects.delete(key);
    },
  };
  const source = png({
    metadata: [pngChunk("tEXt", Buffer.from("device=Bob's iPhone", "utf8"))],
  });
  const submission = rawV2Submission({ screenshots: [source] });
  let postedIssue;
  const receipt = await createV2GitHubIssue(
    { BUG_REPORT_MEDIA: media },
    submission,
    {
      async getToken() {
        return "installation-token";
      },
      async fetchImpl(_url, options) {
        postedIssue = JSON.parse(options.body);
        return new Response(JSON.stringify({ number: 102 }), {
          status: 201,
          headers: { "Content-Type": "application/json" },
        });
      },
    },
  );

  assert.equal(receipt.number, 102);
  assert.deepEqual(puts.map(({ key, options }) => ({ key, options })), [
    {
      key: `bug-report-media/${REPORT_RETRY_UUID}/screenshot-1.png`,
      options: { httpMetadata: { contentType: "image/png" } },
    },
  ]);
  assert.match(postedIssue.body, /https:\/\/reports\.openzcine\.app\/v2\/bug-report-media\//u);
  assert.deepEqual(pngChunkTypes(puts[0].value), ["IHDR", "IDAT", "IEND"]);
  assert.equal(Buffer.from(puts[0].value).includes(Buffer.from("Bob's iPhone")), false);

  const worker = createWorker();
  const response = await worker.fetch(
    new Request(`https://reports.openzcine.app/v2/bug-report-media/${REPORT_RETRY_UUID}/1`),
    { BUG_REPORT_MEDIA: media },
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "image/png");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(response.headers.get("Cache-Control"), "public, max-age=300");
  assert.equal(response.headers.get("Content-Disposition"), null);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), null);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), puts[0].value);

  const missing = await worker.fetch(
    new Request(`https://reports.openzcine.app/v2/bug-report-media/${REPORT_RETRY_UUID}/2`),
    { BUG_REPORT_MEDIA: media },
  );
  assert.equal(missing.status, 404);
});

test("v2 removes newly written media when GitHub definitively rejects issue creation", async () => {
  const objects = new Map();
  const deleted = [];
  const media = {
    async get(key) {
      const value = objects.get(key);
      return value ? { body: value } : null;
    },
    async put(key, value) {
      objects.set(key, new Uint8Array(value));
    },
    async delete(key) {
      deleted.push(key);
      objects.delete(key);
    },
  };

  const submission = await v2Submission({ screenshots: [png()] });
  await assert.rejects(
    () =>
      createV2GitHubIssue(
        { BUG_REPORT_MEDIA: media },
        submission,
        {
          async getToken() {
            return "installation-token";
          },
          async fetchImpl() {
            return new Response(JSON.stringify({ message: "never expose" }), { status: 422 });
          },
        },
      ),
    ServiceUnavailableError,
  );

  assert.deepEqual(deleted, [`bug-report-media/${REPORT_RETRY_UUID}/screenshot-1.png`]);
  assert.equal(objects.size, 0);
});

test("uncertain v2 issue creation blocks matching retries without losing its reservation", async () => {
  const storage = new MemoryStorage();
  let issueCreations = 0;
  const coordinator = new ReceiptCoordinator({
    storage,
    now: () => 10_000,
    async createIssue() {
      issueCreations += 1;
      throw new AmbiguousIssueCreationError();
    },
  });
  const submission = await v2Submission({ screenshots: [png()] });
  const changedSubmission = await v2Submission({
    screenshots: [png({ color: [0x11, 0x22, 0x33, 0xff] })],
  });

  await assert.rejects(() => coordinator.submit(submission), AmbiguousIssueCreationError);
  assert.deepEqual(await coordinator.submit(submission), { status: 503 });
  assert.deepEqual(await coordinator.submit(changedSubmission), { status: 400 });
  assert.equal(issueCreations, 1);
  assert.equal(storage.values.get("pending-submission")?.outcome, "uncertain");
});

test("v2 retains canonical media when the GitHub issue outcome is ambiguous", async () => {
  const objects = new Map();
  const deleted = [];
  const media = {
    async get(key) {
      const value = objects.get(key);
      return value ? { body: value } : null;
    },
    async put(key, value) {
      objects.set(key, new Uint8Array(value));
    },
    async delete(key) {
      deleted.push(key);
      objects.delete(key);
    },
  };
  const options = {
    async getToken() {
      return "installation-token";
    },
  };

  await assert.rejects(
    () =>
      createV2GitHubIssue(
        { BUG_REPORT_MEDIA: media },
        rawV2Submission({ screenshots: [png()] }),
        {
          ...options,
          async fetchImpl() {
            throw new Error("connection ended after request dispatch");
          },
        },
      ),
    AmbiguousIssueCreationError,
  );

  await assert.rejects(
    () =>
      createV2GitHubIssue(
        { BUG_REPORT_MEDIA: media },
        rawV2Submission({
          idempotencyKey: "223e4567-e89b-12d3-a456-426614174000",
          screenshots: [png()],
        }),
        {
          ...options,
          async fetchImpl() {
            return new Response("not a JSON receipt", { status: 201 });
          },
        },
      ),
    AmbiguousIssueCreationError,
  );

  assert.equal(objects.size, 2);
  assert.deepEqual(deleted, []);
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
